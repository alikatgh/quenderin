import type { apiFetch } from '../api.js';
import type {
    SpeechDownloadSnapshot,
    SpeechModelListResponse,
    SpeechSettingsResponse,
    SpeechTranscriptionResponse,
    UpdateSpeechSettingsRequest,
} from './types.js';

/** The authenticated fetch used by every state-changing call. */
export type SpeechFetch = typeof apiFetch;

export interface SpeechApiOptions {
    /** Injectable for tests; defaults to apiFetch. */
    readonly fetchImpl?: SpeechFetch;
}

export interface TranscribeOptions {
    readonly modelId: string;
    readonly language?: string;
    readonly autoSend?: boolean;
    readonly signal?: AbortSignal;
}

/** Typed client for /api/speech/*. Errors surface as SpeechApiError with a code. */
export interface SpeechApi {
    listModels(signal?: AbortSignal): Promise<SpeechModelListResponse>;
    startDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    getDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    pauseDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    resumeDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    cancelDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    retryDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    getSettings(): Promise<SpeechSettingsResponse>;
    updateSettings(patch: UpdateSpeechSettingsRequest): Promise<SpeechSettingsResponse>;
    transcribe(wav: Blob, options: TranscribeOptions): Promise<SpeechTranscriptionResponse>;
}

export class SpeechApiError extends Error {
    readonly status: number;
    readonly code: string;

    constructor(message: string, status: number, code: string) {
        super(message);
        this.name = 'SpeechApiError';
        this.status = status;
        this.code = code;
    }
}

/** Create the client; the implementation is Stage 2's. */
export function createSpeechApi(_options: SpeechApiOptions = {}): SpeechApi {
    throw new Error('TODO(stage2): implement the typed /api/speech client with apiFetch and error codes.');
}
