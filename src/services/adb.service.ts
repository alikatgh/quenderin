import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import { IDeviceService } from '../types/index.js';

export class AdbService implements IDeviceService {
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

    public async checkDevice(): Promise<boolean> {
        try {
            const out = await this.spawnAdb(['devices']);
            const lines = out.split('\n');
            return lines.length > 1 && lines[1].trim().length > 0;
        } catch (e) {
            return false;
        }
    }

    public async dumpUI(): Promise<string> {
        const tempFileName = `window_dump_${crypto.randomUUID()}.xml`;
        const tempFile = path.join(os.tmpdir(), tempFileName);

        await this.spawnAdb(['shell', 'uiautomator', 'dump', '/sdcard/window_dump.xml']);
        await this.spawnAdb(['pull', '/sdcard/window_dump.xml', tempFile]);

        const content = await fs.readFile(tempFile, 'utf-8');
        await fs.unlink(tempFile).catch(() => { });
        return content;
    }

    public async screencap(): Promise<string> {
        const tempFileName = `screen_${crypto.randomUUID()}.png`;
        const tempPath = path.join(os.tmpdir(), tempFileName);

        await this.spawnAdb(['shell', 'screencap', '-p', '/sdcard/screen.png']);
        await this.spawnAdb(['pull', '/sdcard/screen.png', tempPath]);
        return tempPath;
    }

    public async tap(x: number, y: number): Promise<void> {
        await this.spawnAdb(['shell', 'input', 'tap', Math.round(x).toString(), Math.round(y).toString()]);
    }

    public async typeText(text: string, clearFirst: boolean = true): Promise<void> {
        if (clearFirst) {
            await this.spawnAdb(['shell', 'input', 'keyevent', '123']);
            const deletes = Array(50).fill('67');
            await this.spawnAdb(['shell', 'input', 'keyevent', ...deletes]);
        }
        // Safely passes text as an exact argument, no shell parsing
        await this.spawnAdb(['shell', 'input', 'text', text]);
    }

    public async swipe(x1: number, y1: number, x2: number, y2: number, durationMs: number = 300): Promise<void> {
        await this.spawnAdb(['shell', 'input', 'swipe', Math.round(x1).toString(), Math.round(y1).toString(), Math.round(x2).toString(), Math.round(y2).toString(), durationMs.toString()]);
    }

    public async keyevent(code: number): Promise<void> {
        await this.spawnAdb(['shell', 'input', 'keyevent', code.toString()]);
    }
}
