import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
    FsListCapability, FsReadCapability, FsMoveCapability, FsRenameCapability, FsTrashCapability,
    fileCapabilities,
} from '../src/services/capability/fileCapabilities.js';
import { RunSession, InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';

/**
 * File capabilities are the #1 chore class ("organize my downloads") and the reason the CLI agent
 * has hands at all off macOS. The safety contract is structural: a granted WORKSPACE folder, plain
 * names only (no paths / no traversal), never overwrite, Trash is a visible subfolder (never a real
 * delete), and every write is undoable so it plugs into session rollback. These tests pin all of it.
 */
let ws: string;
const workspace = () => ws;
beforeEach(() => { ws = fs.mkdtempSync(path.join(os.tmpdir(), 'qws-')); });
afterEach(() => { fs.rmSync(ws, { recursive: true, force: true }); });

const touch = (name: string, body = 'hi') => fs.writeFileSync(path.join(ws, name), body);
const exists = (rel: string) => fs.existsSync(path.join(ws, rel));

describe('fs.list', () => {
    it('lists files and marks folders with a trailing slash, hiding dotfiles', async () => {
        touch('b.txt'); touch('a.txt'); fs.mkdirSync(path.join(ws, 'photos')); touch('.hidden');
        const out = await new FsListCapability(workspace).run();
        expect(out).toBe('a.txt\nb.txt\nphotos/');   // sorted, dotfile hidden, folder flagged
    });

    it('says so when empty, and refuses with no workspace', async () => {
        expect(await new FsListCapability(workspace).run()).toContain('is empty');
        expect(await new FsListCapability(() => null).run()).toContain('No workspace');
    });
});

describe('fs.read', () => {
    it('reads a named text file, rejects paths, and 404s a missing file', async () => {
        touch('note.txt', 'the body');
        const cap = new FsReadCapability(workspace);
        expect(await cap.run('note.txt')).toBe('the body');
        expect(await cap.run('../secret')).toContain('no paths');
        expect(await cap.run('sub/x')).toContain('no paths');
        expect(await cap.run('ghost.txt')).toContain('No file named');
    });

    it('truncates a file past the byte cap and flags binary', async () => {
        const cap = new FsReadCapability(workspace, 16);
        touch('big.txt', 'x'.repeat(100));
        expect(await cap.run('big.txt')).toContain('truncated');
        fs.writeFileSync(path.join(ws, 'bin.dat'), Buffer.from([0xff, 0xfe, 0x00, 0x01]));
        expect(await cap.run('bin.dat')).toContain("isn't a UTF-8");
    });
});

describe('fs.move', () => {
    it('moves a file into a subfolder and undoes it', async () => {
        touch('report.pdf');
        const cap = new FsMoveCapability(workspace);
        const out = await cap.run('report.pdf to docs');
        expect(out).toContain('Moved');
        expect(exists('docs/report.pdf')).toBe(true);
        expect(exists('report.pdf')).toBe(false);

        expect(await cap.undo('report.pdf to docs')).toContain('back');
        expect(exists('report.pdf')).toBe(true);
        expect(exists('docs/report.pdf')).toBe(false);
    });

    it('refuses to overwrite an existing target, and rejects bad input', async () => {
        touch('a.txt'); fs.mkdirSync(path.join(ws, 'docs')); fs.writeFileSync(path.join(ws, 'docs', 'a.txt'), 'old');
        const cap = new FsMoveCapability(workspace);
        expect(await cap.run('a.txt to docs')).toContain('refusing to overwrite');
        expect(exists('a.txt')).toBe(true);                       // source untouched
        expect(await cap.run('../a.txt to docs')).toContain('plain names');
        expect(await cap.run('a.txt docs')).toContain('<file> to <subfolder>');
        expect(await cap.run('ghost.txt to docs')).toContain('No file named');
    });
});

describe('fs.rename', () => {
    it('renames and undoes, and never overwrites', async () => {
        touch('IMG_1.jpg'); touch('taken.jpg');
        const cap = new FsRenameCapability(workspace);
        expect(await cap.run('IMG_1.jpg to beach.jpg')).toContain('Renamed');
        expect(exists('beach.jpg')).toBe(true);
        expect(await cap.undo('IMG_1.jpg to beach.jpg')).toContain('back');
        expect(exists('IMG_1.jpg')).toBe(true);

        expect(await cap.run('IMG_1.jpg to taken.jpg')).toContain('refusing to overwrite');
        expect(await cap.run('../etc to x')).toContain('plain names');
    });
});

describe('fs.trash', () => {
    it('moves to a visible Trash/ folder (never deletes) and restores on undo', async () => {
        touch('junk.log');
        const cap = new FsTrashCapability(workspace);
        expect(await cap.run('junk.log')).toContain('Trash/');
        expect(exists('Trash/junk.log')).toBe(true);             // still on disk — not deleted
        expect(exists('junk.log')).toBe(false);
        expect(await cap.undo('junk.log')).toContain('Restored');
        expect(exists('junk.log')).toBe(true);
    });

    it('rejects paths and a missing file', async () => {
        const cap = new FsTrashCapability(workspace);
        expect(await cap.run('../../etc/passwd')).toContain('no paths');
        expect(await cap.run('ghost')).toContain('No file named');
    });
});

describe('fileCapabilities() + session rollback', () => {
    it('registers the five fs.* tools', () => {
        expect(fileCapabilities(workspace).map(c => c.name)).toEqual(
            ['fs.list', 'fs.read', 'fs.move', 'fs.rename', 'fs.trash'],
        );
    });

    it('a move + a rename in one run both reverse newest-first via undoAll', async () => {
        touch('a.txt'); touch('b.txt');
        const consent = new InMemoryConsentStore();
        fileCapabilities(workspace).forEach(c => consent.setGranted(c.name, true));
        const session = new RunSession();
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async () => true, () => 0, session);

        await runner.execute(new FsMoveCapability(workspace), 'a.txt to docs');
        await runner.execute(new FsRenameCapability(workspace), 'b.txt to c.txt');
        expect(session.undoableCount).toBe(2);
        expect(exists('docs/a.txt')).toBe(true);
        expect(exists('c.txt')).toBe(true);

        await session.undoAll();
        expect(exists('a.txt')).toBe(true);       // move reversed
        expect(exists('b.txt')).toBe(true);       // rename reversed
        expect(exists('docs/a.txt')).toBe(false);
        expect(exists('c.txt')).toBe(false);
        expect(session.undoableCount).toBe(0);
    });
});
