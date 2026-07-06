import os from 'os';
import path from 'path';

/**
 * Expand a leading `~` to the user's home directory. The shell does this before a command ever
 * runs, so a bare `--workspace ~/Downloads` already arrives expanded — but a QUOTED flag
 * (`--workspace "~/Downloads"`) or a value read from a config file does NOT, and `path.resolve`
 * treats `~` as a literal folder name. Expanding here makes both paths behave like the shell.
 */
export function expandTilde(p: string): string {
    if (p === '~') return os.homedir();
    if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2));
    return p;
}
