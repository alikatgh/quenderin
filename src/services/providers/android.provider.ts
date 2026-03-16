import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import { EventEmitter } from 'events';
import { IDeviceProvider } from '../../types/index.js';
import { getHardwareProfile } from '../../utils/hardware.js';

const HW = getHardwareProfile();

export class AndroidProvider extends EventEmitter implements IDeviceProvider {
    /** ADB command timeout scales with hardware — slow devices need more time */
    private readonly adbTimeoutMs = Math.round(15_000 * HW.timeoutMultiplier);
    /** Wait between UI idle polls — longer on embedded to reduce ADB round-trips */
    private readonly uiIdlePollMs = HW.tier === 'embedded' ? 1000 : HW.tier === 'constrained' ? 750 : 500;
    /** Cached device screen dimensions — queried once from the device */
    private screenWidth: number = 0;
    private screenHeight: number = 0;
    private screenDimsQueried = false;

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
        });
    }

    /** Query actual device screen resolution via ADB instead of hardcoding */
    private async getScreenDimensions(): Promise<{ width: number; height: number }> {
        if (this.screenDimsQueried && this.screenWidth > 0) {
            return { width: this.screenWidth, height: this.screenHeight };
        }
        this.screenDimsQueried = true;
        try {
            const output = await this.spawnAdb(['shell', 'wm', 'size']);
            // Output format: "Physical size: 1080x2400" or "Override size: 1080x2400"
            const match = output.match(/(\d+)x(\d+)/);
            if (match) {
                this.screenWidth = parseInt(match[1], 10);
                this.screenHeight = parseInt(match[2], 10);
                return { width: this.screenWidth, height: this.screenHeight };
            }
        } catch {
            // Fall back to reasonable defaults
        }
        // Default fallback
        this.screenWidth = 1080;
        this.screenHeight = 2400;
        return { width: this.screenWidth, height: this.screenHeight };
    }

    // Helper to get just the UI XML quickly without screenshot overhead
    private async getUiHierarchyXml(): Promise<string> {
        const uuid = crypto.randomUUID();
        const xmlFileName = `window_dump_poll_${uuid}.xml`;
        const xmlTempFile = path.join(os.tmpdir(), xmlFileName);

        try {
            await this.spawnAdb(['shell', 'uiautomator', 'dump', '/sdcard/window_dump.xml']);
            await this.spawnAdb(['pull', '/sdcard/window_dump.xml', xmlTempFile]);
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
        await this.spawnAdb(['shell', 'input', 'keyevent', '123']);
        const deletes = Array(50).fill('67');
        await this.spawnAdb(['shell', 'input', 'keyevent', ...deletes]);

        // Safely passes text as an exact argument, no shell parsing
        await this.spawnAdb(['shell', 'input', 'text', text]);
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
        // Convert generic key strings to ADB Keycodes if needed, rudimentary map for now
        let code = '66'; // ENTER generic fallback
        if (key.toLowerCase() === 'enter') code = '66';
        if (key.toLowerCase() === 'back') code = '4';
        if (key.toLowerCase() === 'home') code = '3';

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

        // Parallelize ADB calls for speed
        await Promise.all([
            this.spawnAdb(['shell', 'uiautomator', 'dump', '/sdcard/window_dump.xml'])
                .then(() => this.spawnAdb(['pull', '/sdcard/window_dump.xml', xmlTempFile])),
            this.spawnAdb(['shell', 'screencap', '-p', '/sdcard/screen.png'])
                .then(() => this.spawnAdb(['pull', '/sdcard/screen.png', pngTempFile]))
        ]);

        const xml = await fs.readFile(xmlTempFile, 'utf-8');
        await fs.unlink(xmlTempFile).catch(() => { });

        return { xml, screenshotPath: pngTempFile };
    }
}
