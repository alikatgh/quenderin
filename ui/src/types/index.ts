/** Metadata about a generation run (tok/s, TTFT, etc.) */
export interface GenerationMeta {
    tokenCount: number;
    durationMs: number;
    tokensPerSecond: number;
    timeToFirstTokenMs: number;
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

export interface LogEntry {
    id: string;
    type: 'status' | 'observe' | 'decide' | 'action' | 'error' | 'done' | 'chat' | 'chat_response' | 'chat_stream' | 'log';
    message: string;
    timestamp: string;
    elements?: UIElement[];
    command?: string;
    isStreaming?: boolean;
    meta?: GenerationMeta;
}
