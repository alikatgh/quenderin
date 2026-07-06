import { EventEmitter } from "events";
import fs from "fs/promises";
import { UiParserService } from "./uiParser.service.js";
import { OcrService } from "./ocr.service.js";
import { MemoryService } from "./memory.service.js";
import { PromptBuilder } from "./agent/promptBuilder.js";
import { redactSecrets } from "./capability/redaction.js";
import { ActionExecutor } from "./agent/actionExecutor.js";
import { UiVerifier } from "./agent/uiVerifier.js";
import { AgentEvents, AgentAction, IDeviceProvider, ILlmProvider } from "../types/index.js";
import { MetricsService } from "./metrics.service.js";
import { getHardwareProfile } from "../utils/hardware.js";
import logger from "../utils/logger.js";

/**
 * Extract the FIRST complete, balanced `{ … }` object from text, walking braces and skipping quoted
 * strings — NOT `indexOf('{')`..`lastIndexOf('}')`, which over-extends the moment the model emits a
 * second object or a trailing `}` in prose, making `JSON.parse` throw and silently dropping a valid
 * first action (audit H13). Mirrors the mobile `AgentDecisionParser.firstJSONObject`.
 */
export function firstJsonObject(text: string): string | null {
    const start = text.indexOf('{');
    if (start === -1) return null;
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
        const c = text[i];
        if (inString) {
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === '"') inString = false;
        } else if (c === '"') inString = true;
        else if (c === '{') depth++;
        else if (c === '}') { depth--; if (depth === 0) return text.substring(start, i + 1); }
    }
    return null;
}

const HW = getHardwareProfile();

const SYSTEM_PROMPT = `You are an autonomous Android testing agent. Your goal is to accomplish the user's objective.
You will be given the current UI state as a compact JSON list of elements, and a history of your past actions.
You must reply with exactly ONE JSON object representing your next action. Do not wrap it in markdown block.
If you cannot output JSON, you may use XML tags as a fallback: <action>click</action><id>45</id>

Valid actions:
{"action": "click", "id": <element_id>}
{"action": "input", "id": <element_id>, "text": "<text_to_type>"}
{"action": "scroll", "direction": "up"|"down"}
{"action": "key", "key": "back"|"home"|"enter"}
{"action": "done"}

Example output:
{"action": "click", "id": 45}

Respond ONLY with valid JSON or XML. Do not provide any conversational filler.`;

const INTENT_CLASSIFIER_PROMPT = `Classify the user's request into one of two categories: "ACTION" or "CHAT".
- ACTION: The user wants you to interact with the Android device (e.g., "Open Settings", "Tap Search", "Find Spotify").
- CHAT: The user is asking a general question, discussing files, or asking for knowledge (e.g., "What is the capital of France?", "Summarize this code", "Who wrote this?").

Reply with exactly one word: ACTION or CHAT.`;

export declare interface AgentEventEmitter {
    on<U extends keyof AgentEvents>(event: U, listener: AgentEvents[U]): this;
    emit<U extends keyof AgentEvents>(event: U, ...args: Parameters<AgentEvents[U]>): boolean;
}

export class AgentEventEmitter extends EventEmitter { }

type ParsedAgentAction = {
    action?: string;
    target_id?: number | string;
    id?: number | string;
    x?: number;
    y?: number;
    text?: string;
    direction?: 'up' | 'down' | 'left' | 'right';
    key?: string;
};

export class AgentService {
    private promptBuilder: PromptBuilder;
    private actionExecutor: ActionExecutor;
    private uiVerifier: UiVerifier;
    /** Guarded by _stateMutex to prevent pause/resume race conditions */
    private _isPaused: boolean = false;
    private _pendingManualOverride: string | null = null;
    private _isRunning: boolean = false;
    private currentGoal: string = "";

    public get isPaused(): boolean { return this._isPaused; }
    public get isRunning(): boolean { return this._isRunning; }

    public pause(): void {
        this._isPaused = true;
        logger.info('[AgentService] Agent paused.');
    }

    public resume(manualAction?: string): void {
        if (manualAction) {
            this._pendingManualOverride = manualAction;
        }
        this._isPaused = false;
        logger.info(`[AgentService] Agent resumed${manualAction ? ' with manual override' : ''}.`);
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

    /** Default max steps scales with hardware — fewer steps on slow devices to prevent
     *  multi-minute inference loops. Override via QUENDERIN_MAX_AGENT_STEPS env var. */
    private static resolveDefaultMaxSteps(): number {
        const envSteps = Number(process.env.QUENDERIN_MAX_AGENT_STEPS);
        if (Number.isFinite(envSteps) && envSteps >= 1) return envSteps;
        if (HW.tier === 'embedded') return 8;
        if (HW.tier === 'constrained') return 12;
        return 15;
    }

    /** Overall wall-clock budget for one mission. The step cap alone can't bound runtime when each
     *  step is slow (large model on a constrained device), so a long-running loop could pin the
     *  device for many minutes. Override via QUENDERIN_MAX_AGENT_MS. (Audit: no wall-clock timeout.) */
    private static resolveDefaultMaxWallClockMs(): number {
        const envMs = Number(process.env.QUENDERIN_MAX_AGENT_MS);
        if (Number.isFinite(envMs) && envMs >= 0) return envMs;
        return 8 * 60 * 1000; // 8 minutes — generous; never fires in a normal interactive session
    }

    public async runAgentLoop(goal: string, emitter: AgentEventEmitter = new AgentEventEmitter(), attachments: { name: string, content: string }[] = [], maxSteps: number = AgentService.resolveDefaultMaxSteps(), maxWallClockMs: number = AgentService.resolveDefaultMaxWallClockMs()): Promise<void> {
        if (this._isRunning) {
            logger.warn('[AgentService] Agent loop already running — ignoring duplicate start.');
            return;
        }
        // Refuse a blatantly destructive goal before any work (H10) — per-action checks still apply.
        try {
            this.actionExecutor.assertGoalSafe(goal);
        } catch (e: unknown) {
            emitter.emit('error', e instanceof Error ? e.message : String(e));
            emitter.emit('done');
            return;
        }
        this._isRunning = true;
        // try/finally guarantees the running flag clears on EVERY exit — a throw used to leave it
        // stuck `true`, permanently dead-locking all future runAgentLoop() calls (H7).
        try {
            await this._runAgentLoop(goal, emitter, attachments, maxSteps, maxWallClockMs);
        } finally {
            this._isRunning = false;
        }
    }

    private async _runAgentLoop(goal: string, emitter: AgentEventEmitter, attachments: { name: string, content: string }[], maxSteps: number, maxWallClockMs: number): Promise<void> {
        // Q-357: the goal is logged for troubleshooting, but a spoken/typed CREDENTIAL in it must not
        // persist in the app log. redactSecrets masks key/token/password SHAPES while keeping the goal
        // readable. (The command intent itself is the user's own local log; only secrets are scrubbed.)
        logger.info(`[AgentService] Starting mission: ${redactSecrets(goal)}`);
        if (attachments.length > 0) {
            logger.info(`[AgentService] Context enriched with ${attachments.length} attachments.`);
        }

        let step = 0;
        let actionHistory: string[] = [];
        let previousUiHash = "";
        let expectedActionEffect = false;
        let isDone = false;

        const startTimeMs = Date.now();
        let totalRetries = 0;

        // --- Intent Classification —  regex-first, LLM fallback ---
        // On embedded/constrained hardware, skip the LLM call entirely when
        // regex classification has high/medium confidence — saves 5-30s per request.
        emitter.emit('status', " Classifying intent...");
        try {
            const { classifyIntent } = await import('./intentClassifier.js');
            const regexResult = classifyIntent(goal);
            const skipLlmClassification =
                (HW.tier === 'embedded' || HW.tier === 'constrained') &&
                (regexResult.confidence === 'high' || regexResult.confidence === 'medium');

            let isChat = false;
            if (skipLlmClassification) {
                isChat = regexResult.intent === 'chat';
            } else {
                const intentRaw = await this.llmProvider.generateAction(
                    INTENT_CLASSIFIER_PROMPT,
                    `User Request: "${goal}"`,
                    { maxTokens: 10, temperature: 0.1 }
                );
                isChat = intentRaw.trim().toUpperCase().includes("CHAT");
            }

            if (isChat) {
                emitter.emit('status', " Processing as General Intelligence (Bypassing ADB)...");
                const prompt = await this.promptBuilder.buildEnvironment(goal, "No active UI elements (Knowledge Mode)", [], "", attachments);
                const response = await this.llmProvider.generateAction(
                    "You are a helpful AI assistant. Answer the user's question directly and concisely based on the context provided. If you need to perform an action on the device, say so.",
                    prompt,
                    { maxTokens: 500, temperature: 0.7 }
                );
                emitter.emit('status', response);
                emitter.emit('done');
                return;
            }
        } catch (e: unknown) {
            logger.error("[AgentService] Intent classification failed, defaulting to ACTION mode.", e);
        }

        let timedOut = false;
        while (step < maxSteps && !isDone) {
            // Overall wall-clock budget — the step cap alone can't bound a loop whose individual
            // steps are slow. Checked before each step so a long mission stops cleanly (audit).
            if (Date.now() - startTimeMs >= maxWallClockMs) { timedOut = true; break; }
            step++;
            emitter.emit('status', `--- Step ${step} ---`);

            // 1. Verify and Gather UI State
            const state = await this.uiVerifier.waitForIdle(emitter);

            // 2. Self-Healing State Verification
            if (expectedActionEffect && state.hash === previousUiHash) {
                totalRetries++;
                emitter.emit('error', "**Action Unsuccessful: UI Did Not Respond**\nI tried to tap or swipe, but nothing happened. To help me:\n1. Check if the app is frozen or requires a special gesture.\n2. Navigate past any unexpected popups or alerts manually.\n3. Give me a new instruction on what to do next.");
                actionHistory.push("[System Warning] The previous action had no effect on the UI. The button might be disabled, blocked, or a dead zone. Try a different strategy.");
            }

            previousUiHash = state.hash;
            expectedActionEffect = false;

            emitter.emit('observe', state.elements);
            emitter.emit('status', ` Observed ${state.elements.length} elements.`);

            // 3. Pause Check (Human-in-the-Loop)
            while (this._isPaused) {
                emitter.emit('status', " Agent paused for manual human correction. Waiting for resume...");
                await new Promise(r => setTimeout(r, 1000));
            }

            // Did the human provide a manual override while we were paused?
            if (this._pendingManualOverride) {
                // 3b. Overwrite memory and skip the LLM
                emitter.emit('status', ` Applying Human Override: ${this._pendingManualOverride}`);
                actionHistory.push(`[Success] (MANUAL OVERRIDE) ${this._pendingManualOverride}`);

                await this.memoryService.injectOverride(goal, actionHistory, this._pendingManualOverride);

                this._pendingManualOverride = null;
                expectedActionEffect = true;
                continue; // Immediately jump to the next verify loop step
            }

            // Before building prompt, get eye description (Autonomous Eye)
            emitter.emit('status', " Processing visual context...");
            let eyeDescription = "";
            if (state.screenshotPath) {
                try {
                    eyeDescription = await this.llmProvider.generateAction(
                        "Briefly describe the interactive elements visible on this screen in one sentence.",
                        "",
                        { maxTokens: 100, temperature: 0.1 },
                        state.screenshotPath
                    );
                } catch (e) {
                    logger.debug("[AgentService] Eye formulation failed:", e);
                }
            }

            // 4. Build Prompt
            const prompt = await this.promptBuilder.buildEnvironment(goal, state.textRepresentation, actionHistory, eyeDescription, attachments);

            emitter.emit('status', " Deciding next action...");

            // 5. Generate LLM Action
            let commandText: string;
            try {
                commandText = await this.llmProvider.generateAction(
                    step === 1 ? SYSTEM_PROMPT : "",
                    prompt,
                    { maxTokens: 150, temperature: 0.1 },
                    state.screenshotPath
                );
            } finally {
                // Screenshot has been consumed by the LLM calls — delete it to free /tmp space (2–5 MB
                // per frame) on EVERY path. A throw in generateAction previously skipped the unlink and
                // leaked the file until the periodic temp sweep (deep-hunt).
                if (state.screenshotPath) {
                    fs.unlink(state.screenshotPath).catch(() => { /* already gone */ });
                }
            }
            emitter.emit('decide', commandText);

            try {
                // 6. Parse and Execute Action (Universal Tool Loop)
                let actionObj: ParsedAgentAction | null = null;
                try {
                    const jsonStr = firstJsonObject(commandText);   // first COMPLETE object, not first-{..last-} (H13)
                    if (jsonStr) {
                        actionObj = JSON.parse(jsonStr) as ParsedAgentAction;
                    } else {
                        throw new Error("No JSON object found.");
                    }
                } catch {
                    emitter.emit('status', " Applying XML parser fallback...");
                    const extract = (tag: string): string | undefined => {
                        const match = commandText.match(new RegExp(`<${tag}>(.*?)</${tag}>`, 'i'));
                        return match ? match[1] : undefined;
                    };
                    const action = extract('action');
                    if (!action) throw new Error("Could not parse JSON or XML action from response.");

                    const xmlActionObj: ParsedAgentAction = { action: action as AgentAction['action'] };
                    const id = extract('id');
                    if (id) xmlActionObj.id = parseInt(id, 10);
                    const text = extract('text');
                    if (text) xmlActionObj.text = text;
                    const x = extract('x');
                    if (x) xmlActionObj.x = parseInt(x, 10);
                    const y = extract('y');
                    if (y) xmlActionObj.y = parseInt(y, 10);
                    const direction = extract('direction');
                    if (direction) xmlActionObj.direction = direction as AgentAction['direction'];
                    const key = extract('key');
                    if (key) xmlActionObj.key = key;
                    actionObj = xmlActionObj;
                }

                if (!actionObj) {
                    throw new Error('No actionable command parsed from LLM output.');
                }

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
                const success = await this.actionExecutor.execute(actionObj as AgentAction, preStateElements, emitter);

                if (success) {
                    // 7. Re-verify the UI after settling
                    const postState = await this.uiVerifier.waitForIdle(emitter);

                    // 8. Generate actionable contextual feedback for LLM
                    const verificationResult = await this.uiVerifier.verifyAction(actionObj as Partial<AgentAction>, preStateElements, postState.elements);
                    actionHistory.push(verificationResult);

                    expectedActionEffect = true;
                    // Overwrite the current loop state with the newly grabbed post-state so step #2 doesn't double dip
                    previousUiHash = postState.hash;
                } else {
                    actionHistory.push(`[Failed] Failed to execute ${actionType}`);
                }

            } catch (err: unknown) {
                const message = err instanceof Error ? err.message : String(err);
                emitter.emit('error', `**Command Execution Failed**\nI couldn't run the last command. Troubleshooting steps:\n1. Wait a moment; I am automatically retrying.\n2. If this persists, ensure your device hasn't disconnected.\n3. Check the terminal running \`npm run dev\` for more detailed connectivity issues.`);
                actionHistory.push(`[Failed] Action error: ${message}`);
                // Small backoff before next step
                await new Promise(r => setTimeout(r, 1000));
            }
        }

        if ((step >= maxSteps || timedOut) && !isDone) {
            emitter.emit('error', timedOut
                ? `**Task Timed Out**\nI ran out of time before reaching the goal. To fix this:\n1. Break your goal down into smaller, simpler instructions.\n2. Look at the device screen and guide me step-by-step.\n3. E.g., instead of "Book a flight," try "Open the travel app."`
                : `**Task Too Complex (Timeout)**\nI took too many steps without reaching the goal. To fix this:\n1. Break your goal down into smaller, simpler instructions.\n2. Look at the device screen and guide me step-by-step.\n3. E.g., instead of "Book a flight," try "Open the travel app."`);
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
