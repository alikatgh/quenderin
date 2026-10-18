import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { VISION_MODELS, type VisionModel } from '../visionModels.js';
import { availableMemBytes } from '../utils/memory.js';
import { installArtifactSet, verifyArtifactSet } from './multipartInstaller.js';
import { nativeWorkloads } from './nativeWorkloads.js';

const abort = (signal?: AbortSignal) => { if (signal?.aborted) throw new Error('Vision operation cancelled.'); };
export class VisionService {
    private running = false;
    constructor(private readonly directory = path.join(os.homedir(), '.quenderin', 'vision'),
        private readonly memory = availableMemBytes, private readonly executable?: string,
        private readonly spawnProcess: typeof spawn = spawn) {}
    models(): readonly VisionModel[] { return VISION_MODELS; }
    private model(id: string): VisionModel {
        const model = VISION_MODELS.find(candidate => candidate.id === id);
        if (!model) throw new Error('Choose a pinned vision model.');
        return model;
    }
    private resources(model: VisionModel): void {
        const available = this.memory();
        if (!Number.isFinite(available) || available < model.minimumMemoryBytes) throw new Error(`${model.label} requires at least ${Math.ceil(model.minimumMemoryBytes / 1024 ** 3)} GiB of available memory, including the complete language model and projector.`);
    }
    private parts(model: VisionModel) { return model.artifacts.map(part => ({ ...part, downloadBytes: part.bytes })); }
    private folder(model: VisionModel) { return path.join(this.directory, model.id); }
    async status(id: string) {
        const model = this.model(id); const folder = this.folder(model);
        const states = await Promise.all(model.artifacts.map(part => fs.promises.lstat(path.join(folder, part.filename)).catch(() => null)));
        return { installed: states.every((stat, index) => stat?.isFile() && !stat.isSymbolicLink() && stat.size === model.artifacts[index].bytes), availableMemoryBytes: this.memory() };
    }
    async install(id: string, signal: AbortSignal, progress: (fraction: number) => void): Promise<void> {
        const model = this.model(id);
        if (os.totalmem() < model.minimumMemoryBytes) throw new Error(`${model.label} requires a device with at least ${Math.ceil(model.minimumMemoryBytes / 1024 ** 3)} GiB of memory.`);
        await this.exclusive(async () => { await this.probe(signal); await installArtifactSet(this.parts(model), this.folder(model), progress, fetch, signal); });
    }
    async verify(id: string, signal: AbortSignal): Promise<void> {
        const model = this.model(id);
        await this.exclusive(async () => { await this.probe(signal); await verifyArtifactSet(this.parts(model), this.folder(model), signal); });
    }
    private async exclusive<T>(work: () => Promise<T>): Promise<T> {
        if (this.running) throw new Error('A vision operation is already running.');
        this.running = true; try { return await work(); } finally { this.running = false; }
    }
    private runtime(): string {
        if (this.executable) return this.executable;
        const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
        const filename = process.platform === 'win32' ? 'quenderin-vision-cli.exe' : 'quenderin-vision-cli';
        const variant = `${process.platform === 'win32' ? 'win' : process.platform === 'darwin' ? 'mac' : 'linux'}-${process.arch === 'arm' ? 'armv7l' : process.arch}`;
        if (resources) return path.join(resources, 'vision', filename);
        const root = [new URL('../../', import.meta.url), new URL('../../../', import.meta.url)]
            .map(url => fileURLToPath(url)).find(candidate => fs.existsSync(path.join(candidate, 'package.json')));
        if (!root) throw new Error('The development vision runtime root is unavailable.');
        return path.join(root, 'build', 'vision', variant, filename);
    }
    private lock(): { revision: string; visionPatch: { sha256: string } } {
        const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
        const candidates = [...(resources ? [path.join(resources, 'shared/prism-runtime.json')] : []),
            fileURLToPath(new URL('../../shared/prism-runtime.json', import.meta.url)), fileURLToPath(new URL('../../../shared/prism-runtime.json', import.meta.url))];
        const file = candidates.find(candidate => fs.existsSync(candidate));
        if (!file) throw new Error('This build is missing its pinned vision runtime lock.');
        return JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    private async process(args: string[], input: unknown, signal: AbortSignal, timeoutMs: number): Promise<string> {
        abort(signal);
        return new Promise((resolve, reject) => {
            const child = this.spawnProcess(this.runtime(), args, { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
            const chunks: Buffer[] = []; let bytes = 0, errors = 0; let failure: Error | undefined;
            let killTimer: ReturnType<typeof setTimeout> | undefined;
            const stop = (reason: Error) => {
                if (failure) return; failure = reason; child.kill('SIGTERM'); killTimer = setTimeout(() => child.kill('SIGKILL'), 2000);
            };
            const cancel = () => stop(new Error('Vision operation cancelled.'));
            signal.addEventListener('abort', cancel, { once: true });
            if (signal.aborted) cancel();
            const timer = setTimeout(() => stop(new Error('Vision operation reached its time limit.')), timeoutMs);
            child.stdout.on('data', (chunk: Buffer) => { bytes += chunk.length; if (bytes > 512 * 1024) stop(new Error('Vision runtime exceeded its output bound.')); else chunks.push(Buffer.from(chunk)); });
            child.stderr.on('data', (chunk: Buffer) => { errors += chunk.length; if (errors > 128 * 1024) stop(new Error('Vision runtime exceeded its diagnostic bound.')); });
            child.stdin.on('error', () => { /* EPIPE is reported by close/error below. */ });
            child.once('error', () => { failure ??= new Error('The pinned vision runtime is not installed in this build.'); });
            child.once('close', code => {
                clearTimeout(timer); if (killTimer) clearTimeout(killTimer); signal.removeEventListener('abort', cancel);
                if (failure) return reject(failure);
                if (code !== 0) return reject(new Error('The vision runtime could not complete this request. Verify the files and available memory, then retry.'));
                try { resolve(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); } catch { reject(new Error('The vision runtime returned invalid UTF-8.')); }
            });
            child.stdin.end(input === undefined ? undefined : JSON.stringify(input));
        });
    }
    private async probe(signal: AbortSignal): Promise<void> {
        const current = JSON.parse(await this.process(['--abi'], undefined, signal, 5000)); const lock = this.lock();
        if (current.abi !== 1 || current.revision !== lock.revision || current.visionPatchSha256 !== lock.visionPatch?.sha256) {
            throw new Error('The compiled vision runtime does not match the pinned source patch.');
        }
    }
    async answer(id: string, image: string, prompt: string, signal: AbortSignal): Promise<{ text: string; tokens: number }> {
        if (!prompt.trim() || prompt.includes('\0') || Buffer.byteLength(prompt) > 8192) throw new Error('Ask an image question of 1–8,192 UTF-8 bytes.');
        const model = this.model(id);
        return nativeWorkloads.exclusive('Vision', signal, lease => this.exclusive(async () => {
            const signal = lease.signal;
            await this.probe(signal);
            // Native runner verifies both complete SHA-256 artifacts immediately before load.
            this.resources(model); abort(signal);
            const component = (role: string) => path.join(this.folder(model), model.artifacts.find(part => part.role === role)!.filename);
            const output = await this.process(['--stdin'], { model_id: id, model_path: component('model'), projector_path: component('projector'), image_path: image,
                prompt, max_tokens: 512, context_size: 4096, threads: Math.min(8, os.availableParallelism()) }, signal, 15 * 60_000);
            let text = '', tokens = -1, done = false;
            for (const line of output.split('\n').filter(Boolean)) {
                const event = JSON.parse(line);
                if (done || !event || typeof event !== 'object') throw new Error('Invalid vision response sequence.');
                if (event.type === 'error') throw new Error('The vision engine rejected this image or model. Check the complete artifacts and retry.');
                if (event.type === 'token' && typeof event.text === 'string' && Buffer.byteLength(text + event.text) <= 256 * 1024) text += event.text;
                else if (event.type === 'done' && Number.isInteger(event.tokens) && event.tokens >= 0 && event.tokens <= 512) { tokens = event.tokens; done = true; }
                else throw new Error('Invalid vision response event.');
            }
            if (!done || !text.trim() || /<\/?think|<\|(?:im_start|im_end|channel)|<｜/iu.test(text)) throw new Error('The vision engine did not return a valid final answer.');
            return { text, tokens };
        }));
    }
}
