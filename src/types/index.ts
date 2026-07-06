import { EventEmitter } from 'events';

/** Metadata about a generation run (tok/s, TTFT, etc.) */
export interface GenerationMeta {
    tokenCount: number;
    durationMs: number;
    tokensPerSecond: number;
    timeToFirstTokenMs: number;
}

/** Options accepted by generateAction (all optional). */
export interface GenerationOptions {
    maxTokens?: number;
    temperature?: number;
    onTextChunk?: (chunk: string) => void;
}

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
    action_required: (payload: { code: string, title: string, message: string }) => void;
    model_download_progress: (payload: { progress: number; modelId?: string }) => void;
}

export interface IDeviceProvider extends EventEmitter {
    click(x: number, y: number): Promise<void>;
    type(text: string): Promise<void>;
    scroll(direction: 'up' | 'down'): Promise<void>;
    pressKey(key: string): Promise<void>;
    getScreenContext(): Promise<{ xml: string, screenshotPath: string }>;
}

export interface ILlmProvider extends EventEmitter {
    generalChat(prompt: string, onToken?: (token: string) => void, opts?: { plainChat?: boolean }): Promise<{ text: string; meta: GenerationMeta }>;
    generateAction(systemPrompt: string, userPrompt: string, options: GenerationOptions, imagePath?: string, signal?: AbortSignal): Promise<string>;
    /** True while chat or agent/action inference holds the shared model (GPU/CPU). */
    isCurrentlyGenerating(): { isGenerating: boolean; buffer: string };
}

export interface AgentAction {
    action: 'click' | 'input' | 'scroll' | 'key' | 'done';
    id?: number | string;
    target_id?: number | string;
    x?: number;
    y?: number;
    text?: string;
    direction?: 'up' | 'down' | 'left' | 'right';
    /** Hardware/navigation key for the 'key' action: 'back' | 'home' | 'enter'. */
    key?: string;
}
