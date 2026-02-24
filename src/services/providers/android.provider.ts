import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import { IDeviceProvider } from '../../types/index.js';

export class AndroidProvider implements IDeviceProvider {
    // Helper to safely execute adb commands without a shell
    private async spawnAdb(args: string[]): Promise<string> {
        return new Promise((resolve, reject) => {
            const proc = spawn('adb', args);
            let stdout = '';
            let stderr = '';

            proc.stdout.on('data', (data) => stdout += data.toString());
            proc.stderr.on('data', (data) => stderr += data.toString());

            proc.on('close', (code) => {
                if (code === 0) resolve(stdout.trim());
                else reject(new Error(`ADB Command failed: adb ${args.join(' ')}\n${stderr}`));
            });
        });
    }

    public async click(x: number, y: number): Promise<void> {
        await this.spawnAdb(['shell', 'input', 'tap', Math.round(x).toString(), Math.round(y).toString()]);
    }

    public async type(text: string): Promise<void> {
        // Clear field first
        await this.spawnAdb(['shell', 'input', 'keyevent', '123']);
        const deletes = Array(50).fill('67');
        await this.spawnAdb(['shell', 'input', 'keyevent', ...deletes]);

        // Safely passes text as an exact argument, no shell parsing
        await this.spawnAdb(['shell', 'input', 'text', text]);
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
    }

    public async pressKey(key: string): Promise<void> {
        // Convert generic key strings to ADB Keycodes if needed, rudimentary map for now
        let code = '66'; // ENTER generic fallback
        if (key.toLowerCase() === 'enter') code = '66';
        if (key.toLowerCase() === 'back') code = '4';
        if (key.toLowerCase() === 'home') code = '3';

        await this.spawnAdb(['shell', 'input', 'keyevent', code]);
    }

    public async getScreenContext(): Promise<{ xml: string, screenshotPath: string }> {
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
