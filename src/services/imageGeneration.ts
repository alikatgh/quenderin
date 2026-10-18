import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';
import { PNG } from 'pngjs';
import { availableMemBytes } from '../utils/memory.js';

export const IMAGE_MEMORY_REQUIRED_BYTES = 24 * 1024 ** 3;
export const IMAGE_GENERATION_TIMEOUT_MS = 15 * 60 * 1000;
const OUTPUT_RESERVE_BYTES = 64 * 1024 ** 2;
const STDOUT_LIMIT = 8 * 1024;
const STDERR_LIMIT = 64 * 1024;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

type ComponentRole = 'diffusion' | 'text_encoder' | 'vae' | 'tokenizer';
export interface ImageModelComponent {
    role: ComponentRole;
    localFilename: string;
    bytes: number;
    sha256: string;
}
export interface ImageModelPreset {
    id: string;
    label: string;
    modelKind: number;
    license: string;
    licenseUrl: string;
    requiresPublisherAccess: boolean;
    promptRequirement?: string;
    defaults: { width: number; height: number; steps: number };
    components: ImageModelComponent[];
}
export interface ImageModelCatalog {
    version: number;
    status: string;
    models: ImageModelPreset[];
}
export interface DiffusionRuntimeLock {
    version: number;
    abiVersion: number;
    revision: string;
    bounds: { maxDimension: number; maxSteps: number; maxThreads: number; maxImages: number };
}
export interface ImageProgress { step: number; steps: number }
export interface ImageGenerationRequest {
    model: string;
    directory: string;
    prompt: string;
    output: string;
    runtime?: string;
    signal?: AbortSignal;
    onProgress?: (progress: ImageProgress) => void;
}
export interface ImageGenerationResult { path: string; width: number; height: number }
type SpawnRuntime = (file: string, args: string[], options: SpawnOptions) => ChildProcess;
export interface ImageGenerationDependencies {
    catalog?: ImageModelCatalog;
    runtimeLock?: DiffusionRuntimeLock;
    bundledRuntimePath?: string;
    spawnProcess?: SpawnRuntime;
    availableMemoryBytes?: () => number;
    freeDiskBytes?: (directory: string) => Promise<bigint>;
    timeoutMs?: number;
    killGraceMs?: number;
}
interface VerifiedComponent {
    path: string;
    role: ComponentRole;
    identity: fs.BigIntStats;
}

function abortIfNeeded(signal?: AbortSignal): void {
    if (signal?.aborted) throw new Error('Image operation cancelled.');
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
    const directory = candidates.find(candidate => fs.existsSync(path.join(candidate, 'image-model-catalog.json')));
    if (!directory) throw new Error('The bundled image model catalog is missing.');
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

function validateConfiguration(catalog: ImageModelCatalog, lock: DiffusionRuntimeLock): void {
    if (catalog.version !== 1 || !Array.isArray(catalog.models) || !catalog.models.length
        || lock.version !== 1 || lock.abiVersion !== 1 || !/^[a-f0-9]{40}$/u.test(lock.revision)
        || lock.bounds.maxDimension !== 1024 || lock.bounds.maxSteps !== 50
        || lock.bounds.maxThreads !== 8 || lock.bounds.maxImages !== 1) {
        throw new Error('Image catalog or runtime lock is invalid.');
    }
    const ids = new Set<string>();
    const kinds: Record<string, number> = { 'flux3-image-klein': 1, 'moss-image-base': 2, 'moss-image-sft': 3 };
    for (const model of catalog.models) {
        if (!kinds[model.id] || kinds[model.id] !== model.modelKind || ids.has(model.id)) {
            throw new Error('Image model identity is invalid.');
        }
        ids.add(model.id);
        const { width, height, steps } = model.defaults;
        if (![width, height].every(n => Number.isInteger(n) && n >= 64 && n <= 1024 && n % 16 === 0)
            || !Number.isInteger(steps) || steps < 1 || steps > 50) throw new Error('Image preset exceeds runtime bounds.');
        const roles = new Set<string>();
        const filenames = new Set<string>();
        const extensions: Record<ComponentRole, string> = { diffusion: '.safetensors', text_encoder: '.gguf', vae: '.safetensors', tokenizer: '.json' };
        for (const component of model.components) {
            if (!['diffusion', 'text_encoder', 'vae', 'tokenizer'].includes(component.role)
                || roles.has(component.role) || filenames.has(component.localFilename)
                || !component.localFilename || component.localFilename.startsWith('.')
                || /[/\\]/u.test(component.localFilename) || hasControlCharacters(component.localFilename)
                || path.extname(component.localFilename) !== extensions[component.role]
                || !Number.isSafeInteger(component.bytes) || component.bytes <= 0
                || !/^[a-f0-9]{64}$/u.test(component.sha256)) throw new Error('Image component manifest is invalid.');
            roles.add(component.role);
            filenames.add(component.localFilename);
        }
        const required = model.modelKind === 1 ? ['diffusion', 'text_encoder', 'vae'] : ['diffusion', 'text_encoder', 'vae', 'tokenizer'];
        if (roles.size !== required.length || !required.every(role => roles.has(role))) {
            throw new Error('The complete image component set is required.');
        }
    }
}

export class ImageGenerationService {
    readonly catalog: ImageModelCatalog;
    readonly runtimeLock: DiffusionRuntimeLock;
    private readonly bundledRuntimePath: string;
    private readonly spawnProcess: SpawnRuntime;
    private readonly availableMemoryBytes: () => number;
    private readonly freeDiskBytes: (directory: string) => Promise<bigint>;
    private readonly timeoutMs: number;
    private readonly killGraceMs: number;
    private active = false;

    constructor(dependencies: ImageGenerationDependencies = {}) {
        const shared = dependencies.catalog && dependencies.runtimeLock ? undefined : sharedDirectory();
        this.catalog = dependencies.catalog ?? JSON.parse(fs.readFileSync(path.join(shared!, 'image-model-catalog.json'), 'utf8'));
        this.runtimeLock = dependencies.runtimeLock ?? JSON.parse(fs.readFileSync(path.join(shared!, 'diffusion-runtime.json'), 'utf8'));
        validateConfiguration(this.catalog, this.runtimeLock);
        const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
        const executable = `quenderin-diffusion-cli${process.platform === 'win32' ? '.exe' : ''}`;
        this.bundledRuntimePath = dependencies.bundledRuntimePath ?? (resources
            ? path.join(resources, 'diffusion', executable)
            : path.join(shared ?? sharedDirectory(), '..', 'native', 'diffusion', 'bin', executable));
        this.spawnProcess = dependencies.spawnProcess ?? spawn;
        this.availableMemoryBytes = dependencies.availableMemoryBytes ?? availableMemBytes;
        this.freeDiskBytes = dependencies.freeDiskBytes ?? (async directory => {
            const stats = await fs.promises.statfs(directory, { bigint: true });
            return stats.bavail * stats.bsize;
        });
        this.timeoutMs = Math.max(1, Math.min(dependencies.timeoutMs ?? IMAGE_GENERATION_TIMEOUT_MS, IMAGE_GENERATION_TIMEOUT_MS));
        this.killGraceMs = Math.max(1, Math.min(dependencies.killGraceMs ?? 2000, 2000));
    }

    models(): readonly ImageModelPreset[] { return this.catalog.models; }

    private model(id: string): ImageModelPreset {
        const model = this.catalog.models.find(candidate => candidate.id === id);
        if (!model) throw new Error(`Unknown image model "${id}". Run \`quenderin image models\`.`);
        return model;
    }

    private async components(id: string, directory: string, signal?: AbortSignal): Promise<VerifiedComponent[]> {
        const model = this.model(id);
        const canonical = await directoryPath(directory);
        const verified: VerifiedComponent[] = [];
        for (const component of model.components) {
            abortIfNeeded(signal);
            const filename = path.join(canonical, component.localFilename);
            const link = await fs.promises.lstat(filename, { bigint: true });
            if (!link.isFile() || link.isSymbolicLink()) throw new Error(`Component must be a regular file: ${component.localFilename}`);
            const handle = await fs.promises.open(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
            try {
                const before = await handle.stat({ bigint: true });
                if (!sameFile(link, before) || before.size !== BigInt(component.bytes)) {
                    throw new Error(`Component size or identity mismatch: ${component.localFilename}`);
                }
                const hash = crypto.createHash('sha256');
                let hashedBytes = 0;
                for await (const chunk of handle.createReadStream({ start: 0, end: component.bytes - 1,
                    highWaterMark: 1024 * 1024, autoClose: false, signal })) {
                    abortIfNeeded(signal);
                    hashedBytes += chunk.length;
                    hash.update(chunk);
                }
                if (hashedBytes !== component.bytes) throw new Error(`Component was truncated: ${component.localFilename}`);
                if (hash.digest('hex') !== component.sha256) throw new Error(`Component SHA-256 mismatch: ${component.localFilename}`);
                const after = await handle.stat({ bigint: true });
                if (!sameFile(before, after) || !sameFile(after, await fs.promises.lstat(filename, { bigint: true }))) {
                    throw new Error(`Component changed during verification: ${component.localFilename}`);
                }
                verified.push({ path: filename, role: component.role, identity: after });
            } finally { await handle.close(); }
        }
        return verified;
    }

    async verify(model: string, directory: string, signal?: AbortSignal): Promise<{ model: string; components: number; bytes: number }> {
        const components = await this.components(model, directory, signal);
        return { model, components: components.length, bytes: components.reduce((sum, item) => sum + Number(item.identity.size), 0) };
    }

    private async resources(directory: string, model: ImageModelPreset): Promise<void> {
        const memory = this.availableMemoryBytes();
        if (!Number.isFinite(memory) || memory < IMAGE_MEMORY_REQUIRED_BYTES) {
            throw new Error('Image generation requires at least 24 GiB of available memory for the complete pipeline. Close other model processes first.');
        }
        const required = BigInt(OUTPUT_RESERVE_BYTES + model.defaults.width * model.defaults.height * 4 + model.defaults.height);
        if (await this.freeDiskBytes(directory) < required) throw new Error('Insufficient free disk space for a new image and its output reserve.');
    }

    private async runtime(explicit?: string): Promise<string> {
        const selected = safePath(explicit ?? process.env.QUENDERIN_IMAGE_RUNTIME ?? this.bundledRuntimePath, 'Runtime');
        let info: fs.Stats;
        try { info = await fs.promises.lstat(selected); } catch {
            throw new Error('The pinned image runtime is unavailable. Supply --runtime with a prepared quenderin-diffusion-cli build.');
        }
        if (!info.isFile() || info.isSymbolicLink()) throw new Error('Image runtime must be a regular executable file.');
        await fs.promises.access(selected, fs.constants.X_OK);
        return fs.promises.realpath(selected);
    }

    private run(executable: string, args: string[], timeoutMs: number, signal?: AbortSignal,
        onProgress?: (progress: ImageProgress) => void): Promise<string> {
        abortIfNeeded(signal);
        return new Promise((resolve, reject) => {
            let child: ChildProcess;
            try { child = this.spawnProcess(executable, args, { shell: false, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true }); }
            catch { reject(new Error('Unable to launch the local image runtime.')); return; }
            let stdout = '';
            let stdoutBytes = 0;
            const decoder = new StringDecoder('utf8');
            let stderrBytes = 0;
            let progressBuffer = '';
            let progressCount = 0;
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
            const cancelled = (): void => stop(new Error('Image operation cancelled.'));
            const timeout = setTimeout(() => stop(new Error('The local image runtime exceeded its time limit.')), timeoutMs);
            signal?.addEventListener('abort', cancelled, { once: true });
            if (signal?.aborted) cancelled();
            child.on('error', () => finish(failure ?? new Error('Unable to launch the local image runtime.')));
            child.on('close', (code, terminationSignal) => {
                if (failure) { finish(failure); return; }
                if (code !== 0 || terminationSignal) { finish(new Error('The local image runtime failed. No successful image was reported.')); return; }
                finish();
            });
            child.stdout?.on('data', (chunk: Buffer) => {
                if (settled || failure) return;
                stdoutBytes += chunk.length;
                if (stdoutBytes > STDOUT_LIMIT) {
                    stop(new Error('Image runtime output exceeded the bounded response limit.')); return;
                }
                stdout += decoder.write(chunk);
            });
            child.stderr?.on('data', (chunk: Buffer) => {
                if (settled || failure) return;
                stderrBytes += chunk.length;
                if (stderrBytes > STDERR_LIMIT) { stop(new Error('Image runtime progress exceeded the bounded response limit.')); return; }
                progressBuffer += chunk.toString('utf8');
                if (progressBuffer.length > 4096) { stop(new Error('Image runtime progress line exceeded its limit.')); return; }
                let newline: number;
                while ((newline = progressBuffer.indexOf('\n')) >= 0) {
                    const line = progressBuffer.slice(0, newline);
                    progressBuffer = progressBuffer.slice(newline + 1);
                    if (++progressCount > 200) { stop(new Error('Image runtime emitted too many progress updates.')); return; }
                    try {
                        const value = JSON.parse(line) as ImageProgress;
                        if (Number.isInteger(value.step) && Number.isInteger(value.steps)
                            && value.step >= 0 && value.step <= value.steps && value.steps > 0 && value.steps <= 50) {
                            onProgress?.({ step: value.step, steps: value.steps });
                        }
                    } catch { /* Native diagnostic lines are bounded and never forwarded. */ }
                }
            });
        });
    }

    async generate(request: ImageGenerationRequest): Promise<ImageGenerationResult> {
        if (this.active) throw new Error('An image generation is already running in this process.');
        this.active = true;
        try {
            abortIfNeeded(request.signal);
            const model = this.model(request.model);
            if (!request.prompt.trim() || request.prompt.includes('\0') || Buffer.byteLength(request.prompt, 'utf8') > 8192) {
                throw new Error('Provide a scene caption between 1 and 8192 UTF-8 bytes.');
            }
            const requestedOutput = safePath(request.output, 'Output');
            if (path.extname(requestedOutput) !== '.png') throw new Error('Output must be a new .png file.');
            const parent = await directoryPath(path.dirname(requestedOutput));
            const output = path.join(parent, path.basename(requestedOutput));
            await this.assertNewOutput(output);
            await this.resources(parent, model);
            const components = await this.components(model.id, request.directory, request.signal);
            const executable = await this.runtime(request.runtime);
            let version: { abiVersion?: number; revision?: string };
            try { version = JSON.parse(await this.run(executable, ['--version'], 5000, request.signal)); }
            catch (error) {
                if (request.signal?.aborted) throw error;
                throw new Error('Image runtime identity probe failed. A verified local CLI build is required.');
            }
            if (version?.abiVersion !== this.runtimeLock.abiVersion || version?.revision !== this.runtimeLock.revision) {
                throw new Error('Image runtime ABI or source revision does not match the pinned runtime.');
            }
            await this.resources(parent, model);
            await this.assertNewOutput(output);
            for (const component of components) {
                if (!sameFile(component.identity, await fs.promises.lstat(component.path, { bigint: true }))) {
                    throw new Error('An image model component changed after verification.');
                }
            }
            const flags: Record<ComponentRole, string> = { diffusion: '--diffusion', text_encoder: '--text-encoder', vae: '--vae', tokenizer: '--tokenizer' };
            const args = ['--model', model.id];
            for (const component of components) args.push(flags[component.role], component.path);
            args.push('--prompt', request.prompt, '--output', output, '--width', String(model.defaults.width),
                '--height', String(model.defaults.height), '--steps', String(model.defaults.steps), '--threads', '4', '--seed', '0');
            const response = await this.run(executable, args, this.timeoutMs, request.signal, request.onProgress);
            let result: { ok?: boolean; path?: string; width?: number; height?: number };
            try { result = JSON.parse(response); } catch { throw new Error('Image runtime returned an invalid completion response.'); }
            if (!result || result.ok !== true || result.path !== output
                || result.width !== model.defaults.width || result.height !== model.defaults.height) {
                throw new Error('Image runtime did not confirm the requested image.');
            }
            await this.verifyOutput(output, model.defaults.width, model.defaults.height);
            return { path: output, width: model.defaults.width, height: model.defaults.height };
        } finally { this.active = false; }
    }

    private async assertNewOutput(output: string): Promise<void> {
        try { await fs.promises.lstat(output); } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
            throw error;
        }
        throw new Error('Output already exists. Choose a new PNG filename; existing files are preserved.');
    }

    private async verifyOutput(output: string, width: number, height: number): Promise<void> {
        const info = await fs.promises.lstat(output);
        if (!info.isFile() || info.isSymbolicLink() || info.size < 33 || info.size > 8 * 1024 ** 2) {
            throw new Error('Runtime output is not a bounded regular PNG file.');
        }
        const file = await fs.promises.open(output, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
        try {
            const opened = await file.stat();
            if (opened.dev !== info.dev || opened.ino !== info.ino || opened.size !== info.size) {
                throw new Error('Runtime output changed during validation.');
            }
            const bytes = Buffer.alloc(info.size);
            let offset = 0;
            while (offset < bytes.length) {
                const { bytesRead } = await file.read(bytes, offset, bytes.length - offset, offset);
                if (!bytesRead) throw new Error('Runtime output PNG is incomplete.');
                offset += bytesRead;
            }
            if (!bytes.subarray(0, 8).equals(PNG_SIGNATURE)
                || bytes.readUInt32BE(8) !== 13 || bytes.toString('ascii', 12, 16) !== 'IHDR'
                || bytes.readUInt32BE(16) !== width || bytes.readUInt32BE(20) !== height) {
                throw new Error('Runtime output PNG dimensions or signature are invalid.');
            }
            try {
                const decoded = PNG.sync.read(bytes, { checkCRC: true });
                if (decoded.width !== width || decoded.height !== height) throw new Error('Wrong dimensions.');
            } catch { throw new Error('Runtime output PNG pixels or checksums are invalid.'); }
        } finally { await file.close(); }
    }
}
