import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { EventEmitter } from 'events';
import { AgentService, AgentEventEmitter, firstJsonObject } from '../src/services/agent.service.js';
import { SafetyViolationError } from '../src/services/agent/actionExecutor.js';
import type { ILlmProvider, IDeviceProvider, UIElement } from '../src/types/index.js';
import type { UiParserService } from '../src/services/uiParser.service.js';
import type { MetricsService } from '../src/services/metrics.service.js';
import type { OcrService } from '../src/services/ocr.service.js';
import type { MemoryService } from '../src/services/memory.service.js';
import { createApp } from '../src/app.js';

// --- Mock factories ----------------------------------------------------------
// runAgentLoop builds PromptBuilder / ActionExecutor / UiVerifier internally from
// the injected collaborators. We inject light stubs for the constructor, then
// replace the three internal helpers with fakes so the loop is fully deterministic
// (no ADB, no OCR, no real LLM, no disk I/O).

function makeUiElement(id: number, text = `el-${id}`): UIElement {
    return {
        id,
        text,
        contentDesc: '',
        className: 'android.widget.Button',
        resourceId: '',
        clickable: true,
        scrollable: false,
        focusable: true,
        enabled: true,
        visible: true,
        bounds: '[0,0][100,100]',
        center: { x: 50, y: 50 },
        rect: { x: 0, y: 0, width: 100, height: 100 },
    };
}

function createLlmStub(overrides: Partial<ILlmProvider> = {}): ILlmProvider {
    const emitter = new EventEmitter();
    return Object.assign(emitter, {
        generalChat: vi.fn().mockResolvedValue({ text: '', meta: {} }),
        generateAction: vi.fn().mockResolvedValue('{"action":"done"}'),
        isCurrentlyGenerating: vi.fn().mockReturnValue({ isGenerating: false, buffer: '' }),
        ...overrides,
    }) as unknown as ILlmProvider;
}

function createDeviceStub(): IDeviceProvider {
    const emitter = new EventEmitter();
    return Object.assign(emitter, {
        click: vi.fn().mockResolvedValue(undefined),
        type: vi.fn().mockResolvedValue(undefined),
        scroll: vi.fn().mockResolvedValue(undefined),
        pressKey: vi.fn().mockResolvedValue(undefined),
        getScreenContext: vi.fn().mockResolvedValue({ xml: '<node/>', screenshotPath: '' }),
    }) as unknown as IDeviceProvider;
}

function createMemoryStub(overrides: Partial<MemoryService> = {}): MemoryService {
    return {
        findSimilarGoal: vi.fn().mockResolvedValue(null),
        findRelevantCorrections: vi.fn().mockResolvedValue([]),
        saveTrajectory: vi.fn().mockResolvedValue(undefined),
        injectOverride: vi.fn().mockResolvedValue(undefined),
        ...overrides,
    } as unknown as MemoryService;
}

function createMetricsStub(): MetricsService {
    return {
        appendMetrics: vi.fn().mockResolvedValue(undefined),
        getMetrics: vi.fn().mockResolvedValue([]),
    } as unknown as MetricsService;
}

/**
 * Build an AgentService with all heavy collaborators faked.
 * `verifierState` controls what each waitForIdle() call returns (one entry per call,
 * last entry repeats). `executeResult` controls ActionExecutor.execute().
 */
function buildAgent(opts: {
    llm?: ILlmProvider;
    memory?: MemoryService;
    metrics?: MetricsService;
    verifierStates?: Array<{ elements: UIElement[]; textRepresentation: string; hash: string; screenshotPath: string }>;
    executeResult?: boolean;
} = {}) {
    const llm = opts.llm ?? createLlmStub();
    const memory = opts.memory ?? createMemoryStub();
    const metrics = opts.metrics ?? createMetricsStub();
    const device = createDeviceStub();
    const uiParser = {} as unknown as UiParserService;
    const ocr = {} as unknown as OcrService;

    const agent = new AgentService(llm, device, uiParser, metrics, ocr, memory);

    const states = opts.verifierStates ?? [
        { elements: [makeUiElement(1)], textRepresentation: '<node id=1/>', hash: 'h1', screenshotPath: '' },
    ];
    let callIdx = 0;
    const waitForIdle = vi.fn().mockImplementation(() => {
        const state = states[Math.min(callIdx, states.length - 1)];
        callIdx++;
        return Promise.resolve(state);
    });
    const verifyAction = vi.fn().mockResolvedValue('[Success] Executed.');
    const execute = vi.fn().mockResolvedValue(opts.executeResult ?? true);
    const buildEnvironment = vi.fn().mockResolvedValue('PROMPT');

    // Replace internal helpers with fakes.
    (agent as any).uiVerifier = { waitForIdle, verifyAction };
    (agent as any).actionExecutor = {
        execute,
        // Keep the real safety gate semantics: throw on a destructive goal.
        assertGoalSafe: (goal: string) => {
            if (/\b(wipe|factory reset|delete|pay|transfer)\b/i.test(goal)) {
                throw new Error(`Safety Block: '${goal}'`);
            }
        },
    };
    (agent as any).promptBuilder = { buildEnvironment };

    return { agent, llm, memory, metrics, device, waitForIdle, verifyAction, execute, buildEnvironment };
}

/** Collect every event the loop emits, keyed by event name. */
function captureEvents(emitter: AgentEventEmitter) {
    const events: Record<string, unknown[]> = {};
    const names = ['status', 'error', 'observe', 'decide', 'action', 'done'] as const;
    for (const name of names) {
        events[name] = [];
        emitter.on(name as any, (...args: unknown[]) => events[name].push(args.length === 1 ? args[0] : args));
    }
    return events;
}

describe('AgentService.runAgentLoop — integration', () => {
    let prevMaxSteps: string | undefined;
    beforeEach(() => {
        // Force a fixed step budget independent of the host hardware tier.
        prevMaxSteps = process.env.QUENDERIN_MAX_AGENT_STEPS;
        process.env.QUENDERIN_MAX_AGENT_STEPS = '5';
    });
    afterEach(() => {
        if (prevMaxSteps === undefined) delete process.env.QUENDERIN_MAX_AGENT_STEPS;
        else process.env.QUENDERIN_MAX_AGENT_STEPS = prevMaxSteps;
    });

    it('runs to completion when the LLM immediately returns a done action', async () => {
        const llm = createLlmStub({ generateAction: vi.fn().mockResolvedValue('{"action":"done"}') });
        const { agent, metrics } = buildAgent({ llm });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('Open the settings app', emitter, [], 5);

        expect(events.done.length).toBe(1);
        expect(events.action).toContain('DONE');
        // Success metrics recorded exactly once.
        expect(metrics.appendMetrics).toHaveBeenCalledTimes(1);
        expect((metrics.appendMetrics as any).mock.calls[0][0]).toMatchObject({ success: true, total_steps: 1 });
        // isRunning flag is cleared after the loop (try/finally guard, H7).
        expect(agent.isRunning).toBe(false);
    });

    it('executes a click action then completes on the next step', async () => {
        // No screenshotPath on the verifier states below, so the eye-description LLM call is skipped;
        // the queue is just: intent, step-1 decision, step-2 decision.
        const generateAction = vi
            .fn()
            .mockResolvedValueOnce('ACTION') // intent classification (LLM fallback on non-embedded host)
            .mockResolvedValueOnce('{"action":"click","id":1}') // step 1 decision
            .mockResolvedValueOnce('{"action":"done"}'); // step 2 decision
        const llm = createLlmStub({ generateAction });
        const { agent, execute } = buildAgent({
            llm,
            verifierStates: [
                { elements: [makeUiElement(1)], textRepresentation: '<a/>', hash: 'h1', screenshotPath: '' },
                { elements: [makeUiElement(2)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
                { elements: [makeUiElement(2)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
            ],
        });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('Tap the button', emitter, [], 5);

        expect(execute).toHaveBeenCalledTimes(1);
        expect(events.done.length).toBe(1);
        expect(events.decide.length).toBe(2);
    });

    it('Q-560: stop() hard-stops the legacy AgentService loop mid-run — no further steps run', async () => {
        // The planner would keep clicking every step; the user hits Stop WHILE step 1 executes. The loop's
        // step-top stopped() check must then break before step 2 — the legacy-AgentService twin of the
        // capability kill switch (tests/kill-switch.test.ts covered only the CapabilityRunner/Agent path).
        const generateAction = vi.fn()
            .mockResolvedValueOnce('ACTION')                    // intent classification
            .mockResolvedValue('{"action":"click","id":1}');    // every step decision
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({
            llm,
            verifierStates: [
                { elements: [makeUiElement(1)], textRepresentation: '<a/>', hash: 'h1', screenshotPath: '' },
                { elements: [makeUiElement(1)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
            ],
        });
        const execSpy = vi.fn().mockImplementation(async () => { agent.stop(); return true; });
        (agent as any).actionExecutor.execute = execSpy;
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('open the settings screen', emitter, [], 5);

        expect(execSpy).toHaveBeenCalledTimes(1);              // step 1 ran; step 2 never started
        expect(agent.isRunning).toBe(false);                  // controller cleared on exit
        expect(events.status.some((s: unknown) => String(s).includes('Stopped'))).toBe(true);
    });

    it('Q-549: records each executed device action in the audit ledger with its decision + goal', async () => {
        const generateAction = vi.fn()
            .mockResolvedValueOnce('ACTION')                      // intent
            .mockResolvedValueOnce('{"action":"click","id":1}')   // step 1 → executes
            .mockResolvedValueOnce('{"action":"done"}');          // step 2 → done
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({
            llm,
            verifierStates: [
                { elements: [makeUiElement(1)], textRepresentation: '<a/>', hash: 'h1', screenshotPath: '' },
                { elements: [makeUiElement(1)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
                { elements: [makeUiElement(1)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
            ],
        });
        const emitter1 = new AgentEventEmitter();
        captureEvents(emitter1);   // attaches an 'error' listener so benign self-healing warnings don't throw
        await agent.runAgentLoop('open the settings screen', emitter1, [], 5);
        const entries = agent.actionLedger.entries();
        expect(entries).toHaveLength(1);   // the 'done' action isn't a device action
        expect(entries[0]).toMatchObject({ capability: 'device.click', decision: 'allowed', input: 'id=1', goal: 'open the settings screen' });
    });

    it('Q-549: records a safety-refused action as "blocked"', async () => {
        const generateAction = vi.fn()
            .mockResolvedValueOnce('ACTION')
            .mockResolvedValue('{"action":"click","id":1}');
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({ llm });
        // The executor refuses the action (a destructive target) by throwing — the loop must ledger it.
        (agent as unknown as { actionExecutor: { execute: unknown } }).actionExecutor.execute =
            vi.fn().mockRejectedValue(new SafetyViolationError('Safety Block: nope'));
        const emitter2 = new AgentEventEmitter();
        captureEvents(emitter2);
        await agent.runAgentLoop('tap something', emitter2, [], 1);
        const entries = agent.actionLedger.entries();
        expect(entries.some(e => e.decision === 'blocked' && e.capability === 'device.click')).toBe(true);
    });

    it('stops with a wall-clock timeout before exhausting the step budget', async () => {
        // generateAction would keep clicking forever; the wall-clock budget (0 ms = already past)
        // must stop the loop before a single step runs. (Audit: no overall wall-clock timeout.)
        const generateAction = vi.fn().mockResolvedValue('{"action":"click","id":1}');
        const llm = createLlmStub({ generateAction });
        const { agent, metrics } = buildAgent({ llm });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('Do something slow', emitter, [], 5, 0);

        expect(events.done.length).toBe(1);
        expect(events.error.some((e: unknown) => String(e).includes('Timed Out'))).toBe(true);
        // Bailed before any step → 0 steps, failure metric recorded once.
        const lastMetric = (metrics.appendMetrics as any).mock.calls.at(-1)?.[0];
        expect(lastMetric).toMatchObject({ success: false, total_steps: 0 });
        expect(agent.isRunning).toBe(false);
    });

    it('refuses a destructive goal before any step runs', async () => {
        const llm = createLlmStub();
        const { agent, metrics } = buildAgent({ llm });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('factory reset the phone', emitter, [], 5);

        expect(events.error.length).toBe(1);
        expect(String(events.error[0])).toContain('Safety Block');
        expect(events.done.length).toBe(1);
        // No metrics, no LLM call — we bailed before the loop.
        expect(metrics.appendMetrics).not.toHaveBeenCalled();
        expect(llm.generateAction).not.toHaveBeenCalled();
    });

    it('ignores a duplicate start while a loop is already running', async () => {
        // A generateAction that blocks until we release it keeps the first loop "running".
        let release: () => void = () => {};
        const gate = new Promise<void>((r) => { release = r; });
        const generateAction = vi.fn().mockImplementation(async () => {
            await gate;
            return '{"action":"done"}';
        });
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({ llm });

        const e1 = new AgentEventEmitter();
        e1.on('error', () => {}); // swallow self-healing error emits (EventEmitter throws otherwise)
        const first = agent.runAgentLoop('goal one', e1, [], 5);
        // Let the first loop reach (and block on) its intent-classification LLM call.
        await new Promise((r) => setTimeout(r, 20));
        const callsAfterFirst = generateAction.mock.calls.length;
        expect(callsAfterFirst).toBeGreaterThanOrEqual(1);

        // Second call must short-circuit because _isRunning is true — no new LLM calls.
        await agent.runAgentLoop('goal two', new AgentEventEmitter(), [], 5);
        expect(generateAction.mock.calls.length).toBe(callsAfterFirst);
        expect(agent.isRunning).toBe(true);

        release();
        await first;
        expect(agent.isRunning).toBe(false);
    });

    it('records a timeout (failure metrics) when max steps are exhausted without done', async () => {
        // Never returns done — always asks to scroll.
        const generateAction = vi.fn().mockResolvedValue('{"action":"scroll","direction":"down"}');
        const llm = createLlmStub({ generateAction });
        const { agent, metrics } = buildAgent({ llm });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('do something endless', emitter, [], 2);

        expect(events.error.some((e) => String(e).includes('Task Too Complex'))).toBe(true);
        expect(metrics.appendMetrics).toHaveBeenCalledTimes(1);
        expect((metrics.appendMetrics as any).mock.calls[0][0]).toMatchObject({ success: false });
    });

    it('Q-549 Step 2: the bulk brake self-pauses after N executed actions; Resume continues', async () => {
        // maxSteps/wall-clock bound RUNTIME; the brake bounds CHANGE VOLUME. With the threshold at 2,
        // the second executed click must emit bulk_confirm with the loop SELF-paused; resume() then
        // lets the mission finish. Mirrors the capability runner's passesBulkGuard, on the legacy loop.
        const prevBrake = process.env.QUENDERIN_BULK_BRAKE_ACTIONS;
        process.env.QUENDERIN_BULK_BRAKE_ACTIONS = '2';
        try {
            const generateAction = vi.fn()
                .mockResolvedValueOnce('ACTION')                     // intent classification
                .mockResolvedValueOnce('{"action":"click","id":1}')  // step 1 — executed
                .mockResolvedValueOnce('{"action":"click","id":1}')  // step 2 — executed → brake fires
                .mockResolvedValueOnce('{"action":"done"}');         // step 3 — after resume
            const llm = createLlmStub({ generateAction });
            const { agent, execute } = buildAgent({ llm });
            const emitter = new AgentEventEmitter();
            const events = captureEvents(emitter);

            const brakes: Array<{ executed: number; threshold: number }> = [];
            let pausedAtBrake = false;
            emitter.on('bulk_confirm' as any, (payload: { executed: number; threshold: number }) => {
                brakes.push(payload);
                pausedAtBrake = agent.isPaused;   // the brake must have parked the loop…
                agent.resume();                    // …and the user's Resume must release it
            });

            await agent.runAgentLoop('tap through the list', emitter, [], 5);

            expect(brakes).toEqual([{ executed: 2, threshold: 2 }]);
            expect(pausedAtBrake).toBe(true);
            expect(execute).toHaveBeenCalledTimes(2);      // two clicks; 'done' executes nothing
            expect(events.done.length).toBe(1);            // the mission still completed after Resume
            expect(agent.isPaused).toBe(false);
        } finally {
            if (prevBrake === undefined) delete process.env.QUENDERIN_BULK_BRAKE_ACTIONS;
            else process.env.QUENDERIN_BULK_BRAKE_ACTIONS = prevBrake;
        }
    });
});

describe('AgentService — pause / resume', () => {
    let prevMaxSteps: string | undefined;
    beforeEach(() => {
        prevMaxSteps = process.env.QUENDERIN_MAX_AGENT_STEPS;
        process.env.QUENDERIN_MAX_AGENT_STEPS = '5';
    });
    afterEach(() => {
        if (prevMaxSteps === undefined) delete process.env.QUENDERIN_MAX_AGENT_STEPS;
        else process.env.QUENDERIN_MAX_AGENT_STEPS = prevMaxSteps;
    });

    it('pause() / resume() toggle the isPaused flag', () => {
        const { agent } = buildAgent();
        expect(agent.isPaused).toBe(false);
        agent.pause();
        expect(agent.isPaused).toBe(true);
        agent.resume();
        expect(agent.isPaused).toBe(false);
    });

    it('blocks in the pause loop and resumes when unpaused', async () => {
        // Decision returns scroll forever so the loop keeps spinning until max steps.
        const generateAction = vi.fn().mockResolvedValue('{"action":"scroll","direction":"down"}');
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({ llm });

        agent.pause();
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        const run = agent.runAgentLoop('keep going', emitter, [], 1);

        // Give the loop time to reach the pause wait (1s poll interval inside the loop).
        await new Promise((r) => setTimeout(r, 50));
        expect(agent.isPaused).toBe(true);
        // The pause check sits before the LLM *decision* — no 'decide' event must fire while paused.
        expect(events.decide.length).toBe(0);
        expect((events.status as string[]).some((s) => s.includes('paused'))).toBe(true);

        agent.resume();
        await run;
        expect(agent.isPaused).toBe(false);
        // After resume the decision is reached at least once.
        expect(events.decide.length).toBeGreaterThanOrEqual(1);
    });

    it('applies a manual override and injects it into memory, skipping the LLM decision', async () => {
        const injectOverride = vi.fn().mockResolvedValue(undefined);
        const memory = createMemoryStub({ injectOverride });
        // Step 1 applies the override and `continue`s (no eye/decision call). Step 2 reaches the
        // LLM and returns done. The default fallback covers the eye call in step 2.
        const generateAction = vi
            .fn()
            .mockResolvedValueOnce('ACTION') // intent classification
            .mockResolvedValue('{"action":"done"}'); // step 2 eye + decision (done ends the loop)
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({
            llm,
            memory,
            // Distinct hashes per waitForIdle call so the override step doesn't trip the
            // "UI did not respond" self-healing path.
            verifierStates: [
                { elements: [makeUiElement(1)], textRepresentation: '<a/>', hash: 'h1', screenshotPath: '' },
                { elements: [makeUiElement(2)], textRepresentation: '<b/>', hash: 'h2', screenshotPath: '' },
                { elements: [makeUiElement(3)], textRepresentation: '<c/>', hash: 'h3', screenshotPath: '' },
            ],
        });

        agent.pause();
        agent.resume('click the blue Login button');

        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('log me in', emitter, [], 5);

        expect(injectOverride).toHaveBeenCalledTimes(1);
        const [goalArg, , overrideArg] = injectOverride.mock.calls[0];
        expect(goalArg).toBe('log me in');
        expect(overrideArg).toBe('click the blue Login button');
        expect((events.status as string[]).some((s) => s.includes('Human Override'))).toBe(true);
    });

    it('Q-523: stop() hard-stops a running mission mid-loop', async () => {
        let n = 0;
        let agentRef: AgentService;
        // Decision returns scroll forever (would run to maxSteps); fire the kill switch on step 1's decide.
        const generateAction = vi.fn().mockImplementation(async () => {
            n++;
            if (n === 3) agentRef.stop();
            return '{"action":"scroll","direction":"down"}';
        });
        const { agent } = buildAgent({ llm: createLlmStub({ generateAction }) });
        agentRef = agent;

        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);
        await agent.runAgentLoop('keep scrolling', emitter, [], 10);

        // Stopped early — nowhere near maxSteps=10 (~2 generateAction calls per step), Stopped status fired.
        expect(generateAction.mock.calls.length).toBeLessThan(6);
        expect((events.status as string[]).some((s) => s.includes('Stopped'))).toBe(true);
        expect(agent.isRunning).toBe(false);
    });

    // ─── Sober-agent regressions (2026-07-07 engine overhaul) ────────────────
    // These pin the fixes for the three defects that made the agent erratic:
    //  1. SYSTEM_PROMPT was sent only on step 1 while sessions are per-call → steps 2+ never saw
    //     the action schema.  2. A per-step "eye" call hallucinated screen descriptions from an
    //     image the model can't see.  3. Output was unconstrained text scraped by regex.

    it('sends the action SYSTEM_PROMPT + JSON schema + cacheKey on EVERY decision step, not just step 1', async () => {
        const generateAction = vi.fn()
            .mockResolvedValueOnce('{"action":"done"}')                       // intent classifier tiebreak
            .mockResolvedValueOnce('{"action":"click","id":1}')               // step 1 decision
            .mockResolvedValueOnce('{"action":"click","id":1}')               // step 2 decision
            .mockResolvedValue('{"action":"done"}');                          // step 3 decision
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({ llm });

        const emitter = new AgentEventEmitter();
        captureEvents(emitter);   // registers an 'error' listener — a bare emitter would throw on it
        await agent.runAgentLoop('open settings', emitter, [], 5);

        // Decision calls are the ones prompted with the (stubbed) built environment.
        const decisionCalls = generateAction.mock.calls.filter((c) => c[1] === 'PROMPT');
        expect(decisionCalls.length).toBeGreaterThanOrEqual(2);
        for (const call of decisionCalls) {
            expect(call[0]).toContain('Valid actions');                       // schema-bearing system prompt, every step
            // Grammar constraint requested, shaped oneOf-per-variant (a flat object schema makes
            // the GBNF grammar emit EVERY property — junk fields on every action, live-caught).
            expect(Array.isArray(call[2]?.jsonSchema?.oneOf)).toBe(true);
            expect(typeof call[2]?.cacheKey).toBe('string');                  // KV prefix reuse requested
        }
    });

    it('never passes a screenshot to the LLM and makes no per-step eye call (vision is not wired)', async () => {
        const generateAction = vi.fn()
            .mockResolvedValueOnce('{"action":"done"}')                       // intent classifier
            .mockResolvedValueOnce('{"action":"click","id":1}')               // step 1
            .mockResolvedValue('{"action":"done"}');                          // step 2
        const llm = createLlmStub({ generateAction });
        const { agent } = buildAgent({
            llm,
            verifierStates: [
                // screenshotPath present — the old code fired an extra "describe this screen"
                // inference per step and fed the model a text path it hallucinated against.
                { elements: [makeUiElement(1)], textRepresentation: '<node id=1/>', hash: 'h1', screenshotPath: '/tmp/does-not-exist-shot.png' },
                { elements: [makeUiElement(2)], textRepresentation: '<node id=2/>', hash: 'h2', screenshotPath: '/tmp/does-not-exist-shot.png' },
            ],
        });

        const emitter = new AgentEventEmitter();
        captureEvents(emitter);   // registers an 'error' listener — a bare emitter would throw on it
        await agent.runAgentLoop('open settings', emitter, [], 5);

        // 1 intent + 2 decisions = 3 calls. The old eye path added one MORE call per step.
        expect(generateAction.mock.calls.length).toBe(3);
        for (const call of generateAction.mock.calls) {
            expect(call[3]).toBeUndefined();                                  // no imagePath ever reaches the LLM
        }
    });

    it('routes a high-confidence knowledge goal (math) to knowledge mode with ZERO extra inference', async () => {
        // "what is 17 * 23" → regex intent 'math', HIGH confidence. Two regressions pinned at once:
        //  • high-confidence regex skips the LLM tiebreak on EVERY tier (old gate: embedded only,
        //    so desktops paid one full inference per mission to re-confirm the regex);
        //  • non-'action' intents map to knowledge mode (old `=== 'chat'` sent math/code/image —
        //    the only HIGH-confidence intents — into device-tapping ACTION mode).
        const generateAction = vi.fn().mockResolvedValue('The answer is 391.');
        const llm = createLlmStub({ generateAction });
        const { agent, waitForIdle } = buildAgent({ llm });
        const emitter = new AgentEventEmitter();
        const events = captureEvents(emitter);

        await agent.runAgentLoop('what is 17 * 23?', emitter, [], 5);

        expect(generateAction).toHaveBeenCalledTimes(1);          // ONLY the knowledge-mode answer
        expect(generateAction.mock.calls[0][0]).toContain('helpful AI assistant');
        expect(waitForIdle).not.toHaveBeenCalled();               // no device interaction at all
        expect(events.done.length).toBe(1);
        expect((events.status as string[]).some(s => s.includes('The answer is 391.'))).toBe(true);
    });

    it('releases the mission KV cache (releaseActionCache) exactly once when the run ends', async () => {
        const releaseActionCache = vi.fn();
        const llm = createLlmStub({ releaseActionCache } as Partial<ILlmProvider>);
        const { agent } = buildAgent({ llm });

        await agent.runAgentLoop('open settings', new AgentEventEmitter(), [], 5);

        expect(releaseActionCache).toHaveBeenCalledTimes(1);
        expect(releaseActionCache).toHaveBeenCalledWith('agent-mission');
    });
});

describe('app.ts — pause/resume HTTP routes', () => {
    const TEST_TOKEN = 'test-auth-token-deadbeef';
    const AUTH = { 'X-Auth-Token': TEST_TOKEN };   // state-changing routes require the launch token (HIGH #1)
    let agentStub: { pause: ReturnType<typeof vi.fn>; resume: ReturnType<typeof vi.fn> };
    let baseUrl: string;
    let server: import('http').Server;

    beforeEach(async () => {
        agentStub = { pause: vi.fn(), resume: vi.fn() };
        const app = createApp(undefined, agentStub as unknown as AgentService, undefined, undefined, undefined, TEST_TOKEN);
        await new Promise<void>((resolve) => {
            server = app.listen(0, () => resolve());
        });
        const addr = server.address();
        const port = typeof addr === 'object' && addr ? addr.port : 0;
        baseUrl = `http://127.0.0.1:${port}`;
    });

    afterEach(() => {
        server?.close();
    });

    it('POST /api/agent/intervene pauses the agent', async () => {
        const res = await fetch(`${baseUrl}/api/agent/intervene`, { method: 'POST', headers: AUTH });
        const body = await res.json();
        expect(res.status).toBe(200);
        expect(body.message).toContain('paused');
        expect(agentStub.pause).toHaveBeenCalledTimes(1);
    });

    it('POST /api/agent/resume resumes and forwards a string manualAction', async () => {
        const res = await fetch(`${baseUrl}/api/agent/resume`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', ...AUTH },
            body: JSON.stringify({ manualAction: 'tap the Continue button' }),
        });
        const body = await res.json();
        expect(res.status).toBe(200);
        expect(agentStub.resume).toHaveBeenCalledTimes(1);
        expect(agentStub.resume).toHaveBeenCalledWith('tap the Continue button');
        expect(body.manualAction).toBe('tap the Continue button');
    });

    it('POST /api/agent/resume ignores a non-string manualAction (injection guard, M7/L7)', async () => {
        const res = await fetch(`${baseUrl}/api/agent/resume`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', ...AUTH },
            body: JSON.stringify({ manualAction: { evil: 'object' } }),
        });
        const body = await res.json();
        expect(res.status).toBe(200);
        // Non-string is dropped → resume called with undefined.
        expect(agentStub.resume).toHaveBeenCalledWith(undefined);
        expect(body.manualAction).toBeUndefined();
    });

    it('POST /api/agent/resume caps an over-long manualAction at 4000 chars', async () => {
        const huge = 'a'.repeat(5000);
        const res = await fetch(`${baseUrl}/api/agent/resume`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', ...AUTH },
            body: JSON.stringify({ manualAction: huge }),
        });
        await res.json();
        expect(res.status).toBe(200);
        const forwarded = agentStub.resume.mock.calls[0][0] as string;
        expect(forwarded.length).toBe(4000);
    });

    it('rejects a state-changing request without the auth token (HIGH #1)', async () => {
        const noToken = await fetch(`${baseUrl}/api/agent/intervene`, { method: 'POST' });
        expect(noToken.status).toBe(401);
        const badToken = await fetch(`${baseUrl}/api/agent/intervene`, { method: 'POST', headers: { 'X-Auth-Token': 'wrong' } });
        expect(badToken.status).toBe(401);
        expect(agentStub.pause).not.toHaveBeenCalled();   // never reached the handler
        // ?token= query also works (the opened-URL/browser delivery path).
        const viaQuery = await fetch(`${baseUrl}/api/agent/intervene?token=${TEST_TOKEN}`, { method: 'POST' });
        expect(viaQuery.status).toBe(200);
    });
});

// firstJsonObject: the action-parsing fix (H13). The model often wraps its JSON action in prose or
// emits more than one object; first-`{`..last-`}` over-extends and JSON.parse throws, dropping a valid
// action. Walking braces takes the FIRST complete object — matching the mobile AgentDecisionParser.
describe('firstJsonObject', () => {
    it('extracts the first complete object, ignoring a trailing second object or prose', () => {
        expect(firstJsonObject('{"action":"tap","id":5} then {"action":"done"}'))
            .toBe('{"action":"tap","id":5}');
        expect(firstJsonObject('Here is my action: {"action":"swipe","direction":"up"}. Done.'))
            .toBe('{"action":"swipe","direction":"up"}');
    });
    it('handles nested objects and braces inside strings', () => {
        expect(firstJsonObject('{"action":"type","text":"a } b","meta":{"k":1}}'))
            .toBe('{"action":"type","text":"a } b","meta":{"k":1}}');
    });
    it('returns null when there is no object / no closing brace', () => {
        expect(firstJsonObject('no json here')).toBeNull();
        expect(firstJsonObject('{"action":"tap"')).toBeNull();   // unterminated
    });
});
