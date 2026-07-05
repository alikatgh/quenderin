import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { replayUndo, isUndoAction, UndoAction } from '../src/services/capability/undo.js';
import { FsMoveCapability, FsTrashCapability } from '../src/services/capability/fileCapabilities.js';
import type { MacAutomation } from '../src/services/capability/macAutomation.js';

/**
 * Cross-session undo — the trust superpower made durable: reverse the last task from a FRESH
 * process, rebuilding each capability by name. A cloud agent can't reverse your local machine at
 * all, let alone an hour later in a new session. These pin the rebuild-by-name, LIFO order, the
 * fs-needs-workspace contract, and best-effort recovery.
 */
class FakeMac implements MacAutomation {
    scripts: string[] = [];
    constructor(private readonly fail?: string) { }
    available(): boolean { return true; }
    async runAppleScript(script: string): Promise<string> {
        this.scripts.push(script);
        if (this.fail && script.includes(this.fail)) throw new Error('locked');
        return 'ok';
    }
}

let ws: string;
beforeEach(() => { ws = fs.mkdtempSync(path.join(os.tmpdir(), 'qundo-')); });
afterEach(() => { fs.rmSync(ws, { recursive: true, force: true }); });

describe('replayUndo — reverse a persisted task in a fresh process', () => {
    it('says so when there is nothing on record', async () => {
        expect(await replayUndo([], new FakeMac())).toContain('Nothing to undo');
    });

    it('rebuilds an fs.move by name and moves the file back', async () => {
        // Simulate the original run: move report.pdf into docs/.
        fs.writeFileSync(path.join(ws, 'report.pdf'), 'x');
        await new FsMoveCapability(() => ws).run('report.pdf to docs');
        expect(fs.existsSync(path.join(ws, 'docs', 'report.pdf'))).toBe(true);

        // A fresh process only has the journal — name + input + workspace.
        const out = await replayUndo([{ capability: 'fs.move', input: 'report.pdf to docs', workspace: ws }], new FakeMac());
        expect(out).toContain('back');
        expect(fs.existsSync(path.join(ws, 'report.pdf'))).toBe(true);
        expect(fs.existsSync(path.join(ws, 'docs', 'report.pdf'))).toBe(false);
    });

    it('rebuilds a mac.* undo by name and runs its reversal script', async () => {
        const mac = new FakeMac();
        const out = await replayUndo([{ capability: 'mac.reminders.add', input: 'call the dentist' }], mac);
        expect(out).toContain('Removed the reminder "call the dentist"');
        expect(mac.scripts[0]).toContain('delete (every reminder whose name is "call the dentist")');
    });

    it('reverses newest-first (LIFO), mixing fs and mac', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        await new FsTrashCapability(() => ws).run('a.txt');   // a.txt now in Trash/
        const mac = new FakeMac();
        const journal: UndoAction[] = [
            { capability: 'mac.reminders.add', input: 'first' },       // oldest
            { capability: 'fs.trash', input: 'a.txt', workspace: ws },  // newest → undone first
        ];
        const out = await replayUndo(journal, mac);
        const lines = out.split('\n');
        expect(lines[0]).toContain('Restored "a.txt"');   // the fs.trash (newest) reversed first
        expect(lines[1]).toContain('Removed the reminder "first"');
        expect(fs.existsSync(path.join(ws, 'a.txt'))).toBe(true);
    });

    it('skips an fs action with no recorded workspace, and a capability that cannot undo', async () => {
        const out = await replayUndo([
            { capability: 'fs.move', input: 'a to b' },                 // no workspace
            { capability: 'mac.frontApp', input: '' },                  // T1, no undo()
            { capability: 'nonsense.capability', input: 'x' },          // unknown
        ], new FakeMac());
        expect(out).toContain("workspace wasn't recorded");
        expect(out.match(/nothing to reverse/g)?.length).toBe(2);      // frontApp + unknown
    });

    it('is best-effort: one failed reversal is reported, the rest still roll back', async () => {
        const mac = new FakeMac('call the dentist');   // fail the reminder delete
        const out = await replayUndo([
            { capability: 'mac.notes.create', input: 'Trip plan' },
            { capability: 'mac.reminders.add', input: 'call the dentist' },
        ], mac);
        // The reminder's own undo() degrades gracefully (returns a "Couldn't…" sentence, doesn't
        // throw) — same soft-failure contract as the in-session undoAll — and the note still reverses.
        expect(out).toContain("Couldn't remove the reminder");
        expect(out).toContain('Removed the note "Trip plan"');
    });
});

describe('isUndoAction — the journal is on disk, so validate every row', () => {
    it('accepts valid rows and rejects junk', () => {
        expect(isUndoAction({ capability: 'fs.move', input: 'a to b', workspace: '/x' })).toBe(true);
        expect(isUndoAction({ capability: 'mac.reminders.add', input: 'x' })).toBe(true);
        expect(isUndoAction({ capability: 'fs.move' })).toBe(false);        // missing input
        expect(isUndoAction({ capability: 5, input: 'x' })).toBe(false);    // wrong type
        expect(isUndoAction({ capability: 'x', input: 'y', workspace: 3 })).toBe(false);
        expect(isUndoAction('garbage')).toBe(false);
    });
});
