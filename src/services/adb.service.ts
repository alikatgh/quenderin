import { exec } from 'child_process';
import { promisify } from 'util';
import fs from 'fs/promises';
import path from 'path';
import { IDeviceService } from '../types/index.js';

const execAsync = promisify(exec);

export class AdbService implements IDeviceService {
    public async execAdb(command: string): Promise<string> {
        try {
            const { stdout } = await execAsync(`adb ${command}`);
            return stdout.trim();
        } catch (error: any) {
            throw new Error(`ADB Command failed: ${command} (${error.message})`);
        }
    }

    public async checkDevice(): Promise<boolean> {
        try {
            const out = await this.execAdb('devices');
            const lines = out.split('\n');
            return lines.length > 1 && lines[1].trim().length > 0;
        } catch (e) {
            return false;
        }
    }

    public async dumpUI(): Promise<string> {
        await this.execAdb('shell uiautomator dump /sdcard/window_dump.xml');
        const tempFile = path.join(process.cwd(), 'window_dump.xml');
        await this.execAdb(`pull /sdcard/window_dump.xml ${tempFile}`);
        const content = await fs.readFile(tempFile, 'utf-8');
        await fs.unlink(tempFile).catch(() => { });
        return content;
    }
    public async screencap(): Promise<string> {
        await this.execAdb('shell screencap -p /sdcard/screen.png');
        const tempPath = path.join(process.cwd(), 'screen.png');
        await this.execAdb(`pull /sdcard/screen.png ${tempPath}`);
        return tempPath;
    }
    public async tap(x: number, y: number): Promise<void> {
        await this.execAdb(`shell input tap ${Math.round(x)} ${Math.round(y)}`);
    }

    public async typeText(text: string, clearFirst: boolean = true): Promise<void> {
        if (clearFirst) {
            // Move cursor to end of text
            await this.execAdb(`shell input keyevent 123`); // KEYCODE_MOVE_END
            // Send 50 backspaces to clear any existing text (idempotent primitive)
            const deletes = Array(50).fill('67').join(' ');
            await this.execAdb(`shell input keyevent ${deletes}`); // KEYCODE_DEL
        }
        const escaped = text.replace(/ /g, '%s').replace(/"/g, '\\"');
        await this.execAdb(`shell input text "${escaped}"`);
    }

    public async swipe(x1: number, y1: number, x2: number, y2: number, durationMs: number = 300): Promise<void> {
        await this.execAdb(`shell input swipe ${Math.round(x1)} ${Math.round(y1)} ${Math.round(x2)} ${Math.round(y2)} ${durationMs}`);
    }

    public async keyevent(code: number): Promise<void> {
        await this.execAdb(`shell input keyevent ${code}`);
    }
}
