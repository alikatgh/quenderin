import { execFile } from 'child_process';

/**
 * The Windows/Linux automation seam — the mission ("say a thing, Quenderin does it on your
 * computer") reaching beyond macOS. Same discipline as `MacAutomation`: capabilities are built on
 * THIS seam so they're testable with a fake, and no capability ever hands the model an arbitrary
 * executor.
 *
 * Injection stance — STRONGER than escaping: every command is a FIXED binary + FIXED argument
 * strings; user/model values travel ONLY as (a) their own argv elements (never parsed by a shell —
 * execFile) or (b) environment variables that a fixed PowerShell script reads via `$env:` (never
 * concatenated into script text). There is no string-interpolation layer to escape at all.
 */
export interface CommandRunner {
    /** Run `argv[0]` with the remaining elements as arguments (no shell), returning stdout.
     *  `env` entries are ADDED to the child's environment (the fixed-script value channel). */
    run(argv: string[], env?: Record<string, string>): Promise<string>;
    /** The OS this runner drives: 'win32' | 'linux' | others. */
    platform(): NodeJS.Platform;
    available(): boolean;
}

/** Typed failures the capabilities translate into honest user messages. */
export type RunnerErrorCode = 'CMD_TIMEOUT' | 'CMD_MISSING' | 'CMD_ERROR';

/** The real implementation: execFile with a timeout — argv semantics end to end. */
export class ExecFileRunner implements CommandRunner {
    constructor(private readonly timeoutMs = 20_000) { }

    platform(): NodeJS.Platform {
        return process.platform;
    }

    available(): boolean {
        return process.platform === 'win32' || process.platform === 'linux';
    }

    run(argv: string[], env?: Record<string, string>): Promise<string> {
        const [cmd, ...args] = argv;
        return new Promise((resolve, reject) => {
            execFile(cmd, args, {
                timeout: this.timeoutMs,
                maxBuffer: 1024 * 1024,
                env: env ? { ...process.env, ...env } : process.env,
                windowsHide: true,
            }, (err, stdout, stderr) => {
                if (err) {
                    const e = err as NodeJS.ErrnoException & { killed?: boolean };
                    if (e.killed) return reject(Object.assign(new Error(`${cmd} timed out`), { code: 'CMD_TIMEOUT' }));
                    if (e.code === 'ENOENT') return reject(Object.assign(new Error(`${cmd} is not installed`), { code: 'CMD_MISSING', binary: cmd }));
                    return reject(Object.assign(new Error(stderr.trim() || err.message), { code: 'CMD_ERROR' }));
                }
                resolve(stdout.replace(/\r\n/g, '\n').trim());
            });
        });
    }
}

/** PowerShell invocation prefix — a FIXED script only; values ride in env vars. `-NoProfile`
 *  keeps user profiles (and their side effects) out; `-NonInteractive` refuses prompts. */
export function powershell(fixedScript: string): string[] {
    return ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', fixedScript];
}
