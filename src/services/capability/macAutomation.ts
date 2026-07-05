import { execFile } from 'child_process';

/**
 * The macOS automation seam — the door to "anything possible in macOS" (the sharpened mission,
 * 2026-07-05). AppleScript / Apple Events is the richest surface: it scripts Mail, Calendar,
 * Notes, Reminders, Finder, Safari, Messages, and can UI-drive ANY app via System Events.
 *
 * Capabilities are built on THIS seam (not raw osascript calls), so they're testable with a fake
 * and, crucially, so no capability ever hands the model a "run arbitrary script" hole — each
 * capability composes a BOUNDED, typed AppleScript template with escaped inputs. "Anything" is a
 * growing library of governed actions, never one ungoverned executor.
 */
export interface MacAutomation {
    /** Run an AppleScript and return its stdout. Rejects on error / non-macOS. */
    runAppleScript(script: string): Promise<string>;
    /** Whether this machine can run AppleScript (darwin). */
    available(): boolean;
}

/**
 * Escape a value for safe embedding inside an AppleScript double-quoted string literal. The input
 * is LLM-produced while steered by untrusted on-screen/content — it must never break out of the
 * literal (the AppleScript analog of the ADB shell-escaping the AndroidProvider already does).
 * Control chars (newlines/tabs) are normalized to spaces so a value can't smuggle in extra
 * AppleScript statements; then backslash and double-quote are escaped.
 */
export function escapeAppleScriptString(value: string): string {
    return value
        // eslint-disable-next-line no-control-regex
        .replace(/[\u0000-\u001F\u007F]+/g, ' ')  // control chars (newlines/tabs) -> space: no smuggled statements
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"');
}

/** The real implementation: `osascript -e <script>` via execFile (no shell), darwin-only. */
export class OsascriptAutomation implements MacAutomation {
    constructor(private readonly timeoutMs = 20_000) { }

    available(): boolean {
        return process.platform === 'darwin';
    }

    runAppleScript(script: string): Promise<string> {
        if (!this.available()) {
            return Promise.reject(Object.assign(new Error('AppleScript is macOS-only'), { code: 'MAC_ONLY' }));
        }
        return new Promise((resolve, reject) => {
            // execFile, NOT exec — the script is an argv element, never parsed by a shell. Combined
            // with escapeAppleScriptString for interpolated values, that closes both injection
            // layers (shell + AppleScript-string).
            execFile('osascript', ['-e', script], { timeout: this.timeoutMs, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
                if (err) {
                    const e = err as NodeJS.ErrnoException & { killed?: boolean };
                    if (e.killed) return reject(Object.assign(new Error('AppleScript timed out'), { code: 'MAC_TIMEOUT' }));
                    return reject(Object.assign(new Error(stderr.trim() || err.message), { code: 'MAC_ERROR' }));
                }
                resolve(stdout.trim());
            });
        });
    }
}
