export interface UIElement {
    id: number;
    text: string;
    contentDesc: string;
    className: string;
    resourceId: string;
    clickable: boolean;
    scrollable: boolean;
    focusable: boolean;
    enabled: boolean;
    visible: boolean;
    bounds: string;
    center: { x: number; y: number };
    rect: { x: number; y: number; width: number; height: number };
}

export interface AgentEvents {
    status: (msg: string) => void;
    error: (msg: string) => void;
    observe: (elements: UIElement[]) => void;
    decide: (command: string) => void;
    action: (msg: string) => void;
    done: () => void;
}

export interface IDeviceService {
    dumpUI(): Promise<string>;
    screencap(): Promise<string>;
    tap(x: number, y: number): Promise<void>;
    typeText(text: string, clearFirst?: boolean): Promise<void>;
    swipe(x1: number, y1: number, x2: number, y2: number, durationMs?: number): Promise<void>;
    keyevent(code: number): Promise<void>;
}

export interface ILlmProvider {
    generateCode(prompt: string): Promise<string>;
    generalChat(prompt: string): Promise<string>;
    generateAction(systemPrompt: string, userPrompt: string, options: any, imagePath?: string): Promise<string>;
}
