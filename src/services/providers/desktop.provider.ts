import { EventEmitter } from 'events';
import { IDeviceProvider } from '../../types/index.js';
import screenshot from 'screenshot-desktop';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';

interface RobotJsLike {
    moveMouse(x: number, y: number): void;
    mouseClick(): void;
    typeString(text: string): void;
    scrollMouse(x: number, y: number): void;
    keyTap(key: string): void;
}

export class DesktopProvider extends EventEmitter implements IDeviceProvider {
    private robot: RobotJsLike | null = null;
    private robotLoaded = false;

    constructor() {
        super();
    }

    /**
     * Lazily import robotjs via ESM-compatible dynamic import.
     * robotjs is optional — desktop mode is gracefully degraded if it isn't installed.
     */
    private async getRobot(): Promise<RobotJsLike | null> {
        if (this.robotLoaded) return this.robot;
        this.robotLoaded = true;
        try {
            // robotjs is a CJS module; Node ESM supports dynamic import() of CJS.
            const mod = await import('robotjs');
            this.robot = (mod.default ?? mod) as RobotJsLike;
        } catch {
            console.warn(
                "[DesktopProvider] 'robotjs' is not installed or failed to compile. " +
                "Run 'npm install robotjs' and ensure build tools (make, python) are available."
            );
        }
        return this.robot;
    }

    public async click(x: number, y: number): Promise<void> {
        const robot = await this.getRobot();
        if (!robot) return;
        robot.moveMouse(x, y);
        robot.mouseClick();
    }

    public async type(text: string): Promise<void> {
        const robot = await this.getRobot();
        if (!robot) return;
        robot.typeString(text);
    }

    public async scroll(direction: 'up' | 'down'): Promise<void> {
        const robot = await this.getRobot();
        if (!robot) return;
        if (direction === 'up') {
            robot.scrollMouse(0, 50);
        } else {
            robot.scrollMouse(0, -50);
        }
    }

    public async pressKey(key: string): Promise<void> {
        const robot = await this.getRobot();
        if (!robot) return;
        let mappedKey = key.toLowerCase();
        if (mappedKey === 'back') mappedKey = 'escape';
        if (mappedKey === 'home') mappedKey = 'command';

        try {
            robot.keyTap(mappedKey);
        } catch {
            console.error(`[DesktopProvider] Invalid key '${mappedKey}' passed to robotjs`);
        }
    }

    public async getScreenContext(): Promise<{ xml: string, screenshotPath: string }> {
        // Desktop OS does not have a global accessibility XML tree that we can rapidly dump like Android uiautomator.
        // We MUST rely on the Multimodal LLM to analyze the screenshot via OCR (built in Phase 7).
        const xml = ""; // Silent fallback for VLM coordinate mapping

        const uuid = crypto.randomUUID();
        const pngTempFile = path.join(os.tmpdir(), `desktop_screen_${uuid}.png`);

        try {
            await screenshot({ filename: pngTempFile, format: 'png' });
            return { xml, screenshotPath: pngTempFile };
        } catch {
            throw new Error("Unable to capture screen. Please ensure Quenderin has Screen Recording permissions in your OS settings.");
        }
    }
}
