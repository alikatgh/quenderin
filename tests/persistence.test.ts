import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { FileAuditLedger, loadSkillMemory, saveSkillMemory, saveUndoJournal, loadUndoJournal, clearUndoJournal, loadCliConfig } from '../src/services/capability/persistence.js';
import { SkillMemory } from '../src/services/capability/skillMemory.js';
import type { UndoAction } from '../src/services/capability/undo.js';

/**
 * Persistence makes the CLI agent's reliability loop REAL: each `quenderin do` is a fresh process,
 * so in-memory skill memory + ledger would reset every time. Round-trip both to disk.
 */
let dir: string;
beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qp-')); });
afterEach(() => { fs.rmSync(dir, { recursive: true, force: true }); });

describe('FileAuditLedger', () => {
    it('appends JSONL that survives a torn last line', () => {
        const file = path.join(dir, 'ledger.jsonl');
        const ledger = new FileAuditLedger(file);
        ledger.append({ timestampMs: 1, capability: 'mac.reminders.add', tier: 2, input: 'a', decision: 'allowed', outcome: 'ok' });
        ledger.append({ timestampMs: 2, capability: 'mac.notes.create', tier: 2, input: 'b', decision: 'blocked(pay)' });
        fs.appendFileSync(file, '{"timestampMs":3,"capab');   // simulated crash mid-append

        const read = new FileAuditLedger(file).entries();
        expect(read).toHaveLength(2);
        expect(read[1].decision).toBe('blocked(pay)');
    });

    it('a missing ledger reads as empty', () => {
        expect(new FileAuditLedger(path.join(dir, 'nope.jsonl')).entries()).toEqual([]);
    });
});

describe('skill memory persistence', () => {
    it('round-trips proven skills across a save/load (a fresh process)', () => {
        const file = path.join(dir, 'skills.json');
        const m = new SkillMemory(0.5);
        m.record('organize my downloads', ['fs.list', 'fs.move']);
        m.record('add a dentist reminder', ['mac.reminders.add']);
        saveSkillMemory(m, file);

        // A brand-new memory (like the next `quenderin do` process) loads the past skills.
        const reloaded = loadSkillMemory(file, 0.5);
        expect(reloaded.size).toBe(2);
        expect(reloaded.recall('please organize downloads')[0].tools).toEqual(['fs.list', 'fs.move']);
    });

    it('a missing/corrupt skills file loads as an empty memory', () => {
        expect(loadSkillMemory(path.join(dir, 'nope.json')).size).toBe(0);
        fs.writeFileSync(path.join(dir, 'bad.json'), 'not json');
        expect(loadSkillMemory(path.join(dir, 'bad.json')).size).toBe(0);
    });

    it('restore drops junk rows, keeps valid ones', () => {
        const m = new SkillMemory();
        m.restore([{ goal: 'ok task', tools: ['a'] }, { goal: 42 }, { tools: ['b'] }, 'garbage']);
        expect(m.size).toBe(1);
        expect(m.recall('ok task')[0].tools).toEqual(['a']);
    });
});

describe('undo journal persistence — cross-session `quenderin undo`', () => {
    it('round-trips the last task and clears on demand', () => {
        const file = path.join(dir, 'undo.json');
        const journal: UndoAction[] = [
            { capability: 'mac.reminders.add', input: 'call the dentist' },
            { capability: 'fs.move', input: 'a.txt to docs', workspace: '/tmp/ws' },
        ];
        saveUndoJournal(journal, file);
        expect(loadUndoJournal(file)).toEqual(journal);

        clearUndoJournal(file);
        expect(loadUndoJournal(file)).toEqual([]);   // gone → nothing to double-reverse
    });

    it('a save replaces the prior journal (undo targets only the LATEST task)', () => {
        const file = path.join(dir, 'undo.json');
        saveUndoJournal([{ capability: 'mac.notes.create', input: 'old' }], file);
        saveUndoJournal([{ capability: 'mac.notes.create', input: 'new' }], file);
        expect(loadUndoJournal(file)).toEqual([{ capability: 'mac.notes.create', input: 'new' }]);
    });

    it('a missing/corrupt journal loads empty, and junk rows are dropped', () => {
        expect(loadUndoJournal(path.join(dir, 'nope.json'))).toEqual([]);
        fs.writeFileSync(path.join(dir, 'bad.json'), 'not json');
        expect(loadUndoJournal(path.join(dir, 'bad.json'))).toEqual([]);
        fs.writeFileSync(path.join(dir, 'mixed.json'), JSON.stringify([{ capability: 'fs.move', input: 'a to b' }, { nope: 1 }, 'x']));
        expect(loadUndoJournal(path.join(dir, 'mixed.json'))).toEqual([{ capability: 'fs.move', input: 'a to b' }]);
    });

    it('clearing an already-absent journal is a no-op (never throws)', () => {
        expect(() => clearUndoJournal(path.join(dir, 'ghost.json'))).not.toThrow();
    });
});

describe('CLI config — per-user defaults for `quenderin do`', () => {
    it('loads valid fields and drops invalid/unknown ones (a typo never bricks the CLI)', () => {
        const file = path.join(dir, 'config.json');
        fs.writeFileSync(file, JSON.stringify({
            model: 'gemma-4-12b', workspace: '/Users/me/Downloads', gui: true, maxSteps: 20,
            bogus: 'ignored', gui2: 'wrongtype',
        }));
        expect(loadCliConfig(file)).toEqual({ model: 'gemma-4-12b', workspace: '/Users/me/Downloads', gui: true, maxSteps: 20 });
    });

    it('drops fields of the wrong type', () => {
        const file = path.join(dir, 'bad-types.json');
        fs.writeFileSync(file, JSON.stringify({ model: 5, gui: 'yes', maxSteps: 'ten', workspace: '/ok' }));
        expect(loadCliConfig(file)).toEqual({ workspace: '/ok' });   // only the valid string survives
    });

    it('a missing or corrupt config loads as empty', () => {
        expect(loadCliConfig(path.join(dir, 'nope.json'))).toEqual({});
        fs.writeFileSync(path.join(dir, 'corrupt.json'), 'not json');
        expect(loadCliConfig(path.join(dir, 'corrupt.json'))).toEqual({});
    });
});
