import { EventEmitter } from "events";
import { UiParserService } from "./uiParser.service.js";
import { OcrService } from "./ocr.service.js";
import { MemoryService } from "./memory.service.js";
import { PromptBuilder } from "./agent/promptBuilder.js";
import { ActionExecutor } from "./agent/actionExecutor.js";
import { UiVerifier } from "./agent/uiVerifier.js";
import { AgentEvents, UIElement, IDeviceProvider, ILlmProvider } from "../types/index.js";
import { MetricsService, AgentMetrics } from "./metrics.service.js";

const SYSTEM_PROMPT = `You are an autonomous Android testing agent. Your goal is to accomplish the user's objective.
You will be given the current UI state as a compact JSON list of elements, and a history of your past actions.
You must reply with exactly ONE JSON object representing your next action. Do not wrap it in markdown block.

Valid actions:
{"action": "click", "id": <element_id>}
{"action": "input", "id": <element_id>, "text": "<text_to_type>"}
{"action": "swipe", "x1": <x1>, "y1": <y1>, "x2": <x2>, "y2": <y2>}
{"action": "back"}
{"action": "home"}
{"action": "enter"}
{"action": "done"}

Example output:
{"action": "click", "id": 45}

Respond ONLY with valid JSON. Do not provide any conversational filler.`;

export declare interface AgentEventEmitter {
    on<U extends keyof AgentEvents>(event: U, listener: AgentEvents[U]): this;
    emit<U extends keyof AgentEvents>(event: U, ...args: Parameters<AgentEvents[U]>): boolean;
}

export class AgentEventEmitter extends EventEmitter { }

export class AgentService {
    private promptBuilder: PromptBuilder;
    private actionExecutor: ActionExecutor;
    private uiVerifier: UiVerifier;
    private isPaused: boolean = false;
    private pendingManualOverride: string | null = null;
    private currentGoal: string = "";

    public pause() {
        this.isPaused = true;
    }

    public resume(manualAction?: string) {
        if (manualAction) {
            this.pendingManualOverride = manualAction;
        }
        this.isPaused = false;
    }

    constructor(
        private llmProvider: ILlmProvider,
        private deviceProvider: IDeviceProvider,
        private uiParserService: UiParserService,
        private metricsService: MetricsService,
        private ocrService: OcrService,
        private memoryService: MemoryService
    ) {
        this.promptBuilder = new PromptBuilder(this.memoryService);
        this.actionExecutor = new ActionExecutor(this.deviceProvider);
        this.uiVerifier = new UiVerifier(this.deviceProvider, this.uiParserService, this.ocrService);
    }

    public async runAgentLoop(goal: string, maxSteps: number = 15, emitter: AgentEventEmitter = new AgentEventEmitter()): Promise<void> {
        emitter.emit('status', ` Starting Robust Agent Loop for goal: ${goal}`);

        let step = 0;
        let actionHistory: string[] = [];
        let previousUiHash = "";
        let expectedActionEffect = false;
        let isDone = false;

        const startTimeMs = Date.now();
        let totalRetries = 0;

        while (step < maxSteps && !isDone) {
            step++;
            emitter.emit('status', `--- Step ${step} ---`);

            // 1. Verify and Gather UI State
            const state = await this.uiVerifier.waitForIdle(emitter);

            // 2. Self-Healing State Verification
            if (expectedActionEffect && state.hash === previousUiHash) {
                totalRetries++;
                emitter.emit('error', " Verifier: The UI did not change after the last action.");
                actionHistory.push("[System Warning] The previous action had no effect on the UI. The button might be disabled, blocked, or a dead zone. Try a different strategy.");
            }

            previousUiHash = state.hash;
            expectedActionEffect = false;

            emitter.emit('observe', state.elements);
            emitter.emit('status', ` Observed ${state.elements.length} elements.`);

            // 3. Pause Check (Human-in-the-Loop)
            while (this.isPaused) {
                emitter.emit('status', " Agent paused for manual human correction. Waiting for resume...");
                await new Promise(r => setTimeout(r, 1000));
            }

            // Did the human provide a manual override while we were paused?
            if (this.pendingManualOverride) {
                // 3b. Overwrite memory and skip the LLM
                emitter.emit('status', ` Applying Human Override: ${this.pendingManualOverride}`);
                actionHistory.push(`[Success] (MANUAL OVERRIDE) ${this.pendingManualOverride}`);

                await this.memoryService.injectOverride(goal, actionHistory, this.pendingManualOverride);

                this.pendingManualOverride = null;
                expectedActionEffect = true;
                continue; // Immediately jump to the next verify loop step
            }

            // 4. Build Prompt
            const prompt = await this.promptBuilder.buildEnvironment(goal, state.textRepresentation, actionHistory);

            emitter.emit('status', " Deciding next action...");

            // 5. Generate LLM Action
            const commandText = await this.llmProvider.generateAction(
                step === 1 ? SYSTEM_PROMPT : "",
                prompt,
                { maxTokens: 150, temperature: 0.1 },
                state.screenshotPath
            );
            emitter.emit('decide', commandText);

            try {
                // 6. Parse and Execute Action
                const jsonStart = commandText.indexOf('{');
                const jsonEnd = commandText.lastIndexOf('}');
                if (jsonStart === -1 || jsonEnd === -1) throw new Error("No JSON object found in LLM response.");

                const actionObj = JSON.parse(commandText.substring(jsonStart, jsonEnd + 1));
                const actionType = actionObj.action?.toLowerCase();

                if (actionType === 'done') {
                    emitter.emit('status', ` Goal achieved successfully in ${step} steps.`);
                    emitter.emit('action', "DONE");
                    emitter.emit('done');

                    await this.metricsService.appendMetrics({
                        id: Date.now().toString(),
                        goal_text: goal,
                        success: true,
                        total_steps: step,
                        duration_ms: Date.now() - startTimeMs,
                        total_retries: totalRetries,
                        timestamp: new Date().toISOString()
                    });

                    // Save successful trajectory
                    await this.memoryService.saveTrajectory(goal, actionHistory);
                    isDone = true;
                    break;
                }

                // 6. Cache Pre-State
                const preStateElements = [...state.elements];

                // Execute action via ActionExecutor
                const success = await this.actionExecutor.execute(actionObj, preStateElements, emitter);

                if (success) {
                    // 7. Re-verify the UI after settling
                    const postState = await this.uiVerifier.waitForIdle(emitter);

                    // 8. Generate actionable contextual feedback for LLM
                    const verificationResult = await this.uiVerifier.verifyAction(actionObj, preStateElements, postState.elements);
                    actionHistory.push(verificationResult);

                    expectedActionEffect = true;
                    // Overwrite the current loop state with the newly grabbed post-state so step #2 doesn't double dip
                    previousUiHash = postState.hash;
                } else {
                    actionHistory.push(`[Failed] Failed to execute ${actionType}`);
                }

            } catch (err: any) {
                emitter.emit('error', ` Execution failed: ${err.message}. Retrying...`);
                actionHistory.push(`[Failed] Action error: ${err.message}`);
                // Small backoff before next step
                await new Promise(r => setTimeout(r, 1000));
            }
        }

        if (step >= maxSteps && !isDone) {
            emitter.emit('error', ` Maximum steps (${maxSteps}) reached. Goal incomplete.`);
            emitter.emit('done');
            await this.metricsService.appendMetrics({
                id: Date.now().toString(),
                goal_text: goal,
                success: false,
                total_steps: step,
                duration_ms: Date.now() - startTimeMs,
                total_retries: totalRetries,
                timestamp: new Date().toISOString()
            });
        }
    }
}
