import type { BrowserWindow, Dialog, IpcMain, IpcMainInvokeEvent } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { ImageGenerationService, type ImageModelPreset } from '../services/imageGeneration.js';
import { validateImagePng } from '../utils/imagePng.js';
import type { ImageGeneratedView, ImagePresetView } from './imageWorkflowTypes.js';

export const IMAGE_CHANNELS = {
    models: 'quenderin:image:models', folder: 'quenderin:image:folder', verify: 'quenderin:image:verify',
    generate: 'quenderin:image:generate', cancel: 'quenderin:image:cancel', progress: 'quenderin:image:progress',
} as const;
type Service = Pick<ImageGenerationService, 'models' | 'verify' | 'generate'>;
interface Dependencies {
    ipcMain: Pick<IpcMain, 'handle' | 'removeHandler'>;
    dialog: Pick<Dialog, 'showOpenDialog' | 'showSaveDialog'>;
    getWindow: () => BrowserWindow | null;
    trustedUrl: string;
    service?: Service;
}
interface Folder { handle: string; path: string; dev: bigint; ino: bigint; verifiedModel?: string }
interface Operation { controller: AbortController; done: Promise<void>; finish: () => void }
interface State { window: BrowserWindow; folder?: Folder; operation?: Operation; alive: boolean; detach: () => void }

function text(value: unknown, limit: number): string {
    if (typeof value !== 'string' || !value || value.length > limit || value.includes('\0')) throw new Error('Invalid image workflow request.');
    return value;
}
function record(value: unknown, keys: string[]): Record<string, unknown> {
    if (!value || typeof value !== 'object' || Array.isArray(value)
        || Object.keys(value).length !== keys.length || !keys.every(key => Object.hasOwn(value, key))) {
        throw new Error('Invalid image workflow request.');
    }
    return value as Record<string, unknown>;
}
function cancelled(signal: AbortSignal): void { if (signal.aborted) throw new Error('Image operation cancelled.'); }
function localPath(value: unknown): string {
    const file = text(value, 4096);
    if (!path.isAbsolute(file) || [...file].some(character => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)
        || Buffer.byteLength(file) > 4096) throw new Error('Choose a local path in the native dialog.');
    return file;
}
function displayText(value: unknown, maximum: number, fallback = ''): string {
    return typeof value === 'string' && value.length <= maximum ? value : fallback;
}
function modelView(model: ImageModelPreset): ImagePresetView {
    const metadata = model as ImageModelPreset & { publisher?: string };
    return {
        id: model.id, label: displayText(model.label, 120), publisher: displayText(metadata.publisher, 120),
        license: displayText(model.license, 240), licenseUrl: displayText(model.licenseUrl, 1024),
        requiresPublisherAccess: model.requiresPublisherAccess,
        promptRequirement: displayText(model.promptRequirement, 1024),
        width: model.defaults.width, height: model.defaults.height, steps: model.defaults.steps,
        totalBytes: model.components.reduce((sum, component) => sum + component.bytes, 0),
        components: model.components.map(component => {
            const source = component as typeof component & { repo?: string; license?: string; access?: string };
            return { filename: displayText(component.localFilename, 256), role: component.role, bytes: component.bytes,
                license: displayText(source.license, 240, model.license), access: displayText(source.access, 40, 'public'),
                repository: displayText(source.repo, 240) };
        }),
    };
}

/** Read only the just-created result, with fixed byte/pixel bounds and no-follow identity checks. */
async function preview(output: string, width: number, height: number): Promise<string> {
    const before = await fs.promises.lstat(output, { bigint: true });
    if (!before.isFile() || before.isSymbolicLink() || before.size < 33n || before.size > 8n * 1024n ** 2n) throw new Error('The saved image is not a bounded PNG.');
    const file = await fs.promises.open(output, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    const same = (other: fs.BigIntStats) => before.dev === other.dev && before.ino === other.ino && before.size === other.size
        && before.mtimeNs === other.mtimeNs && before.ctimeNs === other.ctimeNs;
    try {
        if (!same(await file.stat({ bigint: true }))) throw new Error('The saved image changed before preview.');
        const bytes = Buffer.alloc(Number(before.size));
        let offset = 0;
        while (offset < bytes.length) {
            const read = await file.read(bytes, offset, bytes.length - offset, offset);
            if (!read.bytesRead) throw new Error('The saved image is incomplete.');
            offset += read.bytesRead;
        }
        validateImagePng(bytes, width, height);
        if (!same(await file.stat({ bigint: true }))
            || !same(await fs.promises.lstat(output, { bigint: true }))) throw new Error('The saved PNG changed during preview.');
        return `data:image/png;base64,${bytes.toString('base64')}`;
    } finally { await file.close(); }
}

/** One trusted main window, one selected folder, and one operation. No renderer-supplied paths. */
export function registerImageWorkflow(dependencies: Dependencies): { dispose: () => Promise<void> } {
    const { ipcMain, dialog, getWindow } = dependencies;
    const trustedUrl = new URL(dependencies.trustedUrl).href;
    const trusted = new URL(trustedUrl);
    if (trusted.protocol !== 'http:' || trusted.hostname !== 'localhost' || trusted.pathname !== '/' || trusted.search || trusted.hash) throw new Error('Image IPC requires the exact local dashboard URL.');
    let service = dependencies.service;
    const engine = () => service ??= new ImageGenerationService();
    let state: State | undefined;
    let pendingOperation: Operation | undefined;
    let disposed = false;
    function abandon(current: State): void {
        current.alive = false;
        current.folder = undefined;
        current.operation?.controller.abort();
        current.detach();
        if (state === current) state = undefined;
    }
    function authenticated(event: IpcMainInvokeEvent): State {
        const window = getWindow();
        if (disposed || !window || window.isDestroyed() || event.sender !== window.webContents
            || event.senderFrame !== window.webContents.mainFrame || event.senderFrame?.url !== trustedUrl
            || event.sender.getURL() !== trustedUrl) throw new Error('Untrusted image workflow sender.');
        if (state?.window !== window) {
            if (state) abandon(state);
            const current: State = { window, alive: true, detach: () => {} };
            const close = () => abandon(current);
            const navigate = (_event: unknown, _url: string, _inPlace: boolean, mainFrame: boolean) => {
                if (mainFrame) { current.folder = undefined; current.operation?.controller.abort(); }
            };
            window.once('closed', close);
            window.webContents.on('did-start-navigation', navigate);
            current.detach = () => { window.removeListener('closed', close); window.webContents.removeListener('did-start-navigation', navigate); };
            state = current;
        }
        return state!;
    }
    async function operation<T>(current: State, work: (signal: AbortSignal) => Promise<T>): Promise<T> {
        if (pendingOperation) throw new Error('An image operation is already running. Cancel it or wait for it to finish.');
        let finish!: () => void;
        const active = { controller: new AbortController(), done: new Promise<void>(resolve => { finish = resolve; }), finish: () => finish() };
        current.operation = active;
        pendingOperation = active;
        try { return await work(active.controller.signal); }
        finally { if (current.operation === active) current.operation = undefined; if (pendingOperation === active) pendingOperation = undefined; active.finish(); }
    }
    function model(id: unknown): ImageModelPreset {
        const selected = engine().models().find(candidate => candidate.id === text(id, 80));
        if (!selected) throw new Error('Choose a catalog image preset.');
        return selected;
    }
    async function folder(current: State, handle: unknown): Promise<Folder> {
        const selected = current.folder;
        if (!selected || text(handle, 64) !== selected.handle) throw new Error('Choose the prepared model folder again.');
        const canonical = await fs.promises.realpath(selected.path);
        const info = await fs.promises.stat(canonical, { bigint: true });
        if (canonical !== selected.path || !info.isDirectory() || info.dev !== selected.dev || info.ino !== selected.ino) throw new Error('The selected folder changed. Choose it again.');
        return selected;
    }
    function handle(channel: string, callback: (current: State, value: unknown) => Promise<unknown> | unknown): void {
        ipcMain.handle(channel, async (event, value) => {
            try { return await callback(authenticated(event), value); }
            catch (error) { throw new Error((error instanceof Error ? error.message : 'Image operation failed.').slice(0, 2048)); }
        });
    }
    handle(IMAGE_CHANNELS.models, () => engine().models().slice(0, 3).map(modelView));
    handle(IMAGE_CHANNELS.folder, current => operation(current, async signal => {
        const selection = await dialog.showOpenDialog(current.window, { title: 'Choose prepared image model folder', properties: ['openDirectory', 'dontAddToRecent'] });
        cancelled(signal);
        if (selection.canceled || selection.filePaths.length !== 1) return null;
        const canonical = localPath(await fs.promises.realpath(localPath(selection.filePaths[0])));
        const info = await fs.promises.stat(canonical, { bigint: true });
        cancelled(signal);
        if (!info.isDirectory()) throw new Error('Choose an existing model folder.');
        current.folder = { handle: randomUUID(), path: canonical, dev: info.dev, ino: info.ino };
        return { handle: current.folder.handle, label: canonical };
    }));
    handle(IMAGE_CHANNELS.verify, (current, value) => operation(current, async signal => {
        const request = record(value, ['modelId', 'folderHandle']);
        const selected = model(request.modelId), files = await folder(current, request.folderHandle);
        cancelled(signal);
        const result = await engine().verify(selected.id, files.path, signal);
        cancelled(signal);
        files.verifiedModel = selected.id;
        return result;
    }));
    handle(IMAGE_CHANNELS.generate, (current, value) => operation(current, async signal => {
        const request = record(value, ['modelId', 'folderHandle', 'prompt', 'requestId']);
        const selected = model(request.modelId), files = await folder(current, request.folderHandle);
        const prompt = text(request.prompt, 8192), requestId = text(request.requestId, 64);
        if (!/^[a-f0-9-]{36}$/u.test(requestId) || !prompt.trim() || Buffer.byteLength(prompt) > 8192) throw new Error('Provide a scene caption of 1–8192 UTF-8 bytes.');
        if (files.verifiedModel !== selected.id) throw new Error('Verify the complete model folder for this preset first.');
        cancelled(signal);
        const save = await dialog.showSaveDialog(current.window, { title: 'Save a new generated PNG',
            defaultPath: `${selected.id}-${Date.now()}.png`, filters: [{ name: 'PNG image', extensions: ['png'] }], properties: ['dontAddToRecent'] });
        cancelled(signal);
        if (save.canceled || !save.filePath) return null;
        const requested = localPath(save.filePath);
        if (path.extname(requested) !== '.png') throw new Error('Choose a new .png filename.');
        const parent = await fs.promises.realpath(path.dirname(requested));
        const output = path.join(parent, path.basename(requested));
        try { await fs.promises.lstat(output); throw new Error('Output already exists. Choose a new filename; existing files are preserved.'); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
        cancelled(signal);
        await folder(current, request.folderHandle);
        let updates = 0;
        const result = await engine().generate({ model: selected.id, directory: files.path, prompt, output, signal,
            onProgress: progress => {
                if (!current.alive || signal.aborted) return;
                if (++updates > 200) { current.operation?.controller.abort(); return; }
                if (!Number.isInteger(progress.step) || !Number.isInteger(progress.steps) || progress.steps < 1 || progress.steps > 50 || progress.step < 0 || progress.step > progress.steps) return;
                const window = getWindow();
                if (window === current.window && !window.isDestroyed() && window.webContents.getURL() === trustedUrl) {
                    window.webContents.send(IMAGE_CHANNELS.progress, { requestId, step: progress.step, steps: progress.steps });
                }
            },
        });
        cancelled(signal);
        if (result.path !== output || result.width !== selected.defaults.width || result.height !== selected.defaults.height) throw new Error('The runtime returned a different image than requested.');
        const previewDataUrl = await preview(output, result.width, result.height);
        cancelled(signal);
        return { ...result, previewDataUrl } satisfies ImageGeneratedView;
    }));
    handle(IMAGE_CHANNELS.cancel, current => { current.operation?.controller.abort(); });
    return { dispose: async () => {
        disposed = true;
        const pending = pendingOperation?.done;
        pendingOperation?.controller.abort();
        if (state) abandon(state);
        for (const channel of [IMAGE_CHANNELS.models, IMAGE_CHANNELS.folder, IMAGE_CHANNELS.verify, IMAGE_CHANNELS.generate, IMAGE_CHANNELS.cancel]) ipcMain.removeHandler(channel);
        if (pending) {
            let timer: ReturnType<typeof setTimeout> | undefined;
            await Promise.race([pending, new Promise<void>(resolve => { timer = setTimeout(resolve, 5000); })]);
            if (timer) clearTimeout(timer);
        }
    } };
}
