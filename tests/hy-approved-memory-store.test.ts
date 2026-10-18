import { describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { HyApprovedMemoryStore } from '../src/services/hyApprovedMemoryStore.js';
import { WINDOWS_MEMORY_ACL_POLICY, WINDOWS_MEMORY_ACL_SCRIPT } from '../src/services/windowsPrivateMemoryAcl.js';

describe('private explicitly approved Hy memory bank', () => {
    it('requires Windows ACL proof before any selected fact is written', async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-hy-private-test-'));
        try {
            const directory = path.join(root, 'not-created'), acl = { ensureDirectory: vi.fn(async () => { throw new Error('ACL fixture failure'); }), verifyFile: vi.fn(async () => {}) };
            const store = new HyApprovedMemoryStore(directory, 'win32', acl);
            expect(await store.saveNote(`Hy memory ${crypto.randomUUID()}`, 'Synthetic fixture fact')).toHaveProperty('error');
            expect(fs.existsSync(directory)).toBe(false);
            const privateDirectory = path.join(root, 'private'), verifyFile = vi.fn(async (file: string) => { expect(fs.statSync(file).size).toBe(0); throw new Error('File ACL fixture failure'); });
            const second = new HyApprovedMemoryStore(privateDirectory, 'win32', { ensureDirectory: async folder => { fs.mkdirSync(folder, { mode: 0o700 }); }, verifyFile });
            expect(await second.saveNote(`Hy memory ${crypto.randomUUID()}`, 'Synthetic fixture fact')).toHaveProperty('error');
            expect(verifyFile).toHaveBeenCalledOnce(); expect(fs.readdirSync(privateDirectory)).toEqual([]);
            expect(WINDOWS_MEMORY_ACL_POLICY.principals).toEqual(['currentUser', 'SYSTEM', 'BuiltinAdministrators']);
            expect(WINDOWS_MEMORY_ACL_SCRIPT).toContain("'S-1-5-18', 'S-1-5-32-544'");
            for (const broad of ['S-1-1-0', 'S-1-5-11', 'S-1-5-32-545']) expect(WINDOWS_MEMORY_ACL_SCRIPT).not.toContain(broad);
        } finally { fs.rmSync(root, { recursive: true }); }
    });
    it.skipIf(process.platform === 'win32')('serializes exclusive atomic UUID writes, uses private modes and retries idempotently', async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-hy-private-test-'));
        try {
            const folder = path.join(root, 'approved-memories'), store = new HyApprovedMemoryStore(folder), id = crypto.randomUUID();
            const first = await store.saveNote(`Hy memory ${id}`, 'Synthetic fixture fact');
            expect(first).toHaveProperty('path'); expect(fs.statSync(folder).mode & 0o777).toBe(0o700);
            const record = path.join(folder, `${id}.json`), before = fs.statSync(record);
            expect(before.mode & 0o777).toBe(0o600); expect(JSON.parse(fs.readFileSync(record, 'utf8'))).toEqual({ id, text: 'Synthetic fixture fact' });
            const retries = await Promise.all(Array.from({ length: 8 }, () => store.saveNote(`Hy memory ${id}`, 'Synthetic fixture fact')));
            expect(retries.every(value => 'path' in value)).toBe(true); expect(fs.statSync(record).ino).toBe(before.ino);
            expect(await store.saveNote(`Hy memory ${id}`, 'Different synthetic fixture')).toHaveProperty('error');
            expect(fs.readdirSync(folder)).toEqual([`${id}.json`]); expect(fs.readFileSync(record, 'utf8')).toContain('Synthetic fixture fact');
        } finally { fs.rmSync(root, { recursive: true }); }
    });
    it.skipIf(process.platform === 'win32')('rejects unsafe existing directories, symlink records and malformed approvals without altering them', async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-hy-private-test-'));
        try {
            const directory = path.join(root, 'legacy-notes'); fs.mkdirSync(directory, { mode: 0o755 });
            expect(await new HyApprovedMemoryStore(directory).saveNote(`Hy memory ${crypto.randomUUID()}`, 'Synthetic fixture fact')).toHaveProperty('error');
            expect(fs.statSync(directory).mode & 0o777).toBe(0o755); expect(fs.readdirSync(directory)).toEqual([]);
            const privateFolder = path.join(root, 'private'); fs.mkdirSync(privateFolder, { mode: 0o700 });
            const original = path.join(root, 'original.txt'); fs.writeFileSync(original, 'Synthetic original fixture');
            const id = crypto.randomUUID(), alias = path.join(privateFolder, `${id}.json`); fs.symlinkSync(original, alias);
            const store = new HyApprovedMemoryStore(privateFolder);
            expect(await store.saveNote(`Hy memory ${id}`, 'Synthetic fixture fact')).toHaveProperty('error');
            expect(await store.saveNote('Hy memory ../../escape', 'Synthetic fixture fact')).toHaveProperty('error');
            expect(await store.saveNote(`Hy memory ${crypto.randomUUID()}`, '<think>private</think>')).toHaveProperty('error');
            expect(fs.readFileSync(original, 'utf8')).toBe('Synthetic original fixture'); expect(fs.lstatSync(alias).isSymbolicLink()).toBe(true);
        } finally { fs.rmSync(root, { recursive: true }); }
    });
    it.runIf(process.platform === 'win32')('uses actual protected Windows ACLs for a tiny synthetic approved fact', async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-hy-windows-acl-test-'));
        try {
            const folder = path.join(root, 'approved-memories'), store = new HyApprovedMemoryStore(folder), id = crypto.randomUUID();
            expect(await store.saveNote(`Hy memory ${id}`, 'Synthetic Windows ACL fixture fact')).toHaveProperty('path');
            expect(await store.saveNote(`Hy memory ${id}`, 'Synthetic Windows ACL fixture fact')).toHaveProperty('path');
            expect(fs.readdirSync(folder)).toEqual([`${id}.json`]);
            expect(JSON.parse(fs.readFileSync(path.join(folder, `${id}.json`), 'utf8')).text).toBe('Synthetic Windows ACL fixture fact');
        } finally { fs.rmSync(root, { recursive: true }); }
    });
});
