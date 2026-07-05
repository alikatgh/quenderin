import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createGovernedAgent, ChatCompleter, llmPlanner } from '../src/services/capability/desktopAgent.js';
import { InMemoryConsentStore } from '../src/services/capability/capability.js';
import type { MacAutomation } from '../src/services/capability/macAutomation.js';

/**
 * The PRODUCTION assembly, end to end — the "make it real" path. A fake local model emits real
 * decisions; a fake macOS seam records the AppleScript. The only production swap is llm → real
 * LlmService and mac → real OsascriptAutomation; everything between is exactly this. This is the
 * proof that the whole governed loop runs on a live model, not just in unit tests.
 */

/** A scripted local model — same shape as LlmService.generalChat, so the real one drops in. */
class FakeLlm implements ChatCompleter {
    private i = 0;
    constructor(private readonly replies: string[]) { }
    async generalChat(_prompt: string): Promise<{ text: string; meta?: unknown }> {
        return { text: this.replies[Math.min(this.i++, this.replies.length - 1)] };
    }
}

class FakeMac implements MacAutomation {
    scripts: string[] = [];
    available(): boolean { return true; }
    async runAppleScript(script: string): Promise<string> { this.scripts.push(script); return 'ok'; }
}

function grantAll() {
    const c = new InMemoryConsentStore();
    ['mac.reminders.add', 'mac.notes.create', 'mac.calendar.today', 'mac.frontApp',
     'mac.clipboard.read', 'mac.app.open', 'mac.safari.openURL', 'mac.mail.draft'].forEach(id => c.setGranted(id, true));
    return c;
}

describe('llmPlanner adapts a local model into the agent planner', () => {
    it('uses plainChat and returns the model text', async () => {
        const planner = llmPlanner(new FakeLlm(['{"answer":"hi"}']));
        expect(await planner('goal')).toBe('{"answer":"hi"}');
    });
});

describe('createGovernedAgent — the whole thing on a (fake) live model', () => {
    it('a goal drives a governed macOS plan, then the task is undone', async () => {
        const mac = new FakeMac();
        // The "model" plans two reminders, then answers.
        const llm = new FakeLlm([
            JSON.stringify({ plan: [
                { tool: 'mac.reminders.add', input: 'water the plants' },
                { tool: 'mac.reminders.add', input: 'call the dentist' },
            ] }),
            JSON.stringify({ answer: 'Added both reminders.' }),
        ]);
        const agent = createGovernedAgent({
            llm,
            mac,
            consent: grantAll(),
            approve: async () => true,   // stands in for the Electron dialog
            bulkThreshold: 20,
        });

        const result = await agent.run('remind me to water the plants and call the dentist');
        expect(result.halt).toBe('answered');
        expect(result.answer).toBe('Added both reminders.');
        // The real capabilities ran the real AppleScript templates.
        expect(mac.scripts.filter(s => s.includes('make new reminder'))).toHaveLength(2);
        // The ledger recorded the task.
        expect(agent.ledger.entries().filter(e => e.decision === 'allowed')).toHaveLength(2);

        // "Undo this task" reverses both, newest-first.
        const undo = await agent.undoAll();
        expect(undo).toContain('Removed the reminder "call the dentist"');
        expect(undo).toContain('Removed the reminder "water the plants"');
        expect(mac.scripts.filter(s => s.includes('delete (every reminder'))).toHaveLength(2);
    });

    it('mutating actions fail closed when no approval dialog is wired', async () => {
        const mac = new FakeMac();
        const llm = new FakeLlm([
            JSON.stringify({ tool: 'mac.reminders.add', input: 'water plants' }),
            JSON.stringify({ answer: 'done' }),
        ]);
        const agent = createGovernedAgent({ llm, mac, consent: grantAll() });   // no approver
        const result = await agent.run('add a reminder');
        expect(result.steps[0]).toContain('needs your per-run approval');
        expect(mac.scripts).toHaveLength(0);
    });

    it('assembles only the capabilities whose seams are provided', async () => {
        const macOnly = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']), mac: new FakeMac() });
        expect(macOnly.capabilities.every(c => c.name.startsWith('mac.'))).toBe(true);
        expect(macOnly.capabilities.length).toBeGreaterThan(0);
        const none = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']) });
        expect(none.capabilities).toHaveLength(0);
    });

    it('surfaces fs.* only when a workspace seam is provided', () => {
        const withWs = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']), workspace: () => '/tmp' });
        expect(withWs.capabilities.map(c => c.name)).toContain('fs.move');
        const withoutWs = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']), mac: new FakeMac() });
        expect(withoutWs.capabilities.some(c => c.name.startsWith('fs.'))).toBe(false);
    });

    it('surfaces mac.ui.* (GUI driving) only when the macUi seam is provided', () => {
        const ui = { available: () => true, observe: async () => [], click: async () => {}, typeText: async () => {}, pressKey: async () => {} };
        const withGui = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']), macUi: ui });
        expect(withGui.capabilities.map(c => c.name)).toContain('mac.ui.tap');
        const macOnly = createGovernedAgent({ llm: new FakeLlm(['{"answer":"x"}']), mac: new FakeMac() });
        expect(macOnly.capabilities.some(c => c.name.startsWith('mac.ui.'))).toBe(false);   // opt-in, off by default
    });
});

/**
 * The flagship chore — "organize my downloads" — through the WHOLE assembly on a real temp folder.
 * This is the "test the route, not the template" check: the capability unit tests prove fs.move
 * in isolation; this proves createGovernedAgent({ workspace }) actually hands fs.* to the model,
 * runs it through the real gate, mutates real disk, ledgers it, and undoes it.
 */
describe('createGovernedAgent — file chores end to end on a real workspace', () => {
    let ws: string;
    beforeEach(() => { ws = fs.mkdtempSync(path.join(os.tmpdir(), 'qga-')); });
    afterEach(() => { fs.rmSync(ws, { recursive: true, force: true }); });

    it('lists, moves a file into a subfolder, then undoes the whole task', async () => {
        fs.writeFileSync(path.join(ws, 'invoice.pdf'), '%PDF');
        const consent = new InMemoryConsentStore();
        ['fs.list', 'fs.move'].forEach(id => consent.setGranted(id, true));
        const llm = new FakeLlm([
            JSON.stringify({ tool: 'fs.list', input: '' }),
            JSON.stringify({ tool: 'fs.move', input: 'invoice.pdf to Finance' }),
            JSON.stringify({ answer: 'Filed invoice.pdf under Finance/.' }),
        ]);
        const agent = createGovernedAgent({ llm, workspace: () => ws, consent, approve: async () => true });

        const result = await agent.run('organize my downloads');
        expect(result.halt).toBe('answered');
        expect(fs.existsSync(path.join(ws, 'Finance', 'invoice.pdf'))).toBe(true);   // real disk changed
        expect(fs.existsSync(path.join(ws, 'invoice.pdf'))).toBe(false);
        expect(agent.ledger.entries().filter(e => e.decision === 'allowed').length).toBeGreaterThanOrEqual(1);

        await agent.undoAll();
        expect(fs.existsSync(path.join(ws, 'invoice.pdf'))).toBe(true);              // moved back
        expect(fs.existsSync(path.join(ws, 'Finance', 'invoice.pdf'))).toBe(false);
    });

    it('honors a custom maxSteps budget (the CLI `--max-steps` for multi-item chores)', async () => {
        const consent = new InMemoryConsentStore(); consent.setGranted('fs.read', true);
        // A model that keeps reading distinct files and never answers — distinct inputs so the loop
        // guard doesn't fire; it should run exactly the budget, then halt 'maxSteps'.
        const llm = new FakeLlm([
            JSON.stringify({ tool: 'fs.read', input: 'a.txt' }),
            JSON.stringify({ tool: 'fs.read', input: 'b.txt' }),
        ]);
        const agent = createGovernedAgent({ llm, workspace: () => ws, consent, maxSteps: 2 });
        const result = await agent.run('read everything, never stop');
        expect(result.halt).toBe('maxSteps');
        expect(result.steps).toHaveLength(2);   // ran the budget, not the default 8
    });
});
