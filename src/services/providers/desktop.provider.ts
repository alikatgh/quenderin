import { EventEmitter } from 'events';
import { IDeviceProvider } from '../../types/index.js';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';
import { execSync } from 'child_process';
import logger from '../../utils/logger.js';

interface RobotJsLike {
    moveMouse(x: number, y: number): void;
    mouseClick(): void;
    typeString(text: string): void;
    scrollMouse(x: number, y: number): void;
    keyTap(key: string): void;
}

interface ScreenshotLike {
    (options: { filename: string; format: string }): Promise<unknown>;
}

export class DesktopProvider extends EventEmitter implements IDeviceProvider {
    private robot: RobotJsLike | null = null;
    private robotLoaded = false;
    // Memoize the in-flight init PROMISE, not a boolean flag — see getScreenshotFn (deep-hunt race fix).
    private screenshotFnPromise: Promise<ScreenshotLike> | null = null;

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
            const mod = await import('robotjs');
            this.robot = (mod.default ?? mod) as RobotJsLike;
        } catch {
            logger.warn(
                "[DesktopProvider] 'robotjs' is not installed or failed to compile. " +
                "Desktop input control is disabled. Install it with 'npm install robotjs' if needed."
            );
        }
        return this.robot;
    }

    /**
     * Lazily import screenshot-desktop. Falls back to platform-native tools
     * (screencapture on macOS, import/gnome-screenshot on Linux, PowerShell on Windows)
     * when the native module isn't available.
     */
    private getScreenshotFn(): Promise<ScreenshotLike> {
        // Memoize the in-flight init PROMISE so concurrent callers await the SAME import. The old boolean
        // flag was set BEFORE the async import resolved, so a second concurrent caller saw "loaded" but a
        // still-undefined fn and double-initialized (deep-hunt race).
        if (!this.screenshotFnPromise) {
            this.screenshotFnPromise = this.loadScreenshotFn();
        }
        return this.screenshotFnPromise;
    }

    private async loadScreenshotFn(): Promise<ScreenshotLike> {
        try {
            const mod = await import('screenshot-desktop');
            const fn = mod.default ?? mod;
            return (opts: { filename: string; format: string }) =>
                fn({ filename: opts.filename, format: opts.format as 'png' | 'jpg' });
        } catch {
            logger.warn("[DesktopProvider] 'screenshot-desktop' unavailable, using platform-native fallback.");
        }

        // Platform-native fallback — no native module needed
        return async (opts: { filename: string; format: string }) => {
            const { filename } = opts;
            const platform = process.platform;
            try {
                if (platform === 'darwin') {
                    execSync(`screencapture -x "${filename}"`, { timeout: 10000 });
                } else if (platform === 'linux') {
                    // Try common Linux screenshot tools in order of likelihood
                    try {
                        execSync(`gnome-screenshot -f "${filename}"`, { timeout: 10000, stdio: 'pipe' });
                    } catch {
                        try {
                            execSync(`import -window root "${filename}"`, { timeout: 10000, stdio: 'pipe' });
                        } catch {
                            execSync(`scrot "${filename}"`, { timeout: 10000, stdio: 'pipe' });
                        }
                    }
                } else if (platform === 'win32') {
                    // PowerShell-based screenshot capture (works on all Windows 10+)
                    const psScript = `
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
$bitmap.Save('${filename.replace(/'/g, "''")}')
$graphics.Dispose()
$bitmap.Dispose()`;
                    execSync(`powershell -NoProfile -Command "${psScript.replace(/\n/g, '; ')}"`, { timeout: 15000, stdio: 'pipe' });
                } else {
                    throw new Error(`Unsupported platform for screenshots: ${platform}`);
                }
            } catch {
                throw new Error(
                    `Native screenshot failed on ${platform}. ` +
                    `Install 'screenshot-desktop' (npm install screenshot-desktop) or ensure ` +
                    `a screenshot tool is available (scrot/gnome-screenshot on Linux).`
                );
            }
        };
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
            logger.error(`[DesktopProvider] Invalid key '${mappedKey}' passed to robotjs`);
        }
    }

    public async getScreenContext(): Promise<{ xml: string, screenshotPath: string }> {
        // Desktop OS does not have a global accessibility XML tree that we can rapidly dump like Android uiautomator.
        // We MUST rely on the Multimodal LLM to analyze the screenshot via OCR (built in Phase 7).
        const xml = ""; // Silent fallback for VLM coordinate mapping

        const uuid = crypto.randomUUID();
        const pngTempFile = path.join(os.tmpdir(), `desktop_screen_${uuid}.png`);

        try {
            const capture = await this.getScreenshotFn();
            await capture({ filename: pngTempFile, format: 'png' });
            return { xml, screenshotPath: pngTempFile };
        } catch {
            throw new Error("Unable to capture screen. Please ensure Quenderin has Screen Recording permissions in your OS settings.");
        }
    }
}
