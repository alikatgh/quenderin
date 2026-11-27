// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Port of Handy src-tauri/src/managers/model/download.rs at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See native/speech/NOTICE.md.
import { modelFile } from '@handy-computer/models';
import { createHash } from 'node:crypto';
import { constants, createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { findCatalogModel, installedModelPath, modelDownloadUrl } from './catalog.js';
import { SpeechError } from './errors.js';
import { engineCompatibility } from './grading.js';
import type {
    HandySpeechCatalog,
    HandySpeechModel,
} from './types.js';
import type {
    SpeechDownloadError,
    SpeechDownloadErrorKind,
    SpeechDownloadPhase,
    SpeechDownloadSnapshot,
} from './types.js';

/** Minimal response surface the manager needs; a real `Response` satisfies it. */
export interface SpeechDownloadHttpResponse {
    readonly ok: boolean;
    readonly status: number;
    readonly headers: { get(name: string): string | null };
    /** Node's fetch body is a ReadableStream, which is async-iterable. */
    readonly body: AsyncIterable<Uint8Array> | null;
    discard?(): Promise<void>;
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
    readonly identity?: string;
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
    createReadStream(filePath: string, signal?: AbortSignal): AsyncIterable<Uint8Array>;
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
    readonly random?: () => number;
    readonly sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
    readonly networkIdleMs?: number;
    readonly retry?: SpeechDownloadRetryPolicy;
    /** 0–100 progress callback; the route bridges this to the WS event. */
    readonly onProgress?: (snapshot: SpeechDownloadSnapshot) => void;
    /** Only one download runs at a time; the rest stay queued. */
    readonly maxConcurrent?: number;
}

export type SpeechDownloadListener = (snapshot: SpeechDownloadSnapshot) => void;

export const speechDownloadFs: SpeechDownloadFileSystem = {
    async stat(filePath) {
        try {
            const info = await fs.lstat(filePath, { bigint: true });
            if (!info.isFile()) {
                throw new SpeechError('permission', 409, 'The speech model path must be a regular file.');
            }
            return { size: Number(info.size), identity: [info.dev, info.ino, info.mtimeNs, info.ctimeNs].join(':') };
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
            throw error;
        }
    },
    async mkdir(directory) { await fs.mkdir(directory, { recursive: true, mode: 0o700 }); },
    async open(filePath, flags) {
        const mode = flags === 'a' ? constants.O_APPEND : constants.O_TRUNC;
        const file = await fs.open(filePath, constants.O_WRONLY | constants.O_CREAT | mode | (constants.O_NOFOLLOW ?? 0), 0o600);
        return {
            async write(chunk) {
                let offset = 0;
                while (offset < chunk.length) {
                    const { bytesWritten } = await file.write(chunk, offset, chunk.length - offset);
                    if (!bytesWritten) throw new Error('Could not write the speech model.');
                    offset += bytesWritten;
                }
            },
            close: () => file.close(),
        };
    },
    rename: fs.rename,
    async unlink(filePath) { await fs.rm(filePath, { force: true }); },
    createReadStream: (filePath, signal) => createReadStream(filePath, {
        flags: (constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)) as unknown as string,
        highWaterMark: 1024 * 1024, signal,
    }),
};

export const fetchSpeechArtifact: SpeechDownloadFetch = async (url, init) => {
    // Reconstruct the request for each attempt; fetch only follows HTTP(S) redirects.
    const response = await fetch(url, init);
    const source = response.body;
    return {
        ok: response.ok, status: response.status, headers: response.headers,
        body: source && (async function* () {
            const reader = source.getReader();
            try {
                for (;;) {
                    const next = await reader.read();
                    if (next.done) return;
                    yield next.value;
                }
            } finally {
                await reader.cancel().catch(() => {});
                reader.releaseLock();
            }
        })(),
        discard: async () => { if (source) await source.cancel().catch(() => {}); },
    };
};

const DOWNLOAD_STALL_TIMEOUT_MS = 60_000;
const PROGRESS_THROTTLE_MS = 100;
const PROGRESS_TICK_MS = 1000;
const RATE_WINDOW_MS = 5000;
const RATE_MIN_SPAN_MS = 1000;

class RateMeter {
    private samples: { time: number; bytes: number }[] = [];

    constructor(private readonly startBytes: number) {}

    sample(bytes: number, now: number): number | null {
        if (!this.samples.length && bytes <= this.startBytes) return null;
        this.samples.push({ time: now, bytes });
        while (this.samples.length > 2 && now - this.samples[1].time >= RATE_WINDOW_MS) {
            this.samples.shift();
        }
        const anchor = this.samples[0];
        const span = now - anchor.time;
        return span < RATE_MIN_SPAN_MS ? null : (bytes - anchor.bytes) * 1000 / span;
    }
}

function contentRangeStart(value: string | null): number | undefined {
    const start = value?.trim().match(/^bytes\s*(\d+)\s*-/)?.[1];
    return start === undefined ? undefined : Number(start);
}

const defaultRetry = { maxAttempts: 5, baseDelayMs: 500, maxDelayMs: 30_000 };
const errorMessages: Record<SpeechDownloadErrorKind, string> = {
    network: 'Download interrupted. Check your connection and retry.',
    'disk-full': 'The disk is full. Free some space and retry.',
    'checksum-mismatch': 'The downloaded file failed verification. Download it again.',
    'http-404': 'The model file is missing at its pinned revision.',
    'http-416': 'The server could not resume this file. Retry from the beginning.',
    'http-size': 'The server advertised a file size that differs from the catalog.',
    'unsupported-engine': 'Needs newer speech engine.',
    permission: 'Quenderin cannot access the speech models folder. Check its permissions and retry.',
    cancelled: 'Download cancelled.',
    unknown: 'The speech model download failed. Try again.',
};

function failure(kind: SpeechDownloadErrorKind, status = 500, message = errorMessages[kind]): SpeechError {
    return new SpeechError(kind, status, message);
}

interface Job {
    snapshot: SpeechDownloadSnapshot;
    controller?: AbortController;
    work?: Promise<void>;
}

export class SpeechDownloadManager {
    private readonly jobs = new Map<string, Job>();
    private readonly queue = new Set<string>();
    private readonly verified = new Map<string, string>();
    private readonly commands = new Map<string, Promise<void>>();
    private readonly listeners = new Set<SpeechDownloadListener>();
    private readonly now: () => number;
    private readonly policy: SpeechDownloadRetryPolicy;
    private active = 0;
    private closed = false;

    constructor(private readonly options: SpeechDownloadManagerOptions) {
        this.now = options.now ?? Date.now;
        this.policy = options.retry ?? defaultRetry;
        if (options.onProgress) this.subscribe(options.onProgress);
    }

    snapshots(): readonly SpeechDownloadSnapshot[] {
        return this.options.catalog.curatedModels.map(model => this.snapshot(model.id) ?? this.idle(model));
    }

    snapshot(modelId: string): SpeechDownloadSnapshot | null {
        return this.jobs.get(modelId)?.snapshot ?? null;
    }

    /** Recover an installed or paused download after a process restart. */
    status(modelId: string): Promise<SpeechDownloadSnapshot | null> {
        return this.command(modelId, async model => {
            const job = this.jobs.get(modelId);
            if (job && job.snapshot.phase !== 'installed' && job.snapshot.phase !== 'idle') return job.snapshot;
            const installed = await this.checkInstalled(model);
            if (installed) return this.job(model).snapshot;
            const part = await this.options.fs.stat(this.part(model));
            if (part) return this.publish(model, 'paused', Math.min(part.size, modelFile(model).size));
            return null;
        });
    }

    start(modelId: string): Promise<SpeechDownloadSnapshot> {
        return this.command(modelId, async model => {
            this.assertEngineSupported(model);
            const current = this.snapshot(modelId);
            if (current && ['queued', 'downloading', 'verifying'].includes(current.phase)) return current;
            if (await this.checkInstalled(model)) {
                throw new SpeechError('already-installed', 409, 'This speech model is already installed.');
            }
            return this.enqueue(model);
        });
    }

    pause(modelId: string): Promise<SpeechDownloadSnapshot> {
        return this.command(modelId, async model => {
            await this.interrupt(model);
            const current = this.snapshot(modelId);
            if (current?.phase === 'installed') return current;
            const part = await this.options.fs.stat(this.part(model));
            return this.publish(model, 'paused', Math.min(part?.size ?? 0, modelFile(model).size));
        });
    }

    resume(modelId: string): Promise<SpeechDownloadSnapshot> { return this.start(modelId); }
    retry(modelId: string): Promise<SpeechDownloadSnapshot> { return this.start(modelId); }

    cancel(modelId: string): Promise<SpeechDownloadSnapshot> {
        return this.command(modelId, async model => {
            await this.interrupt(model);
            await this.options.fs.unlink(this.part(model));
            const current = this.snapshot(modelId);
            return current?.phase === 'installed' ? current : this.publish(model, 'idle', 0);
        });
    }

    remove(modelId: string): Promise<SpeechDownloadSnapshot> {
        return this.command(modelId, async model => {
            await this.interrupt(model);
            await this.options.fs.unlink(this.part(model));
            await this.options.fs.unlink(this.destination(model));
            this.verified.delete(model.id);
            return this.publish(model, 'idle', 0);
        });
    }

    verifyInstalled(modelId: string): Promise<SpeechDownloadSnapshot> {
        return this.command(modelId, async model => {
            if (!this.jobs.get(modelId)?.work && !this.queue.has(modelId)) await this.checkInstalled(model);
            return this.snapshot(modelId) ?? this.idle(model);
        });
    }

    subscribe(listener: SpeechDownloadListener): () => void {
        this.listeners.add(listener);
        return () => { this.listeners.delete(listener); };
    }

    async shutdown(): Promise<void> {
        this.closed = true;
        this.queue.clear();
        for (const job of this.jobs.values()) job.controller?.abort();
        await Promise.allSettled([...this.jobs.values()].map(job => job.work));
    }

    classifyError(error: unknown, status?: number): SpeechDownloadError {
        if (error instanceof SpeechError && Object.hasOwn(errorMessages, error.code)) {
            return { kind: error.code as SpeechDownloadErrorKind, message: error.message, status: status ?? null };
        }
        const code = (error as NodeJS.ErrnoException | undefined)?.code;
        const kind: SpeechDownloadErrorKind =
            status === 404 ? 'http-404' :
            status === 416 ? 'http-416' :
            status !== undefined && (status >= 500 || status === 429 || status === 408) ? 'network' :
            code === 'ENOSPC' || code === 'EDQUOT' ? 'disk-full' :
            code === 'EACCES' || code === 'EPERM' || code === 'ELOOP' ? 'permission' : 'unknown';
        return { kind, message: errorMessages[kind], status: status ?? null };
    }

    assertEngineSupported(model: HandySpeechModel): void {
        if (engineCompatibility(model.minEngine, this.options.pinnedEngineVersion) !== 'supported') {
            throw failure('unsupported-engine', 409,
                `Needs newer speech engine (${model.minEngine}; installed runtime ${this.options.pinnedEngineVersion}).`);
        }
    }

    private command<T>(modelId: string, operation: (model: HandySpeechModel) => Promise<T>): Promise<T> {
        const model = findCatalogModel(this.options.catalog, modelId);
        if (!model) return Promise.reject(new SpeechError('unknown-model', 404, 'Unknown speech model.'));
        const next = (this.commands.get(modelId) ?? Promise.resolve()).then(() => operation(model));
        const tail = next.then(() => {}, () => {});
        this.commands.set(modelId, tail);
        void tail.then(() => { if (this.commands.get(modelId) === tail) this.commands.delete(modelId); });
        return next;
    }

    private idle(model: HandySpeechModel): SpeechDownloadSnapshot {
        return {
            modelId: model.id, phase: 'idle', downloadedBytes: 0, totalBytes: modelFile(model).size,
            percent: 0, bytesPerSecond: null, etaSeconds: null, error: null, updatedAt: new Date(0).toISOString(),
        };
    }

    private job(model: HandySpeechModel): Job {
        let job = this.jobs.get(model.id);
        if (!job) {
            job = { snapshot: this.idle(model) };
            this.jobs.set(model.id, job);
        }
        return job;
    }

    private publish(model: HandySpeechModel, phase: SpeechDownloadPhase, downloadedBytes: number,
        error: SpeechDownloadError | null = null, bytesPerSecond: number | null = null): SpeechDownloadSnapshot {
        const job = this.job(model);
        const snapshot: SpeechDownloadSnapshot = {
            modelId: model.id, phase, downloadedBytes, totalBytes: modelFile(model).size,
            percent: downloadedBytes / modelFile(model).size * 100,
            bytesPerSecond, etaSeconds: bytesPerSecond ? (modelFile(model).size - downloadedBytes) / bytesPerSecond : null,
            error, updatedAt: new Date(Math.max(this.now(), Date.parse(job.snapshot.updatedAt) + 1)).toISOString(),
        };
        job.snapshot = snapshot;
        for (const listener of this.listeners) {
            try { listener(snapshot); } catch { /* A disconnected listener cannot interrupt model installation. */ }
        }
        return snapshot;
    }

    private destination(model: HandySpeechModel): string {
        return installedModelPath(this.options.modelsDir, model);
    }
    private part(model: HandySpeechModel): string { return this.destination(model) + '.part'; }

    private async interrupt(model: HandySpeechModel): Promise<void> {
        this.queue.delete(model.id);
        const job = this.jobs.get(model.id);
        job?.controller?.abort();
        await job?.work;
    }

    private enqueue(model: HandySpeechModel): SpeechDownloadSnapshot {
        if (this.closed) throw new SpeechError('shutting-down', 503, 'Quenderin is shutting down.');
        this.queue.add(model.id);
        const snapshot = this.publish(model, 'queued', this.job(model).snapshot.downloadedBytes);
        this.drain();
        return snapshot;
    }

    private drain(): void {
        if (this.closed || this.active >= (this.options.maxConcurrent ?? 1)) return;
        const modelId = this.queue.values().next().value;
        if (!modelId) return;
        this.queue.delete(modelId);
        const model = findCatalogModel(this.options.catalog, modelId)!;
        const job = this.job(model);
        const controller = new AbortController();
        job.controller = controller;
        this.active++;
        job.work = this.download(model, controller.signal).finally(() => {
            job.work = undefined;
            job.controller = undefined;
            this.active--;
            this.drain();
        });
        this.drain();
    }

    private async checkInstalled(model: HandySpeechModel): Promise<boolean> {
        const file = this.destination(model);
        const info = await this.options.fs.stat(file);
        if (!info) {
            this.verified.delete(model.id);
            if (this.snapshot(model.id)?.phase === 'installed') this.publish(model, 'idle', 0);
            return false;
        }
        if (info.size === modelFile(model).size && info.identity && this.verified.get(model.id) === info.identity) {
            return true;
        }
        if (!await this.matchesHash(file, model, info)) {
            this.verified.delete(model.id);
            await this.options.fs.unlink(file);
            this.publish(model, 'error', 0, this.classifyError(failure('checksum-mismatch')));
            return false;
        }
        if (info.identity) this.verified.set(model.id, info.identity);
        this.publish(model, 'installed', modelFile(model).size);
        return true;
    }

    private async matchesHash(file: string, model: HandySpeechModel, info: SpeechDownloadStat,
        signal?: AbortSignal): Promise<boolean> {
        if (info.size !== modelFile(model).size) return false;
        const hash = createHash('sha256');
        let bytes = 0;
        for await (const chunk of this.options.fs.createReadStream(file, signal)) {
            signal?.throwIfAborted();
            bytes += chunk.length;
            if (bytes > modelFile(model).size) return false;
            hash.update(chunk);
        }
        const after = await this.options.fs.stat(file);
        return bytes === modelFile(model).size && after?.size === info.size && after.identity === info.identity
            && hash.digest('hex') === modelFile(model).sha256;
    }

    private async download(model: HandySpeechModel, signal: AbortSignal): Promise<void> {
        for (let attempt = 1; attempt <= this.policy.maxAttempts; attempt++) {
            try {
                signal.throwIfAborted();
                await this.options.fs.mkdir(this.options.modelsDir, { recursive: true });
                await this.transfer(model, signal);
                signal.throwIfAborted();
                this.publish(model, 'verifying', modelFile(model).size);
                const part = this.part(model);
                const info = await this.options.fs.stat(part);
                if (!info || !await this.matchesHash(part, model, info, signal)) {
                    signal.throwIfAborted();
                    await this.options.fs.unlink(part);
                    throw failure('checksum-mismatch');
                }
                signal.throwIfAborted();
                await this.options.fs.rename(part, this.destination(model));
                // Rename can change ctime. Cache the identity only if the hashed inode remains in place.
                const installed = await this.options.fs.stat(this.destination(model));
                if (info.identity && installed?.identity
                    && installed.identity.split(':', 3).join(':') === info.identity.split(':', 3).join(':')
                    && installed.size === info.size) this.verified.set(model.id, installed.identity);
                this.publish(model, 'installed', modelFile(model).size);
                return;
            } catch (error) {
                if (signal.aborted) return;
                const status = error instanceof SpeechError && error.status !== 500 ? error.status : undefined;
                const classified = this.classifyError(error, status);
                if (classified.kind === 'network' && attempt < this.policy.maxAttempts) {
                    const jitter = 0.75 + (this.options.random ?? Math.random)() * 0.5;
                    const ms = Math.min(this.policy.maxDelayMs, this.policy.baseDelayMs * 2 ** (attempt - 1) * jitter);
                    this.publish(model, 'queued', this.job(model).snapshot.downloadedBytes);
                    try {
                        await (this.options.sleep ?? ((ms, signal) => delay(ms, undefined, { signal })))(ms, signal);
                        continue;
                    } catch {
                        if (signal.aborted) return;
                    }
                }
                this.publish(model, 'error', classified.kind === 'checksum-mismatch' ? 0 : this.job(model).snapshot.downloadedBytes, classified);
                return;
            }
        }
    }

    private async transfer(model: HandySpeechModel, signal: AbortSignal): Promise<void> {
        const part = this.part(model);
        let offset = (await this.options.fs.stat(part))?.size ?? 0;
        if (offset === modelFile(model).size) return;
        if (offset > modelFile(model).size) {
            await this.options.fs.unlink(part);
            offset = 0;
        }

        // Reset the network timer at each chunk, so a long, progressing download is allowed.
        const controller = new AbortController();
        const abort = () => controller.abort();
        if (signal.aborted) abort();
        signal.addEventListener('abort', abort, { once: true });
        let timer: ReturnType<typeof setTimeout> | undefined;
        const arm = () => {
            clearTimeout(timer);
            timer = setTimeout(abort, this.options.networkIdleMs ?? DOWNLOAD_STALL_TIMEOUT_MS);
            timer.unref?.();
        };
        let response: SpeechDownloadHttpResponse | undefined;
        let tick: ReturnType<typeof setInterval> | undefined;
        try {
            this.publish(model, 'downloading', offset);
            const request = async () => {
                arm();
                try {
                    return await this.options.fetchImpl(modelDownloadUrl(model), {
                        headers: offset ? { Range: `bytes=${offset}-`, 'Accept-Encoding': 'identity' } : { 'Accept-Encoding': 'identity' },
                        signal: controller.signal,
                    });
                } catch {
                    throw failure('network');
                }
            };
            response = await request();
            if (offset && response.status === 416) {
                // A full part was handled before HTTP. The remote object ends before this pin.
                await this.options.fs.unlink(part);
                this.publish(model, 'downloading', 0);
                throw failure('http-416', 416);
            }
            if (offset && response.status === 200) {
                await this.options.fs.unlink(part);
                offset = 0;
            }
            if (!response.ok) {
                const { kind, message } = this.classifyError(null, response.status);
                throw failure(kind, response.status, message);
            }
            const total = modelFile(model).size;
            if (response.status === 206 && (!offset || contentRangeStart(response.headers.get('content-range')) !== offset)) {
                await this.options.fs.unlink(part);
                throw failure('http-416', 416, 'The server returned an unexpected byte range. Retry from the beginning.');
            }
            const length = response.headers.get('content-length');
            if (length !== null && (!/^\d+$/.test(length) || Number(length) + offset !== total)) {
                throw new SpeechError('http-size', 502, 'The server advertised a file size that differs from the catalog.');
            }
            if (!response.body) throw failure('network');

            const file = await this.options.fs.open(part, offset ? 'a' : 'w');
            let bytes = offset;
            const rate = new RateMeter(offset);
            let emitted = this.now();
            const progress = () => {
                emitted = this.now();
                this.publish(model, 'downloading', bytes, null, rate.sample(bytes, emitted));
            };
            progress();
            tick = setInterval(() => {
                if (this.now() - emitted >= PROGRESS_TICK_MS) progress();
            }, PROGRESS_TICK_MS);
            tick.unref?.();
            try {
                const stream = response.body[Symbol.asyncIterator]();
                try {
                    for (;;) {
                        let next: IteratorResult<Uint8Array>;
                        try { next = await stream.next(); } catch { throw failure('network'); }
                        controller.signal.throwIfAborted();
                        clearTimeout(timer);
                        if (next.done) break;
                        if (bytes + next.value.length > total) throw failure('checksum-mismatch');
                        await file.write(next.value);
                        bytes += next.value.length;
                        if (this.now() - emitted >= PROGRESS_THROTTLE_MS) progress();
                        arm();
                    }
                } finally {
                    await stream.return?.();
                }
                progress();
                if (bytes !== total) throw failure('checksum-mismatch');
            } finally {
                await file.close();
            }
        } catch (error) {
            if (signal.aborted) throw error;
            if (controller.signal.aborted) throw failure('network');
            if (error instanceof SpeechError && error.code === 'checksum-mismatch') {
                await this.options.fs.unlink(part);
            }
            throw error;
        } finally {
            clearTimeout(timer);
            clearInterval(tick);
            signal.removeEventListener('abort', abort);
            await response?.discard?.();
        }
    }
}
