import { describe, it, expect } from 'vitest';
import { SkillMemory } from '../src/services/capability/skillMemory.js';
import { CapabilityAgent } from '../src/services/capability/capabilityAgent.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { Capability, CapabilityTier, InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';

/**
 * Skill memory — the harness compensating for weak grounding. It records the capability sequence
 * that accomplished a goal and primes the next similar goal with it, so the agent gets reliably
 * better at repeated chores without a bigger model.
 */
describe('SkillMemory', () => {
    it('recalls similar past goals above the threshold, best first, and ignores dissimilar ones', () => {
        const m = new SkillMemory(0.5);
        m.record('organize my downloads folder', ['fs.list', 'fs.move']);
        m.record('add a reminder to call the dentist', ['mac.reminders.add']);
        m.record('tidy the downloads directory', ['fs.list', 'fs.move']);

        const recalled = m.recall('please organize the downloads folder');
        expect(recalled.length).toBeGreaterThan(0);
        expect(recalled[0].tools).toEqual(['fs.list', 'fs.move']);
        // A totally different goal recalls nothing relevant.
        expect(m.recall('what is the capital of France')).toHaveLength(0);
    });

    it('de-dupes an identical goal, keeping the latest sequence, and caps capacity', () => {
        const m = new SkillMemory(0.5, 2);
        m.record('archive old files', ['fs.move']);
        m.record('archive old files', ['fs.list', 'fs.move']);   // same goal → replaces
        expect(m.size).toBe(1);
        expect(m.recall('archive old files')[0].tools).toEqual(['fs.list', 'fs.move']);
        m.record('rename the photos', ['fs.rename']);
        m.record('empty the trash folder', ['fs.trash']);        // capacity 2 → 'archive old files' drops
        expect(m.size).toBe(2);
    });

    it('ignores empty runs', () => {
        const m = new SkillMemory();
        m.record('nothing happened', []);
        expect(m.size).toBe(0);
    });

    it('recordSteps stores tool+input and formatHint surfaces concrete plan shape', () => {
        const m = new SkillMemory(0.5);
        m.recordSteps('organize my downloads', [
            { tool: 'fs.list', input: '' },
            { tool: 'fs.organize', input: '' },
            { tool: 'fs.move', input: 'invoice.pdf to Finance' },
        ]);
        const hit = m.recall('please organize downloads')[0];
        expect(hit.tools).toEqual(['fs.list', 'fs.organize', 'fs.move']);
        expect(hit.steps?.[2]).toEqual({ tool: 'fs.move', input: 'invoice.pdf to Finance' });
        const hint = SkillMemory.formatHint(hit);
        expect(hint).toContain('fs.list');
        expect(hint).toContain('fs.move');
        expect(hint).toContain('invoice.pdf to Finance');
    });

    it('snapshot/restore round-trips steps', () => {
        const m = new SkillMemory();
        m.recordSteps('tidy desktop', [{ tool: 'fs.organize', input: '' }]);
        const m2 = new SkillMemory();
        m2.restore(m.snapshot());
        expect(m2.recall('tidy desktop')[0].steps?.[0].tool).toBe('fs.organize');
    });
});


class NoopCap implements Capability {
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius = { kind: 'read' as const, resource: 't' };
    constructor(readonly name: string) { }
    readonly purpose = 'a test capability';
    async plan() { return { summary: 'read', mutates: false }; }
    async run() { return `ran ${this.name}`; }
}

describe('CapabilityAgent + SkillMemory — learn on success, prime next time', () => {
    it('records the proven sequence after an answered run', async () => {
        const memory = new SkillMemory(0.5);
        const consent = new InMemoryConsentStore(); consent.setGranted('read.a', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger());
        const replies = [
            JSON.stringify({ tool: 'read.a', input: 'x' }),
            JSON.stringify({ answer: 'done' }),
        ];
        let turn = 0;
        const agent = new CapabilityAgent(async () => replies[Math.min(turn++, 1)], [new NoopCap('read.a')], runner, 8, memory);
        await agent.run('check the thing');
        const rec = memory.recall('check the thing')[0];
        expect(rec.tools).toEqual(['read.a']);
        expect(rec.steps).toEqual([{ tool: 'read.a', input: 'x' }]);
    });


    it('the reliability payoff: a model that only picks the right tool WHEN PRIMED succeeds the 2nd time', async () => {
        const memory = new SkillMemory(0.4);
        memory.record('summarize my clipboard', ['read.a']);   // a prior success is remembered

        const consent = new InMemoryConsentStore(); consent.setGranted('read.a', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger());

        // A "weak model" that only calls read.a if the prompt was primed with it; else it flails.
        const planner = async (prompt: string) => {
            if (turn === 0 && prompt.includes('read.a')) { turn++; return JSON.stringify({ tool: 'read.a', input: '' }); }
            if (turn === 0) { turn++; return JSON.stringify({ tool: 'read.nonsense', input: '' }); }
            return JSON.stringify({ answer: 'ok' });
        };
        let turn = 0;
        const agent = new CapabilityAgent(planner, [new NoopCap('read.a')], runner, 8, memory);
        const result = await agent.run('please summarize the clipboard for me');
        expect(result.halt).toBe('answered');
        // Because the preamble was primed with the recalled 'read.a' skill, the weak model chose right.
        expect(result.steps[0]).toBe('ran read.a');
    });
});
