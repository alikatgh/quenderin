import os from 'os';
import path from 'path';
import { describe, it, expect } from 'vitest';
import { expandTilde } from '../src/utils/paths.js';

/**
 * `--workspace ~/Downloads` typed at a shell arrives already expanded, but a QUOTED flag or a
 * config-file value does not — and path.resolve treats a leading ~ as a literal folder. This makes
 * both behave like the shell, so the config example we document actually works.
 */
describe('expandTilde', () => {
    it('expands a bare ~ to the home directory', () => {
        expect(expandTilde('~')).toBe(os.homedir());
    });

    it('expands ~/… to a path under home (and resolves cleanly)', () => {
        expect(expandTilde('~/Downloads')).toBe(path.join(os.homedir(), 'Downloads'));
        // The bug this fixes: without expansion, resolve() would produce <cwd>/~/Downloads.
        expect(path.resolve(expandTilde('~/Downloads'))).toBe(path.join(os.homedir(), 'Downloads'));
    });

    it('leaves absolute, relative, and mid-string ~ paths untouched', () => {
        expect(expandTilde('/Users/me/Downloads')).toBe('/Users/me/Downloads');
        expect(expandTilde('./stuff')).toBe('./stuff');
        expect(expandTilde('Downloads')).toBe('Downloads');
        expect(expandTilde('/opt/~backup')).toBe('/opt/~backup');   // ~ not at the start → literal
    });
});
