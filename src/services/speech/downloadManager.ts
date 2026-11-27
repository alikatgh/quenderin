import type {
    HandySpeechCatalog,
    HandySpeechModel,
} from './types.js';
import type {
    SpeechDownloadError,
    SpeechDownloadSnapshot,
} from './types.js';

/** Minimal response surface the manager needs; a real `Response` satisfies it. */
export interface SpeechDownloadHttpResponse {
    readonly ok: boolean;
    readonly status: number;
    readonly headers: { get(name: string): string | null };
    /** Node's fetch body is a ReadableStream, which is async-iterable. */
    readonly body: AsyncIterable<Uint8Array> | null;
}

export interface SpeechDownloadHttpInit {
    readonly headers?: Readonly<Record<string, string>>;
    readonly signal?: AbortSignal;
}

/** Injectable fetch so every download test runs offline on fixtures. */
export type SpeechDownloadFetch = (
    url: string,
    init: SpeechDownloadHttpInit,
) => Promise<SpeechDownloadHttpResponse>;

export interface SpeechDownloadStat {
    readonly size: number;
}

export interface SpeechDownloadFileHandle {
    write(chunk: Uint8Array): Promise<void>;
    close(): Promise<void>;
}

/** Injectable filesystem: enough for Range resume, atomic rename and hashing. */
export interface SpeechDownloadFileSystem {
    stat(filePath: string): Promise<SpeechDownloadStat | null>;
    mkdir(directory: string, options: { readonly recursive: true }): Promise<void>;
    open(filePath: string, flags: 'a' | 'w'): Promise<SpeechDownloadFileHandle>;
    rename(from: string, to: string): Promise<void>;
    unlink(filePath: string): Promise<void>;
    createReadStream(filePath: string): AsyncIterable<Uint8Array>;
}

export interface SpeechDownloadRetryPolicy {
    /** Total attempts including the first. */
    readonly maxAttempts: number;
    readonly baseDelayMs: number;
    readonly maxDelayMs: number;
}

export interface SpeechDownloadManagerOptions {
    readonly catalog: HandySpeechCatalog;
    /** Directory that receives `<filename>` and `<filename>.part`. */
    readonly modelsDir: string;
    /** Pinned transcribe.cpp version from shared/speech-runtime.json. */
    readonly pinnedEngineVersion: string;
    readonly fetchImpl: SpeechDownloadFetch;
    readonly fs: SpeechDownloadFileSystem;
    readonly now?: () => number;
    readonly retry?: SpeechDownloadRetryPolicy;
    /** 0–100 progress callback; the route bridges this to the WS event. */
    readonly onProgress?: (snapshot: SpeechDownloadSnapshot) => void;
    /** Only one download runs at a time; the rest stay queued. */
    readonly maxConcurrent?: number;
}

export type SpeechDownloadListener = (snapshot: SpeechDownloadSnapshot) => void;

/**
 * Background downloader for the curated Handy ASR files.
 *
 * Contract (fully specified in docs/design/voice-stt-picker.md):
 *   - stream to `<filename>.part`, never to the final name;
 *   - resume with `Range: bytes=<.part size>-` and expect 206; 416 means the
 *     partial is stale and is restarted from zero;
 *   - pause aborts the request but keeps the `.part`;
 *   - verify exact size + SHA-256, then atomically rename `.part` → final;
 *   - checksum mismatch deletes the `.part` and surfaces checksum-mismatch;
 *   - retry transient network/5xx failures with exponential backoff + jitter;
 *   - never download a model whose minEngine exceeds the pinned runtime.
 */
export class SpeechDownloadManager {
    constructor(_options: SpeechDownloadManagerOptions) {
        throw new Error('TODO(stage2): construct the download manager from injected fetch/fs/clock.');
    }

    /** Current snapshot for every known model id (idle when untouched). */
    snapshots(): readonly SpeechDownloadSnapshot[] {
        throw new Error('TODO(stage2): return snapshots for every catalog model, idle when untouched.');
    }

    snapshot(_modelId: string): SpeechDownloadSnapshot | null {
        throw new Error('TODO(stage2): return the live snapshot for a model id.');
    }

    /** Queue a model; rejects unsupported engines, unknown ids and bad installs. */
    async start(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): enqueue and start a download.');
    }

    /** Stop reading, keep the .part, phase → paused. */
    async pause(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): pause an active download and keep its .part.');
    }

    /** Resume with an HTTP Range request from the .part size. */
    async resume(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): resume from .part with Range and handle 206/416.');
    }

    /** Abort, delete the .part and return to idle. */
    async cancel(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): abort, delete .part and reset to idle.');
    }

    /** Retry after a failed attempt, honouring the backoff policy. */
    async retry(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): retry the last failed download with backoff.');
    }

    /** Verify an existing file (size + SHA-256) without downloading. */
    async verifyInstalled(_modelId: string): Promise<SpeechDownloadSnapshot> {
        throw new Error('TODO(stage2): verify an existing GGUF and mark it installed or delete it.');
    }

    /** Subscribe to progress; returns an unsubscribe function. */
    subscribe(_listener: SpeechDownloadListener): () => void {
        throw new Error('TODO(stage2): register a typed progress listener.');
    }

    /** Map a thrown error / HTTP status onto the contract's error kinds. */
    classifyError(_error: unknown, _status?: number): SpeechDownloadError {
        throw new Error('TODO(stage2): classify network, disk-full, checksum, 404, 416 and permission errors.');
    }

    /** Throws unsupported-engine when the model's minEngine exceeds the runtime. */
    assertEngineSupported(_model: HandySpeechModel): void {
        throw new Error('TODO(stage2): compare model.minEngine with pinnedEngineVersion.');
    }
}
