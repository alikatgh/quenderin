import { EventEmitter } from "events";
import fs from "fs/promises";
import { UiParserService } from "./uiParser.service.js";
import { OcrService } from "./ocr.service.js";
import { MemoryService } from "./memory.service.js";
import { PromptBuilder } from "./agent/promptBuilder.js";
import { redactSecrets } from "./capability/redaction.js";
import { ActionExecutor, SafetyViolationError } from "./agent/actionExecutor.js";
import { UiVerifier } from "./agent/uiVerifier.js";
import { AuditLedger, InMemoryAuditLedger } from "./capability/capability.js";
import { AgentEvents, AgentAction, IDeviceProvider, ILlmProvider } from "../types/index.js";
import { MetricsService } from "./metrics.service.js";
import { getHardwareProfile } from "../utils/hardware.js";
import logger from "../utils/logger.js";

// Imported for the loop below and re-exported for existing importers (tests) — the one
// implementation lives in utils/json.ts.
import { firstJsonObject } from "../utils/json.js";
export { firstJsonObject };

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

/** JSON schema mirror of the SYSTEM_PROMPT action space. Passed as GenerationOptions.jsonSchema so
 *  a grammar-capable provider CANNOT emit anything but one valid action object — parse failures and
 *  the XML fallback become dead paths on the real engine (they remain for fakes/ported providers).
 *  Shaped as oneOf-per-variant, NOT one flat object: the GBNF grammar emits EVERY listed property,
 *  so a flat schema forced junk fields onto every action (a "done" with a direction, a "scroll"
 *  with an id — live-caught by scripts/smoke_llm_engine.ts). Each variant carries exactly the
 *  fields its executor branch reads. Must stay in lockstep with AgentAction (types/index.ts) and
 *  the mobile twins' action space. */
const ACTION_JSON_SCHEMA: Record<string, unknown> = {
    oneOf: [
        { type: "object", properties: { action: { const: "click" }, id: { type: "number" } } },
        { type: "object", properties: { action: { const: "click" }, x: { type: "number" }, y: { type: "number" } } },
        { type: "object", properties: { action: { const: "input" }, id: { type: "number" }, text: { type: "string" } } },
        { type: "object", properties: { action: { const: "input" }, x: { type: "number" }, y: { type: "number" }, text: { type: "string" } } },
        { type: "object", properties: { action: { const: "scroll" }, direction: { enum: ["up", "down", "left", "right"] } } },
        { type: "object", properties: { action: { const: "key" }, key: { enum: ["back", "home", "enter"] } } },
        { type: "object", properties: { action: { const: "done" } } },
    ],
};

/** One mission = one KV-cache lineage. The stable prompt prefix (system prompt, goal, hints,
 *  attachments) is prefilled once and reused every step instead of re-decoded from scratch. */
const AGENT_CACHE_KEY = "agent-mission";

// Q-637: the ONE LLM intent step. The agent runs the shared regex classifier (intentClassifier.ts) first
// and only falls back to this coarse chat-vs-action prompt to break a low-confidence tie on capable
// hardware. There is deliberately no second LLM classifier (the divergent classifyWithLlmFallback was
// removed) — one regex classifier + this one tiebreak, so intent behavior can't drift across code paths.
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

/**
 * Q-549 Step 3: opt-in per-run mission approval. Shown the goal (never auto-approved from model
 * output); resolves true = drive the device, false = refuse the mission. Fail-closed when the
 * flag is on and no approver is wired.
 */
export type MissionApprover = (goal: string) => Promise<boolean>;

export class AgentService {
    private promptBuilder: PromptBuilder;
    private actionExecutor: ActionExecutor;
    private uiVerifier: UiVerifier;
    /** Guarded by _stateMutex to prevent pause/resume race conditions */
    private _isPaused: boolean = false;
    private _pendingManualOverride: string | null = null;
    private _isRunning: boolean = false;
    private currentGoal: string = "";
    /** Q-523: the agent HARD-STOP (kill switch). Non-null only while a run is active; stop() aborts it,
     *  which (a) ends any in-flight generateAction decode within a token and (b) breaks the loop + the
     *  pause-wait. Distinct from pause(), which parks and can resume. The local-agent trust superpower. */
    private _abortController: AbortController | null = null;
    /** Q-549 (governance Step 1): a per-action flight recorder for the DEVICE agent — the same
     *  auditability the governed capability path has, adapted to a continuous tap/scroll loop. Every
     *  executed action is recorded with its decision (allowed / failed / blocked / error) and the goal it
     *  served, so a run is reviewable after the fact. Bounded (this agent is long-lived) + secret-redacted
     *  by the ledger's append. Read-only observability — it adds NO gate, so it can't stall the loop.
     *  Surfaced via GET /api/agent/ledger (token-gated). */
    public readonly actionLedger: AuditLedger = new InMemoryAuditLedger(500);

    /**
     * Q-549 Step 3: when true, ACTION missions must pass [missionApprover] before any device
     * observation/tap. Default false (prior behavior). Enable via [setMissionApproval] or env
     * `QUENDERIN_MISSION_APPROVAL=1`. Fail-closed: enabled + no approver ⇒ refuse to drive.
     */
    private _requireMissionApproval: boolean = AgentService.resolveMissionApprovalDefault();
    private _missionApprover: MissionApprover | undefined;

    public get isPaused(): boolean { return this._isPaused; }
    public get isRunning(): boolean { return this._isRunning; }
    /** Whether opt-in per-run mission approval is required (Q-549 Step 3). */
    public get requireMissionApproval(): boolean { return this._requireMissionApproval; }

    /**
     * Q-549 Step 3: configure per-run mission approval. `enabled=false` restores prior behavior
     * (no gate). When enabled, [approver] must be set or every ACTION mission fails closed.
     */
    public setMissionApproval(enabled: boolean, approver?: MissionApprover): void {
        this._requireMissionApproval = enabled;
        this._missionApprover = approver;
    }

    /**
     * Q-549 Step 3: install a waiting approver for the live channel (dashboard / WS).
     * [onRequest] is called with the goal so the UI can show Allow / Don't-allow; the mission
     * parks until [answerMissionApproval] resolves it. Fail-closed if the client disconnects
     * without answering (stop() rejects pending as false).
     */
    public installWaitingMissionApprover(onRequest: (goal: string) => void): void {
        this.setMissionApproval(true, (goal) => new Promise<boolean>((resolve) => {
            // A prior pending wait is fail-closed so a stuck dialog can't double-resolve.
            if (this._pendingMissionResolve) {
                this._pendingMissionResolve(false);
                this._pendingMissionResolve = null;
            }
            this._pendingMissionResolve = resolve;
            try {
                onRequest(goal);
            } catch {
                this._pendingMissionResolve = null;
                resolve(false);
            }
        }));
    }

    /** Resolve a waiting mission-approval dialog (Q-549 Step 3). No-op if nothing is waiting. */
    public answerMissionApproval(approved: boolean): void {
        const resolve = this._pendingMissionResolve;
        this._pendingMissionResolve = null;
        resolve?.(approved === true);
    }

    private _pendingMissionResolve: ((ok: boolean) => void) | null = null;

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

    /** Q-523: hard-stop the running mission. Aborts the in-flight decode and clears pause so a stop
     *  issued WHILE paused also exits the wait loop. No-op when nothing is running. */
    public stop(): void {
        if (this._abortController) {
            logger.info('[AgentService] Hard-stop requested — aborting the mission.');
            this._abortController.abort();
        }
        this._isPaused = false;   // a stop during a pause must break the pause-wait, not stay parked
        // Q-549 Step 3: a stop while waiting on mission approval must not hang forever.
        this.answerMissionApproval(false);
    }

    /** Q-549: compact, human-readable descriptor of a device action for the audit ledger (a `text` field
     *  is secret-redacted by the ledger's append, so a typed credential never lands in the record). */
    private static describeAction(a: ParsedAgentAction): string {
        const parts: string[] = [];
        if (a.id !== undefined) parts.push(`id=${a.id}`);
        if (a.x !== undefined && a.y !== undefined) parts.push(`(${a.x},${a.y})`);
        if (a.direction) parts.push(`dir=${a.direction}`);
        if (a.key) parts.push(`key=${a.key}`);
        if (a.text) parts.push(`text=${a.text}`);
        return parts.join(' ') || '-';
    }

    /** Q-549: record one device action in the flight recorder. Pure side-effect (append-only) — never
     *  throws into the loop; a ledger failure must not stop the agent. */
    private recordAction(a: ParsedAgentAction, decision: string, outcome: string, goal: string): void {
        try {
            this.actionLedger.append({
                timestampMs: Date.now(),
                capability: `device.${a.action?.toLowerCase() ?? 'unknown'}`,
                tier: 0,
                input: AgentService.describeAction(a),
                decision,
                outcome,
                goal,
            });
        } catch { /* observability must never break the loop */ }
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

    /** Q-549 (governance Step 2): the bulk brake — after this many EXECUTED device actions in one
     *  mission, the loop self-pauses and waits for the user's explicit Resume. maxSteps/wall-clock
     *  bound RUNTIME but not CHANGE VOLUME; this mirrors the capability runner's `passesBulkGuard`
     *  (same default of 20) adapted to the continuous loop's pause/intervene channel. 0 disables.
     *  Override via QUENDERIN_BULK_BRAKE_ACTIONS. */
    private static resolveBulkBrakeThreshold(): number {
        const env = Number(process.env.QUENDERIN_BULK_BRAKE_ACTIONS);
        if (Number.isFinite(env) && env >= 0) return env;
        return 20;
    }

    /** Q-549 Step 3 default: OFF unless `QUENDERIN_MISSION_APPROVAL=1|true|yes`. Prior behavior preserved. */
    private static resolveMissionApprovalDefault(): boolean {
        const v = (process.env.QUENDERIN_MISSION_APPROVAL ?? '').trim().toLowerCase();
        return v === '1' || v === 'true' || v === 'yes';
    }

    /**
     * Q-549 Step 3 pure gate — exported for unit tests. When [requireApproval] is false, always allow
     * (prior behavior). When true: no approver ⇒ refuse (fail-closed); approver false ⇒ refuse;
     * approver true ⇒ allow. Never auto-approves from model output.
     */
    static async gateMissionApproval(
        goal: string,
        requireApproval: boolean,
        approver: MissionApprover | undefined,
    ): Promise<{ allowed: boolean; reason: string }> {
        if (!requireApproval) return { allowed: true, reason: 'approval-disabled' };
        if (!approver) {
            return { allowed: false, reason: 'mission-approval-required-but-no-approver' };
        }
        const ok = await approver(goal);
        return ok
            ? { allowed: true, reason: 'mission-approved' }
            : { allowed: false, reason: 'mission-declined' };
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
        // Q-523: a fresh kill-switch per run. (Pause state is deliberately NOT reset — see the Q-426
        // note: pre-run pause/override is a supported, tested setup.)
        this._abortController = new AbortController();
        // NB (Q-426, INTENTIONALLY not "fixed"): pause state is deliberately NOT reset here. Pausing (or
        // resuming with a manual override) BEFORE a run is a supported setup — start paused to review, or
        // seed the first step — pinned by the "blocks in the pause loop" + "applies a manual override"
        // tests. The code can't distinguish an intentional pre-run pause from a stale one, and the design
        // honors both; resetting here would break that contract. See docs/BUG_JOURNAL.md.
        // try/finally guarantees the running flag clears on EVERY exit — a throw used to leave it
        // stuck `true`, permanently dead-locking all future runAgentLoop() calls (H7).
        try {
            await this._runAgentLoop(goal, emitter, attachments, maxSteps, maxWallClockMs);
        } finally {
            this._isRunning = false;
            this._abortController = null;
            // Free the mission's KV-cache sequence (multi-hundred-MB on large contexts). Also resets
            // the prefix lineage so the NEXT mission's different goal/attachments start clean.
            this.llmProvider.releaseActionCache?.(AGENT_CACHE_KEY);
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
        // Q-549 Step 2: executed-action counter for the bulk brake (change volume, not runtime).
        let executedActions = 0;
        const bulkBrakeThreshold = AgentService.resolveBulkBrakeThreshold();

        // --- Intent Classification —  regex-first, LLM fallback ---
        // On embedded/constrained hardware, skip the LLM call entirely when
        // regex classification has high/medium confidence — saves 5-30s per request.
        emitter.emit('status', " Classifying intent...");
        try {
            const { classifyIntent } = await import('./intentClassifier.js');
            const regexResult = classifyIntent(goal);
            // Q-637 intent, now actually implemented: the LLM call exists ONLY to break a
            // low-confidence tie. A HIGH-confidence regex verdict skips it on EVERY tier — the old
            // gate skipped only on embedded/constrained, so powerful desktops paid a full inference
            // per mission to re-confirm what the regex already knew. Medium still gets the LLM
            // tiebreak on capable hardware (it can afford the check); constrained tiers trust it.
            const skipLlmClassification =
                regexResult.confidence === 'high' ||
                ((HW.tier === 'embedded' || HW.tier === 'constrained') && regexResult.confidence === 'medium');

            let isChat = false;
            if (skipLlmClassification) {
                // Everything except 'action' is knowledge mode. The old `=== 'chat'` mapped the
                // classifier's OTHER knowledge intents (math/code/image — the only HIGH-confidence
                // ones!) to isChat=false, sending "what is 2+2?" into device-tapping ACTION mode on
                // every tier that skipped the LLM tiebreak.
                isChat = regexResult.intent !== 'action';
            } else {
                const intentRaw = await this.llmProvider.generateAction(
                    INTENT_CLASSIFIER_PROMPT,
                    `User Request: "${goal}"`,
                    // Grammar-constrained to the two legal labels — a rambling model can no longer
                    // produce an unclassifiable answer that silently defaults the branch. Greedy:
                    // classification must be deterministic.
                    { maxTokens: 10, temperature: 0, jsonSchema: { type: "string", enum: ["ACTION", "CHAT"] } },
                    undefined,
                    this._abortController?.signal
                );
                isChat = intentRaw.trim().toUpperCase().includes("CHAT");
            }

            if (isChat) {
                emitter.emit('status', " Processing as General Intelligence (Bypassing ADB)...");
                const prompt = await this.promptBuilder.buildEnvironment(goal, "No active UI elements (Knowledge Mode)", [], "", attachments);
                const response = await this.llmProvider.generateAction(
                    "You are a helpful AI assistant. Answer the user's question directly and concisely based on the context provided. If you need to perform an action on the device, say so.",
                    prompt,
                    { maxTokens: 500, temperature: 0.7 },
                    undefined,
                    this._abortController?.signal
                );
                emitter.emit('status', response);
                emitter.emit('done');
                return;
            }
        } catch (e: unknown) {
            logger.error("[AgentService] Intent classification failed, defaulting to ACTION mode.", e);
        }

        // Q-549 Step 3: opt-in per-run mission approval — BEFORE any device observation/tap.
        // Knowledge/chat mode already returned above. Fail-closed when enabled without an approver.
        {
            const gate = await AgentService.gateMissionApproval(
                goal, this._requireMissionApproval, this._missionApprover);
            if (!gate.allowed) {
                emitter.emit('mission_approval', { goal });
                emitter.emit('status',
                    gate.reason === 'mission-declined'
                        ? ' Mission declined — device was not driven.'
                        : ' Mission approval required but no approver is configured — refusing to drive the device (fail-closed).');
                emitter.emit('error',
                    gate.reason === 'mission-declined'
                        ? 'You declined this mission. No device actions were taken.'
                        : 'Mission approval is enabled but no approver is wired. Configure setMissionApproval(true, approver).');
                emitter.emit('done');
                return;
            }
            if (gate.reason === 'mission-approved') {
                emitter.emit('mission_approval', { goal });
                emitter.emit('status', ' Mission approved — proceeding to drive the device.');
            }
        }

        let timedOut = false;
        // Q-523: hard-stop convenience — true once stop() has aborted this run.
        const stopped = () => this._abortController?.signal.aborted ?? false;
        if (stopped()) { emitter.emit('status', ' Stopped — you halted the agent.'); emitter.emit('done'); return; }
        while (step < maxSteps && !isDone) {
            // Q-523: hard-stop takes precedence over everything — a stop issued between steps ends the
            // mission immediately (the kill switch a LOCAL agent can offer that a cloud one can't).
            if (stopped()) { emitter.emit('status', ' Stopped — you halted the agent.'); break; }
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
            // Q-538/539: a hard-stop must break the pause wait too — otherwise stop() while paused would
            // spin here forever (stop() also clears _isPaused, so this loop exits either way).
            while (this._isPaused && !stopped()) {
                emitter.emit('status', " Agent paused for manual human correction. Waiting for resume...");
                await new Promise(r => setTimeout(r, 1000));
            }
            if (stopped()) { emitter.emit('status', ' Stopped — you halted the agent.'); break; }

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

            // The old "Autonomous Eye" step is GONE, deliberately. It asked the model to
            // "describe the elements visible on this screen" while passing the screenshot as a
            // TEXT path the model could never see — a guaranteed hallucination, injected into
            // every decision as if it were perception, at the price of a full extra inference
            // per step. Removing it makes each step both more truthful and ~2× faster.
            // Reintroduce only behind a provider that actually decodes image tokens.

            // 4. Build Prompt
            const prompt = await this.promptBuilder.buildEnvironment(goal, state.textRepresentation, actionHistory, "", attachments);

            emitter.emit('status', " Deciding next action...");

            // 5. Generate LLM Action
            let commandText: string;
            try {
                // SYSTEM_PROMPT on EVERY step. The old `step === 1 ? SYSTEM_PROMPT : ""` assumed a
                // persistent session, but generateAction builds a fresh one per call — so from step
                // 2 onward the model had NEVER seen the action schema and was improvising output
                // format from context. This single conditional was the largest source of erratic
                // agent behavior. The KV cacheKey makes the re-sent prompt near-free.
                commandText = await this.llmProvider.generateAction(
                    SYSTEM_PROMPT,
                    prompt,
                    // temperature 0 (greedy): with the grammar constraining STRUCTURE, sampling noise
                    // in the action CHOICE is pure downside — same screen + same goal should always
                    // decide the same action (also what the mobile twins' parity mindset expects).
                    { maxTokens: 150, temperature: 0, jsonSchema: ACTION_JSON_SCHEMA, cacheKey: AGENT_CACHE_KEY },
                    undefined,   // screenshot path removed: the provider has no vision — see the Eye note above
                    this._abortController?.signal
                );
            } catch (e: unknown) {
                // Q-523: a hard-stop lands mid-decode as LLM_CANCELLED — end the mission cleanly rather
                // than treating it as a model error. (The finally below still frees the screenshot.)
                if ((e as NodeJS.ErrnoException)?.code === 'LLM_CANCELLED') {
                    emitter.emit('status', ' Stopped — you halted the agent.');
                    break;
                }
                throw e;
            } finally {
                // Delete the step's screenshot to free /tmp space (2–5 MB per frame) on EVERY path.
                // (No LLM consumes it anymore — the uiVerifier still captures one per idle-wait.)
                // A throw in generateAction previously skipped the unlink and leaked the file until
                // the periodic temp sweep (deep-hunt).
                if (state.screenshotPath) {
                    fs.unlink(state.screenshotPath).catch(() => { /* already gone */ });
                }
            }
            emitter.emit('decide', commandText);

            // Hoisted so the outer catch can ledger a blocked/errored action (Q-549) — null on a pure
            // parse failure (nothing to record).
            let actionObj: ParsedAgentAction | null = null;
            try {
                // 6. Parse and Execute Action (Universal Tool Loop)
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
                    this.recordAction(actionObj, 'allowed', 'executed', goal);   // Q-549 flight recorder
                    // Q-549 Step 2 — the bulk brake: N executed actions is a CHANGE-VOLUME checkpoint
                    // the step/time caps don't provide. Self-pause and hand control to the human via
                    // the EXISTING pause/intervene channel (the top-of-step wait); Resume continues,
                    // Stop still hard-stops. Fires at every multiple so a long mission re-asks.
                    executedActions++;
                    if (bulkBrakeThreshold > 0 && executedActions % bulkBrakeThreshold === 0) {
                        this._isPaused = true;
                        emitter.emit('bulk_confirm', { executed: executedActions, threshold: bulkBrakeThreshold });
                        emitter.emit('status', ` Bulk brake: ${executedActions} device actions this mission. Paused for your OK — press Resume to continue, or Stop to end here.`);
                    }
                    // 7. Re-verify the UI after settling
                    const postState = await this.uiVerifier.waitForIdle(emitter);

                    // 8. Generate actionable contextual feedback for LLM
                    const verificationResult = await this.uiVerifier.verifyAction(actionObj as Partial<AgentAction>, preStateElements, postState.elements);
                    actionHistory.push(verificationResult);

                    expectedActionEffect = true;
                    // Overwrite the current loop state with the newly grabbed post-state so step #2 doesn't double dip
                    previousUiHash = postState.hash;
                } else {
                    this.recordAction(actionObj, 'failed', 'execute returned false', goal);
                    actionHistory.push(`[Failed] Failed to execute ${actionType}`);
                }

            } catch (err: unknown) {
                const message = err instanceof Error ? err.message : String(err);
                // Q-549: ledger a blocked (safety-refused) or errored action. Null actionObj = a pure parse
                // failure — no device action to record.
                if (actionObj) {
                    this.recordAction(actionObj, err instanceof SafetyViolationError ? 'blocked' : 'error', message, goal);
                }
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
