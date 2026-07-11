import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import { EventEmitter } from 'events';
import { IDeviceProvider } from '../../types/index.js';
import { getHardwareProfile } from '../../utils/hardware.js';

const HW = getHardwareProfile();

/**
 * Split text so a LITERAL "%s" never lands inside a single `adb shell input text` argument (r-uc #2).
 * Android's `input text` substitutes "%s" → a space and is escape-UNAWARE, so `\%s` still becomes a
 * space on the device. Breaking between the '%' and the 's' — sending them via separate `input text`
 * calls — is the only way to type a literal "%s"; each returned segment is encoded/escaped separately.
 * A string with no literal "%s" returns as a single segment (unchanged one-call behavior).
 */
export function splitLiteralPercentS(text: string): string[] {
    const segments: string[] = [];
    let start = 0;
    for (let i = 0; i + 1 < text.length; i++) {
        if (text[i] === '%' && text[i + 1] === 's') {
            segments.push(text.slice(start, i + 1)); // segment ends WITH the '%'
            start = i + 1;                            // next segment starts AT the 's'
        }
    }
    segments.push(text.slice(start));
    return segments.filter(s => s.length > 0);
}

export class AndroidProvider extends EventEmitter implements IDeviceProvider {
    /** ADB command timeout scales with hardware — slow devices need more time */
    private readonly adbTimeoutMs = Math.round(15_000 * HW.timeoutMultiplier);
    /** Wait between UI idle polls — longer on embedded to reduce ADB round-trips */
    private readonly uiIdlePollMs = HW.tier === 'embedded' ? 1000 : HW.tier === 'constrained' ? 750 : 500;
    /** Cached device screen dimensions — queried once from the device */
    private screenWidth: number = 0;
    private screenHeight: number = 0;
    /** When the cached dims were last SUCCESSFULLY queried (ms). 0 = never. r-uc #10. */
    private screenDimsAtMs = 0;
    private static readonly SCREEN_DIMS_TTL_MS = 15_000;

    constructor() {
        super();
    }

    // Helper to safely execute adb commands without a shell — with timeout
    private async spawnAdb(args: string[], timeoutMs?: number): Promise<string> {
        const timeout = timeoutMs ?? this.adbTimeoutMs;
        return new Promise((resolve, reject) => {
            const proc = spawn('adb', args);
            let stdout = '';
            let stderr = '';
            let killed = false;

            const timer = setTimeout(() => {
                killed = true;
                proc.kill('SIGKILL');
                const error = new Error(`ADB command timed out after ${Math.round(timeout / 1000)}s: adb ${args.join(' ')}`) as Error & { code?: string };
                error.code = 'ADB_TIMEOUT';
                reject(error);
            }, timeout);

            proc.stdout.on('data', (data) => stdout += data.toString());
            proc.stderr.on('data', (data) => stderr += data.toString());

            proc.on('close', (code) => {
                clearTimeout(timer);
                if (killed) return; // Already rejected by timeout

                const output = (stdout + stderr).toLowerCase();

                // ADB doesn't always exit with > 0 when "no devices" occurs
                if (code === 0 && !output.includes('error: no devices') && !output.includes('error: device unauthorized')) {
                    resolve(stdout.trim());
                } else {
                    let errCode = 'ADB_ERROR';
                    let title = 'ADB Error';

                    if (output.includes('no devices/emulators found') || output.includes('device offline')) {
                        errCode = 'ADB_MISSING';
                        title = 'Android Device Not Found';
                    } else if (output.includes('unauthorized')) {
                        errCode = 'ADB_UNAUTHORIZED';
                        title = 'Device Unauthorized';
                    }

                    // Reject with a clean, user-friendly error instead of raw shell trace
                    const error = new Error(title) as Error & { code?: string };
                    error.code = errCode;
                    reject(error);
                }
            });

            proc.on('error', (err: Error & { code?: string }) => {
                clearTimeout(timer);
                if (killed) return;   // timeout already rejected; ignore the late spawn error
                // spawn() itself failed — almost always ENOENT: adb / Android platform-tools not
                // installed or not on PATH. Without this handler the 'error' event is unhandled (Node
                // re-throws it as an uncaught exception) and 'close' never fires, so the promise would
                // otherwise hang until the misleading ADB_TIMEOUT. Route it through ADB_MISSING handling.
                const error = new Error(
                    err.code === 'ENOENT'
                        ? 'Android tooling (adb) not found — install Android platform-tools or add adb to PATH.'
                        : `Failed to launch adb: ${err.message}`
                ) as Error & { code?: string };
                error.code = 'ADB_MISSING';
                reject(error);
            });
        });
    }

    /** Query actual device screen resolution via ADB instead of hardcoding */
    private async getScreenDimensions(): Promise<{ width: number; height: number }> {
        // r-uc #10: cache with a TTL (a rotation/fold changes w×h, and the old cache-forever swiped
        // to the wrong place after it) AND only pin the cache on a SUCCESSFUL query — the old code set
        // the "queried" flag before the query, so ONE transient failure permanently pinned the
        // 1080×2400 fallback even once the device became queryable again.
        const now = Date.now();
        if (this.screenWidth > 0 && now - this.screenDimsAtMs < AndroidProvider.SCREEN_DIMS_TTL_MS) {
            return { width: this.screenWidth, height: this.screenHeight };
        }
        try {
            const output = await this.spawnAdb(['shell', 'wm', 'size']);
            // Output format: "Physical size: 1080x2400" or "Override size: 1080x2400"
            const match = output.match(/(\d+)x(\d+)/);
            if (match) {
                this.screenWidth = parseInt(match[1], 10);
                this.screenHeight = parseInt(match[2], 10);
                this.screenDimsAtMs = now;   // cache ONLY on success
                return { width: this.screenWidth, height: this.screenHeight };
            }
        } catch {
            // Query failed — fall through. Do NOT pin: leave screenDimsAtMs stale so the next call retries.
        }
        // Failure/unparseable: reuse the last GOOD dims if we ever had them; otherwise a one-shot
        // default that is NOT cached (screenDimsAtMs stays 0), so a later successful query can replace it.
        if (this.screenWidth > 0) return { width: this.screenWidth, height: this.screenHeight };
        return { width: 1080, height: 2400 };
    }

    // Helper to get just the UI XML quickly without screenshot overhead
    private async getUiHierarchyXml(): Promise<string> {
        const uuid = crypto.randomUUID();
        const xmlFileName = `window_dump_poll_${uuid}.xml`;
        const xmlTempFile = path.join(os.tmpdir(), xmlFileName);

        const devXml = `/sdcard/${xmlFileName}`;   // unique device-side path too (M5)
        try {
            await this.spawnAdb(['shell', 'uiautomator', 'dump', devXml]);
            await this.spawnAdb(['pull', devXml, xmlTempFile]);
            await this.spawnAdb(['shell', 'rm', '-f', devXml]).catch(() => { });
            const xml = await fs.readFile(xmlTempFile, 'utf-8');
            await fs.unlink(xmlTempFile).catch(() => { });
            return xml;
        } catch {
            return ""; // Fallback to empty string for bad reads
        }
    }

    private async waitForUiIdle(): Promise<void> {
        let lastXml = "";
        let stableCount = 0;
        // Scale max polls with hardware: embedded gets more time per poll but same total budget
        const maxPolls = 10;

        for (let i = 0; i < maxPolls; i++) {
            // Wait between snapshots — scales with hardware tier
            await new Promise(res => setTimeout(res, this.uiIdlePollMs));

            const currentXml = await this.getUiHierarchyXml();

            // Compare length/structure coarsely first, falling back to full string equality
            if (currentXml && currentXml === lastXml) {
                stableCount++;
            } else {
                stableCount = 0;
            }

            lastXml = currentXml;

            // Two consecutive identical snapshots = UI has settled
            if (stableCount >= 2) {
                break;
            }
        }
    }

    public async click(x: number, y: number): Promise<void> {
        await this.spawnAdb(['shell', 'input', 'tap', Math.round(x).toString(), Math.round(y).toString()]);
        await this.waitForUiIdle();
    }

    public async type(text: string): Promise<void> {
        // Clear field first
        await this.spawnAdb(['shell', 'input', 'keyevent', '123']); // MOVE_END
        // A single `input keyevent 67 67 …` fires only ONE delete on Android <=9 (multi-keycode is
        // ignored), leaving stale text in the field. Run a device-side loop so all 50 fire everywhere (L4).
        await this.spawnAdb(['shell', 'i=0; while [ $i -lt 50 ]; do input keyevent 67; i=$((i+1)); done']);

        // `adb shell input text` runs under the DEVICE shell, which re-tokenizes the joined args
        // and re-splits `input text` on spaces. So a raw string can (a) inject device-shell
        // commands — `"a; reboot"` would run `reboot` (H1) — and (b) lose everything after the
        // first space (M9). The text is LLM-produced while steered by untrusted on-screen content.
        // Encode spaces as `%s` (input's space token) and backslash-escape shell metacharacters.
        // Normalize non-space whitespace to spaces FIRST: mapping tab/newline/CR to `\<char>` made the
        // device shell treat `\<newline>` as line-continuation (dropping it) and `\<CR>` truncate the
        // token on some shells — corrupting typed text from pasted/multiline content. `input text`
        // can't type real newlines anyway (M4).
        const normalized = text.replace(/[\t\n\r\f\v]+/g, ' ');
        // r-uc #2: a LITERAL "%s" in the text collides with `input text`'s %s→space substitution, which
        // is escape-UNAWARE (an escaped `\%` still leaves the `%` adjacent to the `s`, and the device
        // shell strips the backslash) — so "increase%special" rendered "increase pecial". Split the text
        // so the `%` and the following `s` land in SEPARATE `input text` calls; then they can never form
        // the substitution. Each segment still encodes its own spaces as %s and escapes shell metachars.
        const escapeSegment = (s: string) => s.replace(/[\s\\"'`$()<>|;&*?~[\]{}#!%]/g, (c) => (c === ' ' ? '%s' : '\\' + c));
        for (const segment of splitLiteralPercentS(normalized)) {
            await this.spawnAdb(['shell', 'input', 'text', escapeSegment(segment)]);
        }
        await this.waitForUiIdle();
    }

    public async scroll(direction: 'up' | 'down'): Promise<void> {
        // Query actual device resolution instead of hardcoding
        const { width, height } = await this.getScreenDimensions();
        const startX = width / 2;
        const startY = height / 2;

        let endY = startY;
        if (direction === 'down') {
            endY = startY - (height * 0.3); // Swipe up to scroll down
        } else if (direction === 'up') {
            endY = startY + (height * 0.3); // Swipe down to scroll up
        }

        await this.spawnAdb(['shell', 'input', 'swipe', Math.round(startX).toString(), Math.round(startY).toString(), Math.round(startX).toString(), Math.round(endY).toString(), '300']);
        await this.waitForUiIdle();
    }

    public async pressKey(key: string): Promise<void> {
        // r-uc #9: an UNKNOWN key must NOT silently become ENTER — the old `let code = '66'` default
        // meant a typo or an unmapped key (`tab`, `esc`, `search`…) pressed ENTER, which can submit a
        // form / send a message the agent never intended. Map explicitly; reject the unknown.
        const KEYCODES: Record<string, string> = {
            enter: '66', back: '4', home: '3', tab: '61', space: '62',
            delete: '67', backspace: '67', escape: '111', esc: '111',
        };
        const code = KEYCODES[key.toLowerCase().trim()];
        if (!code) {
            throw new Error(`Unsupported key "${key}" — no keyevent sent (refusing to fall back to ENTER).`);
        }
        await this.spawnAdb(['shell', 'input', 'keyevent', code]);
        await this.waitForUiIdle();
    }

    public async getScreenContext(): Promise<{ xml: string, screenshotPath: string }> {
        // Ensure UI is totally idle before returning the primary visual context to the LLM agent
        await this.waitForUiIdle();

        const uuid = crypto.randomUUID();
        const xmlFileName = `window_dump_${uuid}.xml`;
        const pngFileName = `screen_${uuid}.png`;

        const xmlTempFile = path.join(os.tmpdir(), xmlFileName);
        const pngTempFile = path.join(os.tmpdir(), pngFileName);

        // Unique DEVICE-side paths too (M5): the local temp files were UUID'd but the on-device dump
        // paths were fixed, so overlapping ADB ops (concurrent idle-polls / multi-device) could pull a
        // stale or mid-write dump. Suffix the device path and rm it after pull.
        const devXml = `/sdcard/${xmlFileName}`;
        const devPng = `/sdcard/${pngFileName}`;
        // r-uc #18: `.finally` the device-side rm so the /sdcard dump is removed even when the pull
        // FAILS after a successful dump (the old `.then(rm)` only ran on the happy path → device leak).
        // `rm -f` is harmless if the dump itself never created the file.
        await Promise.all([
            this.spawnAdb(['shell', 'uiautomator', 'dump', devXml])
                .then(() => this.spawnAdb(['pull', devXml, xmlTempFile]))
                .finally(() => this.spawnAdb(['shell', 'rm', '-f', devXml]).catch(() => { })),
            this.spawnAdb(['shell', 'screencap', '-p', devPng])
                .then(() => this.spawnAdb(['pull', devPng, pngTempFile]))
                .finally(() => this.spawnAdb(['shell', 'rm', '-f', devPng]).catch(() => { }))
        ]);

        let xml: string;
        try {
            xml = await fs.readFile(xmlTempFile, 'utf-8');
        } catch (e) {
            // The read failed — clean up BOTH local temps so a bad pull doesn't leak into /tmp either.
            await fs.unlink(xmlTempFile).catch(() => { });
            await fs.unlink(pngTempFile).catch(() => { });
            throw e;
        }
        await fs.unlink(xmlTempFile).catch(() => { });

        return { xml, screenshotPath: pngTempFile };
    }
}
