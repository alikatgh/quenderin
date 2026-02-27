import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import { EventEmitter } from 'events';
import { IDeviceProvider } from '../../types/index.js';

export class AndroidProvider extends EventEmitter implements IDeviceProvider {
    constructor() {
        super();
    }
    // Helper to safely execute adb commands without a shell
    private async spawnAdb(args: string[]): Promise<string> {
        return new Promise((resolve, reject) => {
            const proc = spawn('adb', args);
            let stdout = '';
            let stderr = '';

            proc.stdout.on('data', (data) => stdout += data.toString());
            proc.stderr.on('data', (data) => stderr += data.toString());

            proc.on('close', (code) => {
                const output = (stdout + stderr).toLowerCase();

                // ADB doesn't always exit with > 0 when "no devices" occurs
                if (code === 0 && !output.includes('error: no devices') && !output.includes('error: device unauthorized')) {
                    resolve(stdout.trim());
                } else {
                    let errCode = 'ADB_ERROR';
                    let title = 'ADB Error';
                    let message = 'An unknown ADB error occurred.';

                    if (output.includes('no devices/emulators found') || output.includes('device offline')) {
                        errCode = 'ADB_MISSING';
                        title = 'Android Device Not Found';
                        message = 'Ensure your emulator is running or Android device is connected via USB.';
                    } else if (output.includes('unauthorized')) {
                        errCode = 'ADB_UNAUTHORIZED';
                        title = 'Device Unauthorized';
                        message = 'Please check your Android device screen and authorize the USB debugging connection.';
                    }

                    // Reject with a clean, user-friendly error instead of raw shell trace
                    const error = new Error(title);
                    (error as any).code = errCode;
                    reject(error);
                }
            });
        });
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
        } catch (e) {
            return ""; // Fallback to empty string for bad reads
        }
    }

    private async waitForUiIdle(): Promise<void> {
        return new Promise(async (resolve) => {
            let lastXml = "";
            let stableCount = 0;
            const maxPolls = 10; // Up to ~5 seconds (10 * 500ms)

            for (let i = 0; i < maxPolls; i++) {
                // Short wait between snapshots
                await new Promise(res => setTimeout(res, 500));

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
            resolve();
        });
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
        // Hardcoding standard device resolution center points for now layout emulation
        const width = 1080;
        const height = 2400;
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
