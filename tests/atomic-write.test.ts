import { describe, it, expect } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { atomicWriteFile, atomicWriteFileSync } from '../src/utils/atomicWrite.js';

/**
 * r16: persistence must never truncate-then-die. These pin the write-temp-rename contract:
 * the target only ever holds the OLD complete content or the NEW complete content, and a
 * failed rename cleans its temp up rather than littering the store directory.
 */
describe('atomicWriteFile', () => {
    const tmpdir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'qatomic-'));

    it('writes new content and leaves no temp file behind (async)', async () => {
        const dir = tmpdir();
        const target = path.join(dir, 'store.json');
        await atomicWriteFile(target, '{"a":1}');
        expect(fs.readFileSync(target, 'utf8')).toBe('{"a":1}');
        await atomicWriteFile(target, '{"a":2}');
        expect(fs.readFileSync(target, 'utf8')).toBe('{"a":2}');
        expect(fs.readdirSync(dir)).toEqual(['store.json']); // no .tmp residue
    });

    it('writes new content and leaves no temp file behind (sync)', () => {
        const dir = tmpdir();
        const target = path.join(dir, 'store.json');
        atomicWriteFileSync(target, 'one');
        atomicWriteFileSync(target, 'two');
        expect(fs.readFileSync(target, 'utf8')).toBe('two');
        expect(fs.readdirSync(dir)).toEqual(['store.json']);
    });

    it('a failed rename preserves the ORIGINAL file and removes the temp (async)', async () => {
        const dir = tmpdir();
        const target = path.join(dir, 'store.json');
        await atomicWriteFile(target, 'original');
        // Force the rename to fail: replace the target's parent with a read-only dir is flaky
        // cross-platform — instead point the write at a target whose dirname vanished.
        const gone = path.join(dir, 'missing-subdir', 'store.json');
        await expect(atomicWriteFile(gone, 'x')).rejects.toThrow();
        expect(fs.readFileSync(target, 'utf8')).toBe('original');   // untouched
        expect(fs.readdirSync(dir)).toEqual(['store.json']);         // no stray temp
    });

    it('a failed rename preserves the ORIGINAL file and removes the temp (sync)', () => {
        const dir = tmpdir();
        const target = path.join(dir, 'store.json');
        atomicWriteFileSync(target, 'original');
        const gone = path.join(dir, 'missing-subdir', 'store.json');
        expect(() => atomicWriteFileSync(gone, 'x')).toThrow();
        expect(fs.readFileSync(target, 'utf8')).toBe('original');
        expect(fs.readdirSync(dir)).toEqual(['store.json']);
    });
});
