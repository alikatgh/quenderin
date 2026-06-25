import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { EventEmitter } from 'events';
import { AgentService, AgentEventEmitter } from '../src/services/agent.service.js';
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
});

describe('app.ts — pause/resume HTTP routes', () => {
    let agentStub: { pause: ReturnType<typeof vi.fn>; resume: ReturnType<typeof vi.fn> };
    let baseUrl: string;
    let server: import('http').Server;

    beforeEach(async () => {
        agentStub = { pause: vi.fn(), resume: vi.fn() };
        const app = createApp(undefined, agentStub as unknown as AgentService);
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
        const res = await fetch(`${baseUrl}/api/agent/intervene`, { method: 'POST' });
        const body = await res.json();
        expect(res.status).toBe(200);
        expect(body.message).toContain('paused');
        expect(agentStub.pause).toHaveBeenCalledTimes(1);
    });

    it('POST /api/agent/resume resumes and forwards a string manualAction', async () => {
        const res = await fetch(`${baseUrl}/api/agent/resume`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
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
            headers: { 'content-type': 'application/json' },
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
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ manualAction: huge }),
        });
        await res.json();
        expect(res.status).toBe(200);
        const forwarded = agentStub.resume.mock.calls[0][0] as string;
        expect(forwarded.length).toBe(4000);
    });
});
