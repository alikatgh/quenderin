import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';
import { nativeWorkloads, type NativeWorkloadLease } from './nativeWorkloads.js';

export const SPEECH_SAMPLE_RATE_HZ = 16000;
export const SPEECH_MAX_AUDIO_BYTES = 64 * 1024 * 1024;
export const SPEECH_TRANSCRIPTION_TIMEOUT_MS = 5 * 60 * 1000;
export const SPEECH_CAPTURE_TEMP_PREFIX = 'quenderin-speech-capture-';
export const SPEECH_CAPTURE_FILENAME = 'capture.wav';
const STDOUT_LIMIT = 256 * 1024;
const STDERR_LIMIT = 64 * 1024;

export interface SpeechVadManifest {
    id: string;
    label: string;
    repo: string;
    revision: string;
    filename: string;
    localFilename: string;
    bytes: number;
    sha256: string;
    architecture: string;
    variant: string;
    license: string;
    access: string;
}

export interface SpeechModelManifest {
    id: string;
    label: string;
    engine: 'transcribe.cpp' | 'apple_speech' | string;
    architecture: string;
    variant: string;
    repo?: string;
    revision?: string;
    filename?: string | null;
    localFilename?: string | null;
    bytes: number | null;
    sha256?: string | null;
    languages: string[];
    acceptsLanguageHint: boolean;
    supportsLanguageDetection: boolean;
    streams: boolean;
    vocabularyUse: string;
    realtime?: string;
    wordErrorRate?: number;
    license: string;
    access: string;
}

export interface SpeechModelCatalog {
    version: number;
    status: string;
    vad: SpeechVadManifest;
    models: SpeechModelManifest[];
}

export interface SpeechRuntimeLock {
    version: number;
    abiVersion: number;
    revision: string;
    engineVersion: string;
    license: string;
    hex: {
        repository: string;
        revision: string;
        version: string;
        localApiVersion: string;
        license: string;
    };
    bounds: {
        maxAudioBytes: number;
        sampleRateHz: number;
        maxThreads: number;
        maxVocabularyTerms: number;
        maxTermLength: number;
        maxPromptBytes: number;
    };
}

export interface CustomVocabularyTerm {
    term: string;
    phoneticHints?: string[];
    caseSensitive?: boolean;
}

export interface DictationFormatOptions {
    vocabulary?: readonly (string | CustomVocabularyTerm)[];
    removeFillerWords?: boolean;
    spokenPunctuation?: boolean;
    endWithPeriod?: boolean;
    lowercaseOutput?: boolean;
    frenchSpacing?: boolean;
    language?: string;
}

export interface SpeechSegment {
    startMs: number;
    endMs: number;
    text: string;
}

export interface SpeechTranscriptionResult {
    text: string;
    rawText: string;
    language: string;
    backend: string;
    modelId: string;
    durationMs: number;
    truncated: boolean;
    segments: SpeechSegment[];
}

export interface HexReadyHandshake {
    type: 'ready';
    url: string;
    token: string;
    apiVersion: string;
    pid: number;
}

export interface HexDiscoveryInfo {
    port: number;
    token: string;
    apiVersion: string;
    pid?: number;
}

export interface HexPrepareEvent {
    status: string;
    progress?: number;
    downloadedBytes?: number;
    totalBytes?: number;
    message?: string;
}

export interface HexHealthResponse {
    status: string;
    apiVersion?: string;
    modelsLoaded?: string[];
}

export interface HexCapabilitiesResponse {
    apiVersion?: string;
    engines?: string[];
    defaultModel?: string;
}

export interface SpeechNativeRequest {
    model: string;
    directory: string;
    wav: string | Buffer;
    vad?: boolean;
    runtime?: string;
    language?: string;
    prompt?: string;
    threads?: number;
    translate?: boolean;
    timestamps?: boolean;
    format?: DictationFormatOptions;
    signal?: AbortSignal;
}

export interface HexHostTranscribeRequest {
    model: string;
    wav: string | Buffer;
    hexUrl?: string;
    hexToken?: string;
    hexDiscoveryPath?: string;
    hexExecutable?: string;
    prepareModel?: boolean;
    onPrepareProgress?: (event: HexPrepareEvent) => void;
    language?: string;
    format?: DictationFormatOptions;
    signal?: AbortSignal;
}

export type UnifiedSpeechRequest = SpeechNativeRequest | HexHostTranscribeRequest;
type SpawnRuntime = (file: string, args: string[], options: SpawnOptions) => ChildProcess;

export interface HexSpeechDependencies {
    catalog?: SpeechModelCatalog;
    runtimeLock?: SpeechRuntimeLock;
    bundledRuntimePath?: string;
    spawnProcess?: SpawnRuntime;
    fetchImpl?: typeof fetch;
    timeoutMs?: number;
    killGraceMs?: number;
}

function abortIfNeeded(signal?: AbortSignal): void {
    if (signal?.aborted) throw new Error('Speech operation cancelled.');
}

function hasControlCharacters(value: string): boolean {
    for (const character of value) {
        const code = character.charCodeAt(0);
        if (code < 32 || code === 127) return true;
    }
    return false;
}

function sharedDirectory(): string {
    const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
    const candidates = [
        ...(resources ? [path.join(resources, 'shared')] : []),
        fileURLToPath(new URL('../../shared/', import.meta.url)),
        fileURLToPath(new URL('../../../shared/', import.meta.url)),
    ];
    const directory = candidates.find(candidate => fs.existsSync(path.join(candidate, 'speech-model-catalog.json')));
    if (!directory) throw new Error('The bundled speech model catalog is missing.');
    return directory;
}

function safePath(value: string, label: string): string {
    if (!value || hasControlCharacters(value) || value.includes('://')) {
        throw new Error(`${label} must be a local filesystem path.`);
    }
    const resolved = path.resolve(value);
    if (Buffer.byteLength(resolved, 'utf8') > 4096) throw new Error(`${label} path exceeds the native runtime limit.`);
    return resolved;
}

async function directoryPath(value: string): Promise<string> {
    const canonical = await fs.promises.realpath(safePath(value, 'Directory'));
    if (!(await fs.promises.stat(canonical)).isDirectory()) throw new Error('Expected an existing directory.');
    return canonical;
}

function sameFile(a: fs.BigIntStats, b: fs.BigIntStats): boolean {
    return a.dev === b.dev && a.ino === b.ino && a.size === b.size
        && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
}

function escapeRegExp(value: string): string {
    return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

/**
 * Normalize and enforce vocabulary spelling (MIT port of anomalyco/hex HEXShared).
 * Single-pass replacement ordered longest-first avoids double-substituting inside an emitted term.
 */
export function applyVocabularySpelling(
    text: string,
    vocabulary: readonly (string | CustomVocabularyTerm)[] | undefined,
): string {
    if (!text || !vocabulary?.length) return text;
    interface Rule {
        needle: string;
        replacement: string;
        caseSensitive: boolean;
    }
    const rules: Rule[] = [];
    const seen = new Set<string>();
    for (const rawEntry of vocabulary.slice(0, 100)) {
        const entry: CustomVocabularyTerm = typeof rawEntry === 'string' ? { term: rawEntry } : rawEntry;
        const term = entry.term?.trim();
        if (!term) continue;
        const caseSensitive = entry.caseSensitive === true;
        const candidates = [term, ...(entry.phoneticHints ?? [])];
        for (const candidate of candidates) {
            const cleaned = candidate.trim();
            if (!cleaned) continue;
            const key = `${caseSensitive ? 's' : 'i'}:${cleaned.toLowerCase()}->${term}`;
            if (seen.has(key)) continue;
            seen.add(key);
            rules.push({ needle: cleaned, replacement: term, caseSensitive });
        }
    }
    if (!rules.length) return text;
    rules.sort((a, b) => b.needle.length - a.needle.length);

    interface MatchSpan { start: number; end: number; replacement: string }
    const spans: MatchSpan[] = [];
    for (const rule of rules) {
        const flags = rule.caseSensitive ? 'gu' : 'giu';
        const re = new RegExp(`(?<![\\p{L}\\p{N}_])${escapeRegExp(rule.needle)}(?![\\p{L}\\p{N}_])`, flags);
        let match: RegExpExecArray | null;
        while ((match = re.exec(text)) !== null) {
            const start = match.index;
            const end = start + match[0].length;
            if (!spans.some(span => start < span.end && end > span.start)) {
                spans.push({ start, end, replacement: rule.replacement });
            }
        }
    }
    if (!spans.length) return text;
    spans.sort((a, b) => a.start - b.start);
    let out = '';
    let cursor = 0;
    for (const span of spans) {
        out += text.slice(cursor, span.start) + span.replacement;
        cursor = span.end;
    }
    return out + text.slice(cursor);
}

const SPOKEN_PUNCTUATION_RULES: ReadonlyArray<[RegExp, string]> = [
    [/\bnew paragraph\b/giu, '\n\n'],
    [/\bnew line\b/giu, '\n'],
    [/\bquestion mark\b/giu, '?'],
    [/\bexclamation point\b/giu, '!'],
    [/\bexclamation mark\b/giu, '!'],
    [/\bsemicolon\b/giu, ';'],
    [/\bcolon\b/giu, ':'],
    [/\bcomma\b/giu, ','],
    [/\bperiod\b/giu, '.'],
];

/**
 * Pure TypeScript dictation formatting pipeline (MIT port of anomalyco/hex HEXShared).
 */
export function formatDictationTranscript(text: string, options: DictationFormatOptions = {}): string {
    let out = text.trim();
    if (!out) return '';

    if (options.removeFillerWords) {
        out = out.replace(/(?<![\p{L}\p{N}_])(um+|uh+|er+|ah+)(?![\p{L}\p{N}_])[,\s]*/giu, ' ');
    }
    if (options.spokenPunctuation) {
        for (const [pattern, symbol] of SPOKEN_PUNCTUATION_RULES) {
            out = out.replace(pattern, symbol);
        }
        out = out.replace(/[ \t]+([.,!?;:])/gu, '$1');
    }
    if (options.vocabulary?.length) {
        out = applyVocabularySpelling(out, options.vocabulary);
    }
    out = out
        .replace(/[ \t]{2,}/gu, ' ')
        .replace(/ *\n */gu, '\n')
        .trim();

    if (options.frenchSpacing) {
        // Normalize French narrow punctuation spacing before ; : ! ? » and after «
        out = out
            .replace(/\s*([;:!?»])/gu, '\u202F$1')
            .replace(/«\s*/gu, '«\u202F')
            .trim();
    }
    if (options.lowercaseOutput) {
        out = out.toLowerCase();
    }
    if (options.endWithPeriod && out && !/[.!?…]$/u.test(out)) {
        out += '.';
    }
    return out;
}

export function validateWavBuffer(buffer: Buffer): { sampleRate: number; sampleCount: number; durationMs: number } {
    if (buffer.length < 44 || buffer.length > SPEECH_MAX_AUDIO_BYTES) {
        throw new Error('WAV audio size must be between 44 bytes and 64 MiB.');
    }
    if (buffer.toString('ascii', 0, 4) !== 'RIFF' || buffer.toString('ascii', 8, 12) !== 'WAVE') {
        throw new Error('Audio must be a RIFF WAVE file.');
    }
    let audioFormat = 0;
    let channels = 0;
    let sampleRate = 0;
    let bitsPerSample = 0;
    let dataSize = 0;
    let blockAlign = 0;
    let byteRate = 0;
    let offset = 12;
    while (offset + 8 <= buffer.length) {
        const chunkId = buffer.toString('ascii', offset, offset + 4);
        const chunkSize = buffer.readUInt32LE(offset + 4);
        const payload = offset + 8;
        if (payload + chunkSize > buffer.length) {
            throw new Error('Truncated WAV chunk.');
        }
        if (chunkId === 'fmt ' && chunkSize >= 16) {
            audioFormat = buffer.readUInt16LE(payload);
            channels = buffer.readUInt16LE(payload + 2);
            sampleRate = buffer.readUInt32LE(payload + 4);
            bitsPerSample = buffer.readUInt16LE(payload + 14);
            byteRate = buffer.readUInt32LE(payload + 8);
            blockAlign = buffer.readUInt16LE(payload + 12);
        } else if (chunkId === 'data') {
            dataSize = chunkSize;
            break;
        }
        offset = payload + chunkSize + (chunkSize & 1);
    }
    if (audioFormat !== 1 || channels !== 1 || sampleRate !== SPEECH_SAMPLE_RATE_HZ || bitsPerSample !== 16
        || byteRate !== SPEECH_SAMPLE_RATE_HZ * 2 || blockAlign !== 2 || dataSize < 2 || dataSize % 2 !== 0) {
        throw new Error('WAV audio must be non-empty 16 kHz mono 16-bit PCM.');
    }
    const sampleCount = Math.floor(dataSize / 2);
    const durationMs = Math.max(1, Math.round((sampleCount * 1000) / sampleRate));
    return { sampleRate, sampleCount, durationMs };
}

export function assertLoopbackUrl(rawUrl: string): string {
    let parsed: URL;
    try { parsed = new URL(rawUrl); } catch { throw new Error('Hex endpoint must be a valid URL.'); }
    if (parsed.protocol !== 'http:') {
        throw new Error('Hex loopback endpoint must use http on loopback.');
    }
    const host = parsed.hostname.toLowerCase();
    if (host !== '127.0.0.1' && host !== '::1' && host !== '[::1]' && host !== 'localhost') {
        throw new Error(`Refusing non-loopback Hex endpoint host "${parsed.hostname}".`);
    }
    return `${parsed.protocol}//${parsed.host}`;
}

function validateSafeFilename(filename: string, allowedExtensions: readonly string[], label: string): void {
    if (!filename || filename.startsWith('.') || /[/\\]/u.test(filename)
        || hasControlCharacters(filename) || !allowedExtensions.includes(path.extname(filename).toLowerCase())) {
        throw new Error(`${label} filename manifest is invalid.`);
    }
}

function validateConfiguration(catalog: SpeechModelCatalog, lock: SpeechRuntimeLock): void {
    if (catalog.version !== 1 || !catalog.vad || !Array.isArray(catalog.models) || !catalog.models.length
        || lock.version !== 1 || lock.abiVersion !== 1
        || !/^[a-f0-9]{40}$/u.test(lock.revision)
        || !/^[a-f0-9]{40}$/u.test(lock.hex?.revision ?? '')
        || lock.hex?.localApiVersion !== '2'
        || lock.bounds.maxAudioBytes !== SPEECH_MAX_AUDIO_BYTES
        || lock.bounds.sampleRateHz !== SPEECH_SAMPLE_RATE_HZ
        || lock.bounds.maxThreads !== 8) {
        throw new Error('Speech catalog or runtime lock is invalid.');
    }
    validateSafeFilename(catalog.vad.localFilename, ['.gguf'], 'VAD');
    if (!Number.isSafeInteger(catalog.vad.bytes) || catalog.vad.bytes <= 0 || !/^[a-f0-9]{64}$/u.test(catalog.vad.sha256)) {
        throw new Error('Speech VAD manifest metadata is invalid.');
    }
    const ids = new Set<string>();
    for (const model of catalog.models) {
        if (!model.id || ids.has(model.id) || !Array.isArray(model.languages) || !model.languages.length) {
            throw new Error(`Invalid speech model entry: ${model.id || '(empty)'}`);
        }
        ids.add(model.id);
        if (model.engine === 'transcribe.cpp') {
            if (!model.localFilename || !model.sha256 || !Number.isSafeInteger(model.bytes) || (model.bytes ?? 0) <= 0) {
                throw new Error(`Speech artifact metadata incomplete for ${model.id}.`);
            }
            validateSafeFilename(model.localFilename, ['.gguf', '.bin'], `Model ${model.id}`);
            if (!/^[a-f0-9]{64}$/u.test(model.sha256)) {
                throw new Error(`Speech model SHA-256 invalid for ${model.id}.`);
            }
        }
    }
}

async function verifyRegularHashedFile(filePath: string, expectedBytes: number, expectedSha256: string,
    label: string, signal?: AbortSignal): Promise<{ path: string; identity: fs.BigIntStats }> {
    abortIfNeeded(signal);
    const link = await fs.promises.lstat(filePath, { bigint: true });
    if (!link.isFile() || link.isSymbolicLink()) {
        throw new Error(`${label} must be a regular local file without symlinks.`);
    }
    const handle = await fs.promises.open(filePath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    try {
        const before = await handle.stat({ bigint: true });
        if (!sameFile(link, before) || before.size !== BigInt(expectedBytes)) {
            throw new Error(`${label} size or file identity mismatch.`);
        }
        const hash = crypto.createHash('sha256');
        let hashed = 0;
        for await (const chunk of handle.createReadStream({
            start: 0,
            end: expectedBytes - 1,
            highWaterMark: 1024 * 1024,
            autoClose: false,
            signal,
        })) {
            abortIfNeeded(signal);
            hashed += chunk.length;
            hash.update(chunk);
        }
        if (hashed !== expectedBytes) throw new Error(`${label} was truncated during verification.`);
        if (hash.digest('hex') !== expectedSha256) throw new Error(`${label} SHA-256 mismatch.`);
        const after = await handle.stat({ bigint: true });
        if (!sameFile(before, after) || !sameFile(after, await fs.promises.lstat(filePath, { bigint: true }))) {
            throw new Error(`${label} changed during verification.`);
        }
        return { path: filePath, identity: after };
    } finally {
        await handle.close();
    }
}

export class HexLoopbackClient {
    readonly baseUrl: string;
    readonly token: string;
    readonly pid?: number;
    private readonly fetchImpl: typeof fetch;
    private readonly onClose?: () => Promise<void>;

    constructor(options: {
        url: string;
        token: string;
        pid?: number;
        fetchImpl?: typeof fetch;
        onClose?: () => Promise<void>;
    }) {
        if (!options.token || hasControlCharacters(options.token)) {
            throw new Error('Hex API token is missing or invalid.');
        }
        this.baseUrl = assertLoopbackUrl(options.url);
        this.token = options.token;
        this.pid = options.pid;
        this.fetchImpl = options.fetchImpl ?? fetch;
        this.onClose = options.onClose;
    }

    static async fromDiscoveryFile(discoveryPath: string, fetchImpl: typeof fetch = fetch): Promise<HexLoopbackClient> {
        const safe = safePath(discoveryPath, 'Hex discovery file');
        const link = await fs.promises.lstat(safe);
        if (!link.isFile() || link.isSymbolicLink()) {
            throw new Error('Hex discovery path must be a regular file.');
        }
        const raw = await fs.promises.readFile(safe, 'utf8');
        const parsed = JSON.parse(raw) as HexDiscoveryInfo;
        if (!Number.isInteger(parsed.port) || parsed.port < 1 || parsed.port > 65535
            || !parsed.token || parsed.apiVersion !== '2') {
            throw new Error('Hex discovery metadata is invalid or unsupported API version.');
        }
        return new HexLoopbackClient({
            url: `http://127.0.0.1:${parsed.port}`,
            token: parsed.token,
            pid: parsed.pid,
            fetchImpl,
        });
    }

    static async launchEmbedded(executable: string, options: {
        spawnProcess?: SpawnRuntime;
        fetchImpl?: typeof fetch;
        startupTimeoutMs?: number;
        killGraceMs?: number;
        signal?: AbortSignal;
    } = {}): Promise<HexLoopbackClient> {
        abortIfNeeded(options.signal);
        const safeExe = safePath(executable, 'Hex executable');
        const info = await fs.promises.lstat(safeExe);
        if (!info.isFile() || info.isSymbolicLink()) {
            throw new Error('Hex executable must be a regular file.');
        }
        await fs.promises.access(safeExe, fs.constants.X_OK);
        const canonicalExe = await fs.promises.realpath(safeExe);
        const spawner = options.spawnProcess ?? spawn;
        const startupTimeoutMs = Math.max(100, Math.min(options.startupTimeoutMs ?? 10000, 30000));
        const killGraceMs = Math.max(50, Math.min(options.killGraceMs ?? 1500, 5000));

        const child = spawner(canonicalExe, ['service', '--embedded'], {
            shell: false,
            stdio: ['ignore', 'pipe', 'pipe'],
            windowsHide: true,
        });

        const stopChild = async (): Promise<void> => {
            if (child.exitCode !== null || child.signalCode !== null) return;
            await new Promise<void>(resolve => {
                let done = false;
                const finish = (): void => {
                    if (done) return;
                    done = true;
                    clearTimeout(killTimer);
                    child.stdout?.destroy();
                    child.stderr?.destroy();
                    resolve();
                };
                child.once('close', finish);
                try { child.kill('SIGINT'); } catch { finish(); return; }
                const killTimer = setTimeout(() => {
                    try { child.kill('SIGKILL'); } catch { /* ignore */ }
                    setTimeout(() => {
                        try { child.unref(); } catch { /* ignore */ }
                        finish();
                    }, 50);
                }, killGraceMs);
            });
        };

        const ready = await new Promise<HexReadyHandshake>((resolve, reject) => {
            let lineBuffer = '';
            let settled = false;
            const decoder = new StringDecoder('utf8');
            const fail = (error: Error): void => {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                options.signal?.removeEventListener('abort', onAbort);
                void stopChild().finally(() => reject(error));
            };
            const onAbort = (): void => fail(new Error('Hex startup cancelled.'));
            const timer = setTimeout(() => fail(new Error('Hex embedded service timed out before ready handshake.')), startupTimeoutMs);
            options.signal?.addEventListener('abort', onAbort, { once: true });

            child.once('error', () => fail(new Error('Unable to launch embedded Hex service.')));
            child.once('close', code => fail(new Error(`Hex embedded service exited (${code ?? 'signal'}) before ready handshake.`)));
            child.stderr?.on('data', () => { /* bounded diagnostic stream intentionally discarded */ });
            child.stdout?.on('data', (chunk: Buffer) => {
                if (settled) return;
                lineBuffer += decoder.write(chunk);
                if (lineBuffer.length > 8192) {
                    fail(new Error('Hex startup handshake exceeded 8 KiB limit.'));
                    return;
                }
                const nl = lineBuffer.indexOf('\n');
                if (nl < 0) return;
                const firstLine = lineBuffer.slice(0, nl).trim();
                try {
                    const parsed = JSON.parse(firstLine) as HexReadyHandshake;
                    if (parsed.type !== 'ready' || parsed.apiVersion !== '2'
                        || !parsed.token || !parsed.url || typeof parsed.pid !== 'number') {
                        fail(new Error('Hex embedded service emitted an invalid ready handshake.'));
                        return;
                    }
                    assertLoopbackUrl(parsed.url);
                    settled = true;
                    clearTimeout(timer);
                    options.signal?.removeEventListener('abort', onAbort);
                    resolve(parsed);
                } catch {
                    fail(new Error('Hex embedded service emitted malformed JSON handshake.'));
                }
            });
        });

        return new HexLoopbackClient({
            url: ready.url,
            token: ready.token,
            pid: ready.pid,
            fetchImpl: options.fetchImpl,
            onClose: stopChild,
        });
    }

    async close(): Promise<void> {
        await this.onClose?.();
    }

    private headers(extra: Record<string, string> = {}): Record<string, string> {
        return {
            Authorization: `Bearer ${this.token}`,
            ...extra,
        };
    }

    async health(signal?: AbortSignal): Promise<HexHealthResponse> {
        const res = await this.fetchImpl(`${this.baseUrl}/health`, { headers: this.headers(), signal });
        if (!res.ok) throw new Error(`Hex /health failed with HTTP ${res.status}.`);
        return await res.json() as HexHealthResponse;
    }

    async capabilities(signal?: AbortSignal): Promise<HexCapabilitiesResponse> {
        const res = await this.fetchImpl(`${this.baseUrl}/capabilities`, { headers: this.headers(), signal });
        if (!res.ok) throw new Error(`Hex /capabilities failed with HTTP ${res.status}.`);
        return await res.json() as HexCapabilitiesResponse;
    }

    async models(signal?: AbortSignal): Promise<unknown[]> {
        const res = await this.fetchImpl(`${this.baseUrl}/models`, { headers: this.headers(), signal });
        if (!res.ok) throw new Error(`Hex /models failed with HTTP ${res.status}.`);
        const body = await res.json() as unknown;
        return Array.isArray(body) ? body : ((body as { models?: unknown[] }).models ?? []);
    }

    async prepareModel(modelId: string, onProgress?: (event: HexPrepareEvent) => void, signal?: AbortSignal): Promise<void> {
        const res = await this.fetchImpl(`${this.baseUrl}/models/${encodeURIComponent(modelId)}/prepare`, {
            method: 'POST',
            headers: this.headers({ Accept: 'text/event-stream' }),
            signal,
        });
        if (!res.ok) throw new Error(`Hex prepare model "${modelId}" failed with HTTP ${res.status}.`);
        if (!res.body) return;
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let currentEvent = 'message';
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let nl: number;
            while ((nl = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, nl).trimEnd();
                buffer = buffer.slice(nl + 1);
                if (!line) {
                    currentEvent = 'message';
                    continue;
                }
                if (line.startsWith('event:')) {
                    currentEvent = line.slice(6).trim();
                } else if (line.startsWith('data:')) {
                    const dataStr = line.slice(5).trim();
                    if (!dataStr) continue;
                    let parsed: HexPrepareEvent | undefined;
                    try {
                        parsed = JSON.parse(dataStr) as HexPrepareEvent;
                    } catch {
                        continue;
                    }
                    if (currentEvent === 'error' || parsed.status === 'error') {
                        throw new Error(parsed.message || `Hex model preparation failed for ${modelId}.`);
                    }
                    onProgress?.(parsed);
                }
            }
        }
    }

    async transcribeWav(wavBytes: Buffer, options: {
        model: string;
        language?: string;
        signal?: AbortSignal;
    }): Promise<{ transcript: string; durationMs: number; language?: string; segments?: SpeechSegment[] }> {
        validateWavBuffer(wavBytes);
        const query = new URLSearchParams({ model: options.model });
        if (options.language) query.set('language', options.language);
        const res = await this.fetchImpl(`${this.baseUrl}/transcriptions?${query.toString()}`, {
            method: 'POST',
            headers: this.headers({
                'Content-Type': 'audio/wav',
                Accept: 'application/json',
            }),
            body: new Uint8Array(wavBytes),
            signal: options.signal,
        });
        if (!res.ok) {
            throw new Error(`Hex transcription failed with HTTP ${res.status}.`);
        }
        const payload = await res.json() as {
            transcript?: string;
            durationMs?: number;
            language?: string;
            segments?: SpeechSegment[];
        };
        if (typeof payload.transcript !== 'string') {
            throw new Error('Hex transcription response omitted transcript string.');
        }
        return {
            transcript: payload.transcript,
            durationMs: typeof payload.durationMs === 'number' ? payload.durationMs : 0,
            language: payload.language,
            segments: Array.isArray(payload.segments) ? payload.segments : [],
        };
    }
}

export class HexSpeechAdapter {
    readonly catalog: SpeechModelCatalog;
    readonly runtimeLock: SpeechRuntimeLock;
    private readonly bundledRuntimePath: string;
    private readonly spawnProcess: SpawnRuntime;
    private readonly fetchImpl: typeof fetch;
    private readonly timeoutMs: number;
    private readonly killGraceMs: number;
    private active = false;

    constructor(dependencies: HexSpeechDependencies = {}) {
        const shared = dependencies.catalog && dependencies.runtimeLock ? undefined : sharedDirectory();
        this.catalog = dependencies.catalog ?? JSON.parse(fs.readFileSync(path.join(shared!, 'speech-model-catalog.json'), 'utf8'));
        this.runtimeLock = dependencies.runtimeLock ?? JSON.parse(fs.readFileSync(path.join(shared!, 'speech-runtime.json'), 'utf8'));
        validateConfiguration(this.catalog, this.runtimeLock);
        const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
        const executable = `quenderin-speech-cli${process.platform === 'win32' ? '.exe' : ''}`;
        const nativeOS = { win32: 'win', darwin: 'mac', linux: 'linux' }[process.platform as 'win32' | 'darwin' | 'linux'];
        const nativeArch = process.arch === 'arm' ? 'armv7l' : process.arch;
        this.bundledRuntimePath = dependencies.bundledRuntimePath ?? (resources
            ? path.join(resources, 'speech', executable)
            : path.join(shared ?? sharedDirectory(), '..', 'build', 'speech', `${nativeOS}-${nativeArch}`, executable));
        this.spawnProcess = dependencies.spawnProcess ?? spawn;
        this.fetchImpl = dependencies.fetchImpl ?? fetch;
        this.timeoutMs = Math.max(1, Math.min(dependencies.timeoutMs ?? SPEECH_TRANSCRIPTION_TIMEOUT_MS, SPEECH_TRANSCRIPTION_TIMEOUT_MS));
        this.killGraceMs = Math.max(1, Math.min(dependencies.killGraceMs ?? 2000, 2000));
    }

    vad(): SpeechVadManifest { return this.catalog.vad; }
    models(): readonly SpeechModelManifest[] { return this.catalog.models; }

    model(id: string): SpeechModelManifest {
        const found = this.catalog.models.find(candidate => candidate.id === id);
        if (!found) throw new Error(`Unknown speech model "${id}". Run \`quenderin voice models\`.`);
        return found;
    }

    async verify(modelId: string, directory: string, options: { includeVad?: boolean; signal?: AbortSignal } = {}): Promise<{
        model: string;
        bytes: number;
        vadVerified: boolean;
        modelPath: string;
        vadPath?: string;
        identity: fs.BigIntStats;
    }> {
        const model = this.model(modelId);
        if (model.engine !== 'transcribe.cpp' || !model.localFilename || !model.bytes || !model.sha256) {
            throw new Error(`Speech model "${modelId}" uses ${model.engine} and has no local GGUF artifact to verify.`);
        }
        const canonicalDir = await directoryPath(directory);
        const verifiedModel = await verifyRegularHashedFile(
            path.join(canonicalDir, model.localFilename),
            model.bytes,
            model.sha256,
            `Speech model ${model.localFilename}`,
            options.signal,
        );
        let vadPath: string | undefined;
        let vadVerified = false;
        let totalBytes = model.bytes;
        if (options.includeVad) {
            const vad = this.catalog.vad;
            const verifiedVad = await verifyRegularHashedFile(
                path.join(canonicalDir, vad.localFilename),
                vad.bytes,
                vad.sha256,
                `VAD model ${vad.localFilename}`,
                options.signal,
            );
            vadPath = verifiedVad.path;
            vadVerified = true;
            totalBytes += vad.bytes;
        }
        return {
            model: model.id,
            bytes: totalBytes,
            vadVerified,
            modelPath: verifiedModel.path,
            vadPath,
            identity: verifiedModel.identity,
        };
    }

    private async runtime(explicit?: string): Promise<string> {
        const selected = safePath(explicit ?? process.env.QUENDERIN_SPEECH_RUNTIME ?? this.bundledRuntimePath, 'Speech runtime');
        let info: fs.Stats;
        try { info = await fs.promises.lstat(selected); } catch {
            throw new Error('The pinned speech runtime is unavailable. Supply --runtime with a prepared quenderin-speech-cli build or configure Hex host.');
        }
        if (!info.isFile() || info.isSymbolicLink()) throw new Error('Speech runtime must be a regular executable file.');
        await fs.promises.access(selected, fs.constants.X_OK);
        return fs.promises.realpath(selected);
    }

    private runCli(executable: string, args: string[], timeoutMs: number, signal?: AbortSignal, lease?: NativeWorkloadLease): Promise<string> {
        abortIfNeeded(signal);
        return new Promise((resolve, reject) => {
            let child: ChildProcess;
            try { child = this.spawnProcess(executable, args, { shell: false, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true }); }
            catch { reject(new Error('Unable to launch the local speech runtime.')); return; }
            lease?.joinBeforeRelease(new Promise<void>(closed => { child.once('close', () => closed()); }));
            let stdout = '';
            let stdoutBytes = 0;
            let stderrBytes = 0;
            const decoder = new StringDecoder('utf8');
            let settled = false;
            let failure: Error | undefined;
            let killTimer: ReturnType<typeof setTimeout> | undefined;
            let abandonTimer: ReturnType<typeof setTimeout> | undefined;
            const finish = (error?: Error): void => {
                if (settled) return;
                settled = true;
                clearTimeout(timeout);
                clearTimeout(killTimer);
                clearTimeout(abandonTimer);
                signal?.removeEventListener('abort', cancelled);
                child.stdout?.destroy();
                child.stderr?.destroy();
                if (error) reject(error); else resolve(stdout + decoder.end());
            };
            const stop = (error: Error): void => {
                if (settled || failure) return;
                failure = error;
                child.kill('SIGINT');
                killTimer = setTimeout(() => {
                    child.kill('SIGKILL');
                    abandonTimer = setTimeout(() => { child.unref(); finish(error); }, this.killGraceMs);
                }, this.killGraceMs);
            };
            const cancelled = (): void => stop(new Error('Speech transcription cancelled.'));
            const timeout = setTimeout(() => stop(new Error('The local speech runtime exceeded its time limit.')), timeoutMs);
            signal?.addEventListener('abort', cancelled, { once: true });
            if (signal?.aborted) cancelled();
            child.on('error', () => finish(failure ?? new Error('Unable to launch the local speech runtime.')));
            child.on('close', (code, termSignal) => {
                if (failure) { finish(failure); return; }
                if (code !== 0 || termSignal) {
                    finish(new Error('The local speech runtime failed to transcribe audio.'));
                    return;
                }
                finish();
            });
            child.stdout?.on('data', (chunk: Buffer) => {
                if (settled || failure) return;
                stdoutBytes += chunk.length;
                if (stdoutBytes > STDOUT_LIMIT) {
                    stop(new Error('Speech runtime output exceeded bounded response limit.'));
                    return;
                }
                stdout += decoder.write(chunk);
            });
            child.stderr?.on('data', (chunk: Buffer) => {
                if (settled || failure) return;
                stderrBytes += chunk.length;
                if (stderrBytes > STDERR_LIMIT) {
                    stop(new Error('Speech runtime diagnostics exceeded bounded limit.'));
                }
            });
        });
    }

    private async readVerifiedWavPath(wavPath: string): Promise<string> {
        const requested = safePath(wavPath, 'WAV audio');
        if (path.extname(requested).toLowerCase() !== '.wav') {
            throw new Error('Speech input must be a .wav file.');
        }
        const link = await fs.promises.lstat(requested);
        if (!link.isFile() || link.isSymbolicLink()) {
            throw new Error('WAV audio must be a regular local file without symlinks.');
        }
        const canonical = await fs.promises.realpath(requested);
        const bytes = await fs.promises.readFile(canonical);
        validateWavBuffer(bytes);
        return canonical;
    }

    async transcribeWithCli(request: SpeechNativeRequest): Promise<SpeechTranscriptionResult> {
        return nativeWorkloads.exclusive('Speech transcription', request.signal,
            lease => this.transcribeWithCliLease({ ...request, signal: lease.signal }, lease));
    }

    private async transcribeWithCliLease(request: SpeechNativeRequest, lease: NativeWorkloadLease): Promise<SpeechTranscriptionResult> {
        if (this.active) throw new Error('A speech transcription is already running in this process.');
        this.active = true;
        let temporaryDirectory: string | undefined;
        try {
            abortIfNeeded(request.signal);
            const executable = await this.runtime(request.runtime);
            const verified = await this.verify(request.model, request.directory, {
                includeVad: Boolean(request.vad),
                signal: request.signal,
            });
            let wavPath: string;
            if (Buffer.isBuffer(request.wav)) {
                validateWavBuffer(request.wav);
                // The CLI takes a file path. Keep captured audio private and delete it on every exit.
                temporaryDirectory = await fs.promises.mkdtemp(path.join(os.tmpdir(), SPEECH_CAPTURE_TEMP_PREFIX));
                wavPath = await fs.promises.realpath(temporaryDirectory).then(directory => path.join(directory, SPEECH_CAPTURE_FILENAME));
                await fs.promises.writeFile(wavPath, request.wav, { mode: 0o600, flag: 'wx', signal: request.signal });
            } else {
                wavPath = await this.readVerifiedWavPath(request.wav);
            }

            let version: { abiVersion?: number; revision?: string };
            try {
                version = JSON.parse(await this.runCli(executable, ['--version'], 5000, request.signal, lease));
            } catch (error) {
                if (request.signal?.aborted) throw error;
                throw new Error('Speech runtime identity probe failed. A verified local quenderin-speech-cli build is required.');
            }
            if (version?.abiVersion !== this.runtimeLock.abiVersion || version?.revision !== this.runtimeLock.revision) {
                throw new Error('Speech runtime ABI or source revision does not match the pinned runtime.');
            }
            if (!sameFile(verified.identity, await fs.promises.lstat(verified.modelPath, { bigint: true }))) {
                throw new Error('Speech model changed after verification.');
            }

            const threads = Math.max(1, Math.min(request.threads ?? 4, this.runtimeLock.bounds.maxThreads));
            const args = ['--model', verified.modelPath, '--wav', wavPath, '--threads', String(threads)];
            if (verified.vadPath) args.push('--vad', verified.vadPath);
            if (request.language) {
                if (hasControlCharacters(request.language) || request.language.length > 32) {
                    throw new Error('Speech language code is invalid.');
                }
                args.push('--language', request.language);
            }
            if (request.prompt) {
                if (request.prompt.includes('\0') || Buffer.byteLength(request.prompt, 'utf8') > this.runtimeLock.bounds.maxPromptBytes) {
                    throw new Error('Speech prompt exceeds runtime limit.');
                }
                args.push('--prompt', request.prompt);
            }
            const vocabStrings = (request.format?.vocabulary ?? [])
                .map(entry => (typeof entry === 'string' ? entry : entry.term).trim())
                .filter(Boolean)
                .slice(0, this.runtimeLock.bounds.maxVocabularyTerms);
            if (vocabStrings.length) {
                args.push('--vocab', vocabStrings.join(','));
            }
            if (request.translate) args.push('--translate');
            if (request.timestamps) args.push('--timestamps');

            const stdout = await this.runCli(executable, args, this.timeoutMs, request.signal, lease);
            let parsed: {
                ok?: boolean;
                text?: string;
                language?: string;
                backend?: string;
                durationMs?: number;
                truncated?: boolean;
                segments?: SpeechSegment[];
            };
            try { parsed = JSON.parse(stdout); } catch {
                throw new Error('Speech runtime returned an invalid completion response.');
            }
            if (!parsed || parsed.ok !== true || typeof parsed.text !== 'string') {
                throw new Error('Speech runtime did not return a valid transcript.');
            }
            const formatted = request.format
                ? formatDictationTranscript(parsed.text, { ...request.format, language: request.language ?? parsed.language })
                : parsed.text.trim();
            return {
                text: formatted,
                rawText: parsed.text,
                language: parsed.language ?? request.language ?? '',
                backend: parsed.backend ?? 'transcribe.cpp',
                modelId: request.model,
                durationMs: typeof parsed.durationMs === 'number' ? parsed.durationMs : 0,
                truncated: Boolean(parsed.truncated),
                segments: Array.isArray(parsed.segments) ? parsed.segments : [],
            };
        } finally {
            try {
                if (temporaryDirectory) await fs.promises.rm(temporaryDirectory, { recursive: true, force: true });
            } finally {
                this.active = false;
            }
        }
    }

    async transcribeWithHexHost(request: HexHostTranscribeRequest): Promise<SpeechTranscriptionResult> {
        abortIfNeeded(request.signal);
        this.model(request.model);
        const wavBuffer = Buffer.isBuffer(request.wav)
            ? request.wav
            : await fs.promises.readFile(await this.readVerifiedWavPath(request.wav));
        validateWavBuffer(wavBuffer);

        let client: HexLoopbackClient;
        if (request.hexUrl && request.hexToken) {
            client = new HexLoopbackClient({ url: request.hexUrl, token: request.hexToken, fetchImpl: this.fetchImpl });
        } else if (request.hexDiscoveryPath) {
            client = await HexLoopbackClient.fromDiscoveryFile(request.hexDiscoveryPath, this.fetchImpl);
        } else if (request.hexExecutable) {
            client = await HexLoopbackClient.launchEmbedded(request.hexExecutable, {
                spawnProcess: this.spawnProcess,
                fetchImpl: this.fetchImpl,
                signal: request.signal,
            });
        } else {
            throw new Error('Provide Hex loopback URL/token, discovery file, or embedded executable.');
        }

        try {
            if (request.prepareModel) {
                await client.prepareModel(request.model, request.onPrepareProgress, request.signal);
            }
            const res = await client.transcribeWav(wavBuffer, {
                model: request.model,
                language: request.language,
                signal: request.signal,
            });
            const formatted = request.format
                ? formatDictationTranscript(res.transcript, { ...request.format, language: request.language ?? res.language })
                : res.transcript.trim();
            return {
                text: formatted,
                rawText: res.transcript,
                language: res.language ?? request.language ?? '',
                backend: 'hex-loopback-v2',
                modelId: request.model,
                durationMs: res.durationMs,
                truncated: false,
                segments: res.segments ?? [],
            };
        } finally {
            await client.close();
        }
    }

    async transcribe(request: UnifiedSpeechRequest): Promise<SpeechTranscriptionResult> {
        if ('hexUrl' in request || 'hexDiscoveryPath' in request || 'hexExecutable' in request) {
            return this.transcribeWithHexHost(request as HexHostTranscribeRequest);
        }
        return this.transcribeWithCli(request as SpeechNativeRequest);
    }
}
