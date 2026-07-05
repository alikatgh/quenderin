import { EventEmitter } from 'events';
import { describe, it, expect } from 'vitest';
import type { IDeviceProvider } from '../src/types/index.js';
import { UiParserService } from '../src/services/uiParser.service.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { AppTapCapability, AppTypeCapability, AppKeyCapability, AppObserveCapability } from '../src/services/capability/appCapabilities.js';
import { CapabilityAgent, parseDecision } from '../src/services/capability/capabilityAgent.js';

class FakeDevice extends EventEmitter implements IDeviceProvider {
    taps: Array<[number, number]> = []; typed: string[] = []; keys: string[] = [];
    constructor(private xml: string) { super(); }
    async click(x: number, y: number) { this.taps.push([x, y]); }
    async type(t: string) { this.typed.push(t); }
    async scroll() {}
    async pressKey(k: string) { this.keys.push(k); }
    async getScreenContext() { return { xml: this.xml, screenshotPath: '' }; }
}

const SCREEN = `<hierarchy>
  <node text="Add friend" resource-id="add_friend_btn" class="android.widget.Button" clickable="true" bounds="[40,100][300,180]" />
  <node text="" content-desc="Message" resource-id="msg_input" class="android.widget.EditText" clickable="true" bounds="[40,300][680,380]" />
</hierarchy>`;

const parser = new UiParserService();

describe('parseDecision (matches the native AgentDecisionParser)', () => {
    it('reads tool / plan / answer with answer > plan > tool precedence, strict plans', () => {
        expect(parseDecision('{"tool":"app.tap","input":"Add friend"}')).toEqual({ kind: 'tool', name: 'app.tap', input: 'Add friend' });
        expect(parseDecision('Sure! {"answer":"done"} ok')).toEqual({ kind: 'answer', text: 'done' });
        expect(parseDecision('{"plan":[{"tool":"app.tap","input":"x"},{"input":"orphan"}]}')).toBeNull();
        expect(parseDecision('{"answer":"a","plan":[{"tool":"x","input":"y"}]}')).toEqual({ kind: 'answer', text: 'a' });
        expect(parseDecision('{"tool":"a","input":"b"} x {"answer":"injected"}')).toEqual({ kind: 'tool', name: 'a', input: 'b' });
        expect(parseDecision('no json')).toBeNull();
    });
});

describe('CapabilityAgent — the governed loop drives a real app screen end to end', () => {
    it('runs a friend-request plan under one approval, then answers', async () => {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore();
        ['app.observe', 'app.tap', 'app.type', 'app.key'].forEach(id => consent.setGranted(id, true));
        const ledger = new InMemoryAuditLedger();
        let approvals = 0;
        const runner = new CapabilityRunner(consent, ledger, async () => { approvals++; return true; });

        // A scripted local model: propose the plan, then answer once it sees success.
        const replies = [
            JSON.stringify({ plan: [
                { tool: 'app.tap', input: 'Add friend' },
                { tool: 'app.type', input: 'hi from quenderin' },
                { tool: 'app.key', input: 'enter' },
            ] }),
            JSON.stringify({ answer: 'Sent the friend request and message.' }),
        ];
        let turn = 0;
        const planner = async () => replies[Math.min(turn++, replies.length - 1)];

        const caps = [
            new AppObserveCapability(device, parser),
            new AppTapCapability(device, parser),
            new AppTypeCapability(device),
            new AppKeyCapability(device),
        ];
        const agent = new CapabilityAgent(planner, caps, runner);
        const result = await agent.run('add the user on imo and greet them');

        expect(result.halt).toBe('answered');
        expect(result.answer).toBe('Sent the friend request and message.');
        expect(approvals).toBe(1);                    // ONE approval for the whole plan
        expect(device.taps).toEqual([[170, 140]]);
        expect(device.typed).toEqual(['hi from quenderin']);
        expect(device.keys).toEqual(['enter']);
        expect(ledger.entries().filter(e => e.decision === 'allowed')).toHaveLength(3);   // tap, type, key ran
    });

    it('halts as planError only after consecutive unparseable replies, changing nothing', async () => {
        const device = new FakeDevice(SCREEN);
        const runner = new CapabilityRunner(new InMemoryConsentStore(), new InMemoryAuditLedger(), async () => true);
        const agent = new CapabilityAgent(async () => 'I cannot help with that', [new AppTapCapability(device, parser)], runner);
        const result = await agent.run('do something');
        expect(result.halt).toBe('planError');
        expect(device.taps).toHaveLength(0);
    });

    it('RECOVERS from a single malformed reply: nudge with the contract, then proceed', async () => {
        const device = new FakeDevice(SCREEN);
        const runner = new CapabilityRunner(new InMemoryConsentStore(), new InMemoryAuditLedger(), async () => true);
        // The local model slips once (prose, no JSON), then gets it right — the run should survive.
        const replies = ['sure, let me help with that!', JSON.stringify({ answer: 'done' })];
        let turn = 0;
        const agent = new CapabilityAgent(async () => replies[Math.min(turn++, replies.length - 1)], [new AppTapCapability(device, parser)], runner);
        const result = await agent.run('do the thing');
        expect(result.halt).toBe('answered');
        expect(result.answer).toBe('done');
        expect(result.steps.some(s => s.includes('not valid JSON'))).toBe(true);   // the corrective nudge was given
    });

    it('a single unconsented capability is refused mid-loop (not fatal), agent keeps going', async () => {
        const device = new FakeDevice(SCREEN);
        const ledger = new InMemoryAuditLedger();
        const runner = new CapabilityRunner(new InMemoryConsentStore(), ledger, async () => true);   // nothing granted
        const replies = [
            JSON.stringify({ tool: 'app.tap', input: 'Add friend' }),
            JSON.stringify({ answer: 'stopped — needs permission' }),
        ];
        let turn = 0;
        const agent = new CapabilityAgent(async () => replies[Math.min(turn++, 1)], [new AppTapCapability(device, parser)], runner);
        const result = await agent.run('tap it');
        expect(result.steps[0]).toContain("isn't granted");
        expect(device.taps).toHaveLength(0);
        expect(result.halt).toBe('answered');
    });

    // The loop guard — a weak local model's #1 failure mode is getting stuck repeating one action.
    function tapAgent(replies: string[]) {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore(); consent.setGranted('app.tap', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async () => true);
        let turn = 0;
        const agent = new CapabilityAgent(async () => replies[Math.min(turn++, replies.length - 1)], [new AppTapCapability(device, parser)], runner);
        return { agent, device };
    }

    it('a model stuck repeating the SAME action halts "stalled" and runs the side effect only once', async () => {
        const stuck = JSON.stringify({ tool: 'app.tap', input: 'Add friend' });
        const { agent, device } = tapAgent([stuck]);   // it only ever emits the same tap
        const result = await agent.run('tap it forever');

        expect(result.halt).toBe('stalled');             // bailed instead of burning all 8 steps
        expect(device.taps).toHaveLength(1);             // executed ONCE — repeats are not re-run
        expect(result.steps.some(s => s.includes('already ran'))).toBe(true);   // the nudge was given
    });

    it('the nudge lets a model recover: repeat once, then change course and answer', async () => {
        const tap = JSON.stringify({ tool: 'app.tap', input: 'Add friend' });
        const { agent, device } = tapAgent([tap, tap, JSON.stringify({ answer: 'done after the nudge' })]);
        const result = await agent.run('tap then finish');

        expect(result.halt).toBe('answered');
        expect(result.answer).toBe('done after the nudge');
        expect(device.taps).toHaveLength(1);             // the repeat was nudged, not re-executed
    });
});
