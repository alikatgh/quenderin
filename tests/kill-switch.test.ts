import { describe, it, expect } from 'vitest';
import { Capability, CapabilityTier, InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { CapabilityAgent } from '../src/services/capability/capabilityAgent.js';

/**
 * The kill switch — the trust superpower a LOCAL agent has over a cloud one: stop it dead,
 * mid-task, on your own machine, instantly. A cloud agent's "stop" halts the remote brain but
 * can't un-fire an action already dispatched to your computer; ours checks a local signal
 * between every step and simply doesn't run the next one.
 */

/** A recording capability that can flip an AbortController when it runs (to simulate "user hit
 *  Stop DURING step N"). All mutating (needs approval), all reversible-in-spirit. */
class RecordCap implements Capability {
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius = { kind: 'write' as const, resource: 'test' };
    ran = 0;
    constructor(readonly name: string, private readonly onRun?: () => void) { }
    readonly purpose = 'test capability';
    async plan() { return { summary: `do ${this.name}`, mutates: true }; }
    async run() { this.ran++; this.onRun?.(); return `did ${this.name}`; }
}

function grant(...ids: string[]) {
    const c = new InMemoryConsentStore();
    ids.forEach(id => c.setGranted(id, true));
    return c;
}

describe('CapabilityRunner kill switch', () => {
    it('refuses a single action when already halted, and ledgers it as cancelled', async () => {
        const cap = new RecordCap('a');
        const ledger = new InMemoryAuditLedger();
        const ac = new AbortController(); ac.abort();
        const out = await new CapabilityRunner(grant('a'), ledger, async () => true).execute(cap, 'x', ac.signal);
        expect(out).toContain('Stopped');
        expect(cap.ran).toBe(0);
        expect(ledger.entries().at(-1)?.decision).toBe('cancelled');
    });

    it('stops a plan MID-EXECUTION — step 1 runs, Stop is hit, step 2 never runs', async () => {
        const ac = new AbortController();
        const step1 = new RecordCap('a', () => ac.abort());   // hitting Stop while step 1 runs
        const step2 = new RecordCap('b');
        const ledger = new InMemoryAuditLedger();
        const runner = new CapabilityRunner(grant('a', 'b'), ledger, async () => true);
        const out = await runner.executePlan(
            [{ capability: step1, input: 'x' }, { capability: step2, input: 'y' }],
            ac.signal,
        );
        expect(step1.ran).toBe(1);
        expect(step2.ran).toBe(0);   // the whole point: the remainder does NOT run
        expect(out).toContain('Stopped by you after step 1 of 2');
        // Ledger tells the true story: step 1 allowed, step 2 cancelled (never executed).
        expect(ledger.entries().map(e => e.decision)).toEqual(['allowed', 'cancelled']);
    });

    it('halts a whole plan before it starts when Stop is already pressed', async () => {
        const cap = new RecordCap('a');
        const ac = new AbortController(); ac.abort();
        const out = await new CapabilityRunner(grant('a'), new InMemoryAuditLedger(), async () => true)
            .executePlan([{ capability: cap, input: 'x' }], ac.signal);
        expect(out).toContain('before the plan ran');
        expect(cap.ran).toBe(0);
    });
});

describe('CapabilityAgent kill switch', () => {
    it('halts the whole run at the next turn, changing nothing further', async () => {
        const cap = new RecordCap('a');
        const ac = new AbortController();
        let turn = 0;
        // The planner keeps proposing work; the user hits Stop after the first observation.
        const planner = async () => {
            if (turn++ === 0) { ac.abort(); return JSON.stringify({ tool: 'a', input: 'x' }); }
            return JSON.stringify({ tool: 'a', input: 'y' });
        };
        const runner = new CapabilityRunner(grant('a'), new InMemoryAuditLedger(), async () => true);
        const agent = new CapabilityAgent(planner, [cap], runner, 8);
        const result = await agent.run('do stuff', ac.signal);
        expect(result.halt).toBe('cancelled');
        // The first turn's action was already gated by the (now-aborted) signal → not run.
        expect(cap.ran).toBe(0);
    });
});
