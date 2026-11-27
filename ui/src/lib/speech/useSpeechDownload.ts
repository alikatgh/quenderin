import type { SpeechApi } from './api.js';
import type { SpeechDownloadEvent, SpeechDownloadSnapshot } from './types.js';

export interface UseSpeechDownloadOptions {
    readonly modelId: string | null;
    /** Injectable client for tests. */
    readonly api?: SpeechApi;
    /** Snapshot restored from GET /api/speech/downloads/:modelId. */
    readonly initialSnapshot?: SpeechDownloadSnapshot | null;
    readonly onInstalled?: (modelId: string) => void;
    readonly onError?: (snapshot: SpeechDownloadSnapshot) => void;
}

export interface SpeechDownloadController {
    readonly snapshot: SpeechDownloadSnapshot | null;
    readonly isActive: boolean;
    start(): Promise<void>;
    pause(): Promise<void>;
    resume(): Promise<void>;
    cancel(): Promise<void>;
    retry(): Promise<void>;
}

/**
 * Subscribe to `speech_download_progress` WS frames for one model and expose
 * start/pause/resume/cancel/retry. The hook is the only place that mutates
 * download state so the picker and Settings never disagree.
 */
export function useSpeechDownload(_options: UseSpeechDownloadOptions): SpeechDownloadController {
    throw new Error('TODO(stage2): subscribe to WS snapshots and call the typed speech API.');
}

/** Pure reducer used by the hook and its tests; ignores other model ids. */
export function applySpeechDownloadEvent(
    _current: SpeechDownloadSnapshot | null,
    _event: SpeechDownloadEvent,
): SpeechDownloadSnapshot | null {
    throw new Error('TODO(stage2): merge a progress event for the subscribed model.');
}
