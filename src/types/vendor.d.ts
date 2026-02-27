/**
 * Ambient module declarations for dependencies that ship no TypeScript types.
 * This prevents implicit-any TS errors without needing @types/* packages.
 */

declare module 'screenshot-desktop' {
    interface ScreenshotOptions {
        filename?: string;
        format?: 'png' | 'jpg';
        screen?: number | string;
    }
    function screenshot(options?: ScreenshotOptions): Promise<Buffer>;
    export = screenshot;
}

declare module 'robotjs' {
    function moveMouse(x: number, y: number): void;
    function mouseClick(button?: string, double?: boolean): void;
    function typeString(text: string): void;
    function scrollMouse(x: number, y: number): void;
    function keyTap(key: string, modifier?: string | string[]): void;
    function getMousePos(): { x: number; y: number };
    function getScreenSize(): { width: number; height: number };
}

declare module 'whisper-node' {
    interface WhisperOptions {
        modelName?: string;
        modelPath?: string;
        whisperOptions?: {
            word_timestamps?: boolean;
            language?: string;
        };
    }
    interface Transcript {
        start: string;
        end: string;
        speech: string;
    }
    function whisper(audioPath: string, options?: WhisperOptions): Promise<Transcript[]>;
    export { whisper };
    export default whisper;
}
