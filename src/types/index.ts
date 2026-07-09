import { EventEmitter } from 'events';

/** Metadata about a generation run (tok/s, TTFT, etc.) */
export interface GenerationMeta {
    tokenCount: number;
    durationMs: number;
    tokensPerSecond: number;
    timeToFirstTokenMs: number;
    /** Number of tool/function calls actually EXECUTED during this generation (0 = none).
     *  Distinguishes "the model used a tool" from "the model fabricated tool-ish text". */
    toolCalls?: number;
}

/** Options accepted by generateAction (all optional). */
export interface GenerationOptions {
    maxTokens?: number;
    temperature?: number;
    onTextChunk?: (chunk: string) => void;
    /** When set, decoding is grammar-constrained to this JSON schema: the model is structurally
     *  incapable of emitting output that doesn't parse. Providers without grammar support (fakes,
     *  unavailable bindings) ignore it — callers must still run their text parser on the result. */
    jsonSchema?: Record<string, unknown>;
    /** Opaque key. Calls sharing a cacheKey reuse one KV-cache sequence, so the shared prompt
     *  prefix (system prompt, goal, attachments) is not re-prefilled on every call. Purely a
     *  performance hint — each call still behaves as an independent, stateless prompt. */
    cacheKey?: string;
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
    /** Q-549 Step 2: the bulk brake fired — the loop SELF-paused after `executed` device actions
     *  and is waiting for the user's Resume (or Stop). */
    bulk_confirm: (payload: { executed: number; threshold: number }) => void;
    /** Q-549 Step 3: opt-in per-run mission approval is waiting for the user. The mission has not
     *  driven the device yet. Resolve via the configured MissionApprover (dashboard / WS). */
    mission_approval: (payload: { goal: string }) => void;
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
    /** Free the KV-cache sequence held for a GenerationOptions.cacheKey (e.g. at mission end).
     *  Optional: fakes and providers without KV reuse simply don't implement it. */
    releaseActionCache?(cacheKey: string): void;
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
