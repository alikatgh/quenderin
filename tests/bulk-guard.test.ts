import { describe, it, expect } from 'vitest';
import { Capability, CapabilityTier, InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';

/**
 * The runaway/bulk brake — the safety gap flagged in AGENT_AUTONOMY_PLAN §4b (the imo
 * mass-messaging example). A cloud agent runs 500 steps and bills you; ours pauses after a
 * burst of changes and re-asks. Protects against stuck loops AND unattended bulk outreach.
 */
class Counter implements Capability {
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius = { kind: 'write' as const, resource: 'test' };
    ran = 0;
    readonly name = 'test.change';
    readonly purpose = 'a mutating test capability';
    async plan() { return { summary: 'make a change', mutates: true }; }
    async run() { this.ran++; return `change ${this.ran}`; }
}

function grant() { const c = new InMemoryConsentStore(); c.setGranted('test.change', true); return c; }

describe('CapabilityRunner bulk guard (single-action path)', () => {
    it('re-asks after the threshold and stops the run when the user declines to continue', async () => {
        const cap = new Counter();
        const ledger = new InMemoryAuditLedger();
        const approvals: string[] = [];
        // Approve every per-run prompt, but decline the FIRST bulk-continue prompt.
        const approve = async (p: { summary: string }) => {
            if (p.summary.startsWith('⚠️')) { approvals.push('bulk'); return false; }
            approvals.push('run'); return true;
        };
        const runner = new CapabilityRunner(grant(), ledger, approve, () => 0, undefined, 3);   // threshold 3

        const outs: string[] = [];
        for (let i = 0; i < 5; i++) outs.push(await runner.execute(cap, `n${i}`));

        // 3 changes go through; the 4th trips the bulk guard, which is declined → paused.
        expect(cap.ran).toBe(3);
        expect(outs[3]).toContain('Paused');
        expect(ledger.entries().filter(e => e.decision === 'bulkPaused')).toHaveLength(2);   // 4th and 5th
        expect(approvals.filter(a => a === 'bulk').length).toBeGreaterThanOrEqual(1);
    });

    it('continues past the threshold when the user approves the bulk prompt, resetting the window', async () => {
        const cap = new Counter();
        const approve = async () => true;   // approve everything, incl. bulk-continue
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), approve, () => 0, undefined, 3);
        for (let i = 0; i < 7; i++) await runner.execute(cap, `n${i}`);
        expect(cap.ran).toBe(7);   // all run — the window resets on each bulk approval
    });

    it('threshold 0 disables the brake entirely', async () => {
        const cap = new Counter();
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true, () => 0, undefined, 0);
        for (let i = 0; i < 50; i++) await runner.execute(cap, `n${i}`);
        expect(cap.ran).toBe(50);
    });
});

describe('CapabilityRunner bulk guard (plan path)', () => {
    it('prepends a loud change-count banner when a plan exceeds the threshold', async () => {
        const cap = new Counter();
        let seen = '';
        const approve = async (p: { summary: string }) => { seen = p.summary; return true; };
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), approve, () => 0, undefined, 3);
        const items = Array.from({ length: 5 }, (_, i) => ({ capability: cap, input: `f${i}` }));
        await runner.executePlan(items);
        expect(seen).toContain('⚠️ This plan makes 5 changes — review carefully.');
    });

    it('a small plan gets no banner', async () => {
        const cap = new Counter();
        let seen = '';
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async (p: { summary: string }) => { seen = p.summary; return true; }, () => 0, undefined, 3);
        await runner.executePlan([{ capability: cap, input: 'a' }, { capability: cap, input: 'b' }]);
        expect(seen).not.toContain('⚠️');
        expect(seen).toContain('The agent proposes this plan');
    });
});
