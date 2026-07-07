import { describe, it, expect } from 'vitest';
import { DashboardTaskService, AssembleDeps, UndoJournal } from '../src/services/capability/dashboardTasks.js';
import { createGovernedAgent, ChatCompleter } from '../src/services/capability/desktopAgent.js';
import { InMemoryConsentStore } from '../src/services/capability/capability.js';
import type { MacAutomation } from '../src/services/capability/macAutomation.js';
import type { UndoAction } from '../src/services/capability/undo.js';

/**
 * The dashboard's governed-task lifecycle, end to end with fakes: a scripted local model + a fake
 * macOS seam behind the REAL createGovernedAgent, driven the way the WebSocket layer drives it.
 * The load-bearing assertions are the FAIL-CLOSED ones: no listener ⇒ declined, disconnect ⇒
 * declined, stop ⇒ declined + cancelled — an approval question must never hang a run open.
 */

class FakeLlm implements ChatCompleter {
    private i = 0;
    constructor(private readonly replies: string[]) { }
    async generalChat(_prompt: string): Promise<{ text: string }> {
        return { text: this.replies[Math.min(this.i++, this.replies.length - 1)] };
    }
}

class FakeMac implements MacAutomation {
    scripts: string[] = [];
    available(): boolean { return true; }
    async runAppleScript(script: string): Promise<string> { this.scripts.push(script); return 'ok'; }
}

class FakeJournal implements UndoJournal {
    saved: UndoAction[][] = [];
    cleared = 0;
    save(actions: UndoAction[]): void { this.saved.push(actions); }
    clear(): void { this.cleared++; }
}

function grantAll() {
    const c = new InMemoryConsentStore();
    ['mac.reminders.add', 'mac.notes.create', 'mac.calendar.today'].forEach(id => c.setGranted(id, true));
    return c;
}

/** A service whose assemble() builds the real governed agent over the fakes. */
function makeService(replies: string[], mac = new FakeMac(), journal = new FakeJournal()) {
    const service = new DashboardTaskService((deps: AssembleDeps) => createGovernedAgent({
        llm: new FakeLlm(replies),
        mac,
        consent: grantAll(),
        approve: deps.approve,
        signal: deps.signal,
        dryRun: deps.dryRun,
        bulkThreshold: 20,
    }), journal);
    return { service, mac, journal };
}

describe('DashboardTaskService — the governed run over the socket seams', () => {
    it('streams steps, asks for approval, runs on yes, persists the undo journal, and undoes', async () => {
        const { service, mac, journal } = makeService([
            '{"tool":"mac.reminders.add","input":"water the plants"}',
            '{"answer":"Done."}',
        ]);
        const steps: string[] = [];
        service.on('step', (line: string) => steps.push(line));
        service.on('approval_request', (req) => {
            expect(req.summary.toLowerCase()).toContain('reminder');
            expect(req.mutates).toBe(true);
            service.answer(req.id, true);   // the renderer clicks Allow
        });

        const result = await service.start('remind me to water the plants');
        expect(result.halt).toBe('answered');
        expect(result.answer).toBe('Done.');
        expect(result.undoable).toBe(1);
        expect(steps.length).toBeGreaterThan(0);
        expect(mac.scripts.some(s => s.includes('make new reminder'))).toBe(true);
        // Cross-session parity: the reversible tail was persisted for `quenderin undo`.
        expect(journal.saved).toHaveLength(1);

        const report = await service.undoLast();
        expect(report).toContain('water the plants');
        expect(journal.cleared).toBe(1);
        await expect(service.undoLast()).rejects.toThrow('Nothing to undo');
    });

    it('a declined approval refuses the action (nothing runs)', async () => {
        const { service, mac, journal } = makeService([
            '{"tool":"mac.reminders.add","input":"buy a boat"}',
            '{"answer":"Okay, I did not add it."}',
        ]);
        service.on('approval_request', (req) => service.answer(req.id, false));
        const result = await service.start('add a reminder');
        expect(result.halt).toBe('answered');
        expect(result.undoable).toBe(0);
        expect(mac.scripts.some(s => s.includes('make new reminder'))).toBe(false);
        expect(journal.saved).toHaveLength(0);
    });

    it('FAIL-CLOSED: with no renderer listening, a mutating action is declined, not hung', async () => {
        const { service, mac } = makeService([
            '{"tool":"mac.reminders.add","input":"x"}',
            '{"answer":"done"}',
        ]);
        // No 'approval_request' listener at all — the run must still complete, refusing the write.
        const result = await service.start('add x');
        expect(result.halt).toBe('answered');
        expect(mac.scripts).toHaveLength(0);
    });

    it('FAIL-CLOSED: a disconnect mid-question declines the pending approval', async () => {
        const { service, mac } = makeService([
            '{"tool":"mac.reminders.add","input":"x"}',
            '{"answer":"done"}',
        ]);
        service.on('approval_request', () => {
            // The socket closes while the dialog is up — the WS layer calls declinePending().
            service.declinePending();
        });
        const result = await service.start('add x');
        expect(result.halt).toBe('answered');
        expect(mac.scripts).toHaveLength(0);
    });

    it('stop() aborts the run and declines the open question', async () => {
        const { service, mac } = makeService([
            '{"tool":"mac.reminders.add","input":"x"}',
            '{"answer":"never reached"}',
        ]);
        service.on('approval_request', () => service.stop());
        const result = await service.start('add x');
        expect(result.halt).toBe('cancelled');
        expect(mac.scripts).toHaveLength(0);
        expect(service.isRunning).toBe(false);
    });

    it('rejects a concurrent start loudly (one task at a time)', async () => {
        const { service } = makeService([
            '{"tool":"mac.reminders.add","input":"x"}',
            '{"answer":"done"}',
        ]);
        let overlap: Error | null = null;
        service.on('approval_request', (req) => {
            // While the first run awaits approval, a second start must throw.
            service.start('another goal').catch((e: Error) => { overlap = e; service.answer(req.id, true); });
        });
        await service.start('add x');
        expect(String(overlap)).toContain('already running');
    });

    it('rejects a workspace that is not a folder', async () => {
        const { service } = makeService(['{"answer":"unused"}']);
        await expect(service.start('goal', { workspace: '/definitely/not/a/real/dir' }))
            .rejects.toThrow('not a folder');
        expect(service.isRunning).toBe(false);
    });

    it('undoLast() while a run is active is refused', async () => {
        const { service } = makeService([
            '{"tool":"mac.reminders.add","input":"x"}',
            '{"answer":"done"}',
        ]);
        let undoErr: Error | null = null;
        service.on('approval_request', (req) => {
            service.undoLast().catch((e: Error) => { undoErr = e; service.answer(req.id, true); });
        });
        await service.start('add x');
        expect(String(undoErr)).toContain('still running');
    });
});
