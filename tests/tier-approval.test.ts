import { describe, it, expect } from 'vitest';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import {
    InMemoryConsentStore, InMemoryAuditLedger, CapabilityTier, Capability, ActionPreview,
} from '../src/services/capability/capability.js';

/**
 * The runner hands the approver each action's tier so a `--yes` power-user path can auto-approve
 * reversible actions (≤ T2) yet still prompt for app-driving / GUI (T3) — you can't rubber-stamp
 * clicking around your apps. This pins that the tier reaches the approver, single and in a plan.
 */
function fakeCap(name: string, tier: CapabilityTier): Capability {
    return {
        name, purpose: '', tier, blastRadius: { kind: 'write', resource: 'x' },
        async plan(): Promise<ActionPreview> { return { summary: `do ${name}`, mutates: true }; },
        async run(): Promise<string> { return `did ${name}`; },
    };
}

describe('tier-aware approval', () => {
    it('tells the approver each action\'s tier', async () => {
        const consent = new InMemoryConsentStore();
        ['t2', 't3'].forEach(n => consent.setGranted(n, true));
        const seen: Array<number | undefined> = [];
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async p => { seen.push(p.tier); return true; });
        await runner.execute(fakeCap('t2', CapabilityTier.ReversibleWrite), 'x');
        await runner.execute(fakeCap('t3', CapabilityTier.AppAction), 'x');
        expect(seen).toEqual([CapabilityTier.ReversibleWrite, CapabilityTier.AppAction]);
    });

    it('a plan\'s tier is its most dangerous step', async () => {
        const consent = new InMemoryConsentStore();
        ['t2', 't3'].forEach(n => consent.setGranted(n, true));
        let planTier: number | undefined;
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async p => { planTier = p.tier; return true; });
        await runner.executePlan([
            { capability: fakeCap('t2', CapabilityTier.ReversibleWrite), input: 'a' },
            { capability: fakeCap('t3', CapabilityTier.AppAction), input: 'b' },
        ]);
        expect(planTier).toBe(CapabilityTier.AppAction);   // T3 present → the plan prompts even under --yes
    });
});
