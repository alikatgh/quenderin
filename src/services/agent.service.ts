import { LlamaChatSession } from "node-llama-cpp";
import { EventEmitter } from "events";
import { LlmService } from "./llm.service.js";
import { AdbService } from "./adb.service.js";
import { UiParserService } from "./uiParser.service.js";
import { OcrService } from "./ocr.service.js";
import { MemoryService } from "./memory.service.js";
import { AgentEvents, UIElement } from "../types/index.js";
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
    constructor(
        private llmService: LlmService,
        private adbService: AdbService,
        private uiParserService: UiParserService,
        private metricsService: MetricsService,
        private ocrService: OcrService,
        private memoryService: MemoryService
    ) { }

    private async waitForUiIdle(emitter: AgentEventEmitter): Promise<{ elements: UIElement[], textRepresentation: string }> {
        emitter.emit('status', "⏳ Waiting for UI to become idle...");
        let previousDump = "";
        let retries = 0;
        let finalParsed: { elements: UIElement[], textRepresentation: string } | null = null;

        while (retries < 10) {
            const xml = await this.adbService.dumpUI();
            // A simple hash/length check to see if animations have settled
            if (xml === previousDump && xml.length > 0) {
                break; // UI is stable
            }
            previousDump = xml;
            finalParsed = this.uiParserService.parseUI(xml);

            // Poll every 500ms
            await new Promise(r => setTimeout(r, 500));
            retries++;
        }

        if (!finalParsed) {
            const xml = await this.adbService.dumpUI();
            finalParsed = this.uiParserService.parseUI(xml);
        }

        // Vision Fallback (OCR) integration
        if (finalParsed && finalParsed.elements.length < 5) {
            emitter.emit('status', "👁️ Few UI elements detected. Triggering Vision OCR Fallback...");
            try {
                const screenshotPath = await this.adbService.screencap();
                // Find next available ID
                const nextId = finalParsed.elements.length > 0
                    ? Math.max(...finalParsed.elements.map(e => e.id)) + 1
                    : 1000;

                const ocrElements = await this.ocrService.extractTextElements(screenshotPath, nextId);

                if (ocrElements.length > 0) {
                    emitter.emit('status', `👁️ Found ${ocrElements.length} synthetic text nodes via OCR.`);
                    finalParsed.elements.push(...ocrElements);
                    // Regenerate the symbolic JSON text for the LLM
                    finalParsed.textRepresentation = this.uiParserService.formatElementsToSymbolicState(finalParsed.elements);
                }
            } catch (err: any) {
                emitter.emit('error', `Vision Fallback Error: ${err.message}`);
            }
        }

        return finalParsed as { elements: UIElement[], textRepresentation: string };
    }

    public async runAgentLoop(goal: string, maxSteps: number = 15, emitter: AgentEventEmitter = new AgentEventEmitter()): Promise<void> {
        emitter.emit('status', `🤖 Starting Robust Agent Loop for goal: ${goal}`);

        const { context } = await this.llmService.getModelAndContext();
        // Use a new session to prevent context bounds filling up endlessly
        const session = new LlamaChatSession({ contextSequence: context.getSequence() });

        let step = 0;
        let actionHistory: string[] = [];
        let previousUiHash = "";
        let expectedActionEffect = false;

        const startTimeMs = Date.now();
        let totalRetries = 0;

        // Trajectory Memory check
        const pastMemory = await this.memoryService.findSimilarGoal(goal);
        let memoryPromptAddition = "";
        if (pastMemory) {
            emitter.emit('status', "🧠 Found a successful past trajectory for this goal! Injecting into context.");
            memoryPromptAddition = `\n\n[SYSTEM WARNING]: You have successfully solved a similar goal in the past. Your previous winning trajectory was:\n${pastMemory.actions.join('\n')}\nConsider following this known-good sequence.`;
        }

        while (step < maxSteps) {
            step++;
            emitter.emit('status', `--- Step ${step} ---`);

            // Event-Driven Idling
            const { elements, textRepresentation } = await this.waitForUiIdle(emitter);

            // Advanced Verifier (Self-Healing Loop)
            if (expectedActionEffect && textRepresentation === previousUiHash) {
                totalRetries++;
                emitter.emit('error', "⚠️ Verifier: The UI did not change after the last action.");
                actionHistory.push("[System Warning] The previous action had no effect on the UI. The button might be disabled, blocked, or a dead zone. Try a different strategy.");
            }

            previousUiHash = textRepresentation;
            expectedActionEffect = false;

            emitter.emit('observe', elements);
            emitter.emit('status', `👀 Observed ${elements.length} elements.`);

            const historyText = actionHistory.length > 0 ? `\n\nRecent Actions:\n${actionHistory.slice(-5).join('\n')}` : '';
            const prompt = `Current UI State:\n${textRepresentation}${historyText}${memoryPromptAddition}\n\nUser Goal: ${goal}\n\nWhat is your next JSON action?`;

            emitter.emit('status', "🧠 Deciding next action...");

            const response = await session.prompt(step === 1 ? `System: ${SYSTEM_PROMPT}\n\nUser: ${prompt}` : `User: ${prompt}`, {
                maxTokens: 150,
                temperature: 0.1 // Keep temperature low for structured JSON output
            });

            const commandText = response.trim();
            emitter.emit('decide', commandText);

            try {
                // Attempt to parse JSON robustly inside the text block
                const jsonStart = commandText.indexOf('{');
                const jsonEnd = commandText.lastIndexOf('}');
                if (jsonStart === -1 || jsonEnd === -1) throw new Error("No JSON object found in LLM response.");

                const actionObj = JSON.parse(commandText.substring(jsonStart, jsonEnd + 1));
                const actionType = actionObj.action?.toLowerCase();

                // Safety Sandboxing Check
                const destructiveKeywords = ["delete", "pay", "buy", "purchase", "password"];
                if (actionType === 'click' || actionType === 'input') {
                    const el = elements.find(e => e.id === actionObj.id);
                    if (el && destructiveKeywords.some(kw => el.text.toLowerCase().includes(kw) || el.contentDesc.toLowerCase().includes(kw))) {
                        emitter.emit('error', `🛡️ Safety Block: Refusing to interact with potentially destructive element [${el.text}].`);
                        throw new Error(`Safety Sandbox prevented interaction with element ${el.id}.`);
                    }
                }

                if (actionType === 'done') {
                    emitter.emit('status', `✅ Goal achieved successfully in ${step} steps.`);
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
                    break;
                } else if (actionType === 'click') {
                    const targetId = actionObj.id;
                    const el = elements.find(e => e.id === targetId);
                    if (el) {
                        emitter.emit('status', `👉 Clicking dynamically on element ${targetId} at (${el.center.x}, ${el.center.y})`);
                        await this.adbService.tap(el.center.x, el.center.y);
                        actionHistory.push(`[Success] Clicked element ${targetId} (${el.className})`);
                        emitter.emit('action', `Clicked [${targetId}] ${el.className}`);
                        expectedActionEffect = true;
                    } else {
                        throw new Error(`Element ID ${targetId} not found in current UI state.`);
                    }
                } else if (actionType === 'input') {
                    const targetId = actionObj.id;
                    const el = elements.find(e => e.id === targetId);
                    if (el) {
                        emitter.emit('status', `⌨️ Typing into element ${targetId}`);
                        // Tap to focus first
                        await this.adbService.tap(el.center.x, el.center.y);
                        await new Promise(r => setTimeout(r, 500)); // Small wait for keyboard IME
                        await this.adbService.typeText(actionObj.text || "");
                        actionHistory.push(`[Success] Typed "${actionObj.text}" into element ${targetId}`);
                        emitter.emit('action', `Typed into [${targetId}]`);
                        expectedActionEffect = true;
                    } else {
                        throw new Error(`Element ID ${targetId} not found in current UI state.`);
                    }
                } else if (actionType === 'swipe') {
                    await this.adbService.swipe(actionObj.x1, actionObj.y1, actionObj.x2, actionObj.y2);
                    actionHistory.push(`[Success] Swiped from ${actionObj.x1},${actionObj.y1} to ${actionObj.x2},${actionObj.y2}`);
                    emitter.emit('action', 'Swiped screen');
                    expectedActionEffect = true;
                } else if (actionType === 'back') {
                    await this.adbService.keyevent(4);
                    actionHistory.push(`[Success] Pressed BACK`);
                    emitter.emit('action', 'Pressed BACK');
                    expectedActionEffect = true;
                } else if (actionType === 'home') {
                    await this.adbService.keyevent(3);
                    actionHistory.push(`[Success] Pressed HOME`);
                    emitter.emit('action', 'Pressed HOME');
                    expectedActionEffect = true;
                } else if (actionType === 'enter') {
                    await this.adbService.keyevent(66);
                    actionHistory.push(`[Success] Pressed ENTER`);
                    emitter.emit('action', 'Pressed ENTER');
                    expectedActionEffect = true;
                } else {
                    throw new Error(`Unknown action type: ${actionType}`);
                }

            } catch (err: any) {
                emitter.emit('error', `⚠️ Execution failed: ${err.message}. Retrying...`);
                actionHistory.push(`[Failed] Action error: ${err.message}`);
                // Small backoff before next step
                await new Promise(r => setTimeout(r, 1000));
            }
        }

        if (step >= maxSteps) {
            emitter.emit('error', `❌ Maximum steps (${maxSteps}) reached. Goal incomplete.`);
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
