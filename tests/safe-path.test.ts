import path from 'path';
import os from 'os';
import { describe, expect, it } from 'vitest';
import { resolveInside } from '../src/utils/safePath.js';

describe('resolveInside', () => {
    const root = path.join(os.tmpdir(), 'quenderin-safe-path');

    it('keeps a plain filename inside the directory', () => {
        expect(resolveInside(root, 'note.md')).toBe(path.resolve(root, 'note.md'));
    });

    it('rejects a leaf that climbs out of the directory', () => {
        expect(() => resolveInside(root, '../outside.txt')).toThrow(/escapes/);
        expect(() => resolveInside(root, '..')).toThrow(/escapes/);
    });

    it('rejects an empty name', () => {
        expect(() => resolveInside(root, '')).toThrow(/Invalid path name/);
    });
});
