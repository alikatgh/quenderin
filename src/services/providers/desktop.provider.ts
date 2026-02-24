import { IDeviceProvider } from '../../types/index.js';

export class DesktopProvider implements IDeviceProvider {
    private robot: any;

    constructor() {
        try {
            // Lazy load robotjs. This requires the user to have build tools (make, python).
            // npm install robotjs
            this.robot = require('robotjs');
        } catch (e) {
            console.warn("⚠️ DesktopProvider depends on 'robotjs'. It is currently not installed or failed to compile on this architecture. Run 'npm install robotjs'.");
        }
    }

    public async click(x: number, y: number): Promise<void> {
        if (!this.robot) return;
        this.robot.moveMouse(x, y);
        this.robot.mouseClick();
    }

    public async type(text: string): Promise<void> {
        if (!this.robot) return;
        // Desktop doesn't have an exact "clear area" native primitive like Android "backspace 50 times"
        // without knowing exactly what input is focused. We just type the string raw.
        this.robot.typeString(text);
    }

    public async scroll(direction: 'up' | 'down'): Promise<void> {
        if (!this.robot) return;
        // Robot.js scrollMouse takes X and Y delta. 
        // Emulate a standard scroll distance.
        if (direction === 'up') {
            this.robot.scrollMouse(0, 50);
        } else {
            this.robot.scrollMouse(0, -50);
        }
    }

    public async pressKey(key: string): Promise<void> {
        if (!this.robot) return;
        // Map generic key strings to robot.js specific strings
        let mappedKey = key.toLowerCase();
        if (mappedKey === 'back') mappedKey = 'escape';
        if (mappedKey === 'home') mappedKey = 'command'; // Desktop equivalent of home is often OS menu

        try {
            this.robot.keyTap(mappedKey);
        } catch (e) {
            console.error(`DesktopProvider: Invalid key '${mappedKey}' passed to robotjs`);
        }
    }

    public async getScreenContext(): Promise<{ xml: string, screenshotPath: string }> {
        // Desktop OS does not have a global accessibility XML tree that we can rapidly dump like Android uiautomator.
        // We MUST rely on the Multimodal LLM to analyze the screenshot via OCR (built in Phase 7).
        console.warn("DesktopProvider: XML dump is not supported natively. Falling back strictly to Vision/OCR loop.");

        // We need to capture the screen. 
        // For a true cross-platform library we might use `screenshot-desktop`.
        // To prevent another compiling block, we ask the user to provide it.
        const screenshotPath = "";
        console.warn("DesktopProvider: Screenshot capturing requires a native library like 'screenshot-desktop'. Please implement it here.");

        return { xml: "", screenshotPath };
    }
}
