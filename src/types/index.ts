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

export interface IDeviceProvider {
    click(x: number, y: number): Promise<void>;
    type(text: string): Promise<void>;
    scroll(direction: 'up' | 'down'): Promise<void>;
    pressKey(key: string): Promise<void>;
    getScreenContext(): Promise<{ xml: string, screenshotPath: string }>;
}

export interface ILlmProvider {
    generateCode(prompt: string): Promise<string>;
    generalChat(prompt: string): Promise<string>;
    generateAction(systemPrompt: string, userPrompt: string, options: any, imagePath?: string): Promise<string>;
}

export interface AgentAction {
    action: 'click' | 'input' | 'scroll' | 'done';
    id?: number | string;
    x?: number;
    y?: number;
    text?: string;
    direction?: 'up' | 'down' | 'left' | 'right';
}
