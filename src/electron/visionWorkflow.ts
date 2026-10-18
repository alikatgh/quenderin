import type { BrowserWindow, Dialog, IpcMain, IpcMainInvokeEvent } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { VisionService } from '../services/vision.js';
import { GraniteArtifactProof, GraniteChatService } from '../services/graniteChat.js';

export const VISION_CHANNELS = { models: 'quenderin:vision:models', status: 'quenderin:vision:status', image: 'quenderin:vision:image',
    install: 'quenderin:vision:install', verify: 'quenderin:vision:verify', answer: 'quenderin:vision:answer',
    cancel: 'quenderin:vision:cancel', progress: 'quenderin:vision:progress',
    graniteModel: 'quenderin:granite:model', graniteAnswer: 'quenderin:granite:answer' } as const;
interface Dependencies {
    ipcMain: Pick<IpcMain, 'handle' | 'removeHandler'>;
    dialog: Pick<Dialog, 'showOpenDialog'>;
    getWindow: () => BrowserWindow | null;
    trustedUrl: string;
    service?: Pick<VisionService, 'models' | 'status' | 'install' | 'verify' | 'answer'>;
}
const text = (value: unknown, max: number) => {
    if (typeof value !== 'string' || !value || value.length > max || value.includes('\0')) throw new Error('Invalid vision request.');
    return value;
};
const same = (a: fs.BigIntStats, b: fs.BigIntStats) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
export function registerVisionWorkflow(dependencies: Dependencies): { dispose(): Promise<void> } {
    const { ipcMain, dialog, getWindow } = dependencies;
    const trustedUrl = new URL(dependencies.trustedUrl).href;
    const trusted = new URL(trustedUrl);
    if (trusted.protocol !== 'http:' || trusted.hostname !== 'localhost' || trusted.pathname !== '/' || trusted.search || trusted.hash) throw new Error('Vision IPC requires the exact dashboard URL.');
    let service = dependencies.service;
    const engine = () => service ??= new VisionService();
    let selected: { handle: string; path: string; identity: fs.BigIntStats } | undefined;
    let granite: { handle: string; proof: GraniteArtifactProof } | undefined;
    const graniteEngine = new GraniteChatService();
    let owner: BrowserWindow | undefined;
    let detach = () => {};
    let disposed = false;
    let pending: { controller: AbortController; done: Promise<void> } | undefined;
    const abandon = () => { selected = undefined; granite = undefined; pending?.controller.abort(); };
    function authenticated(event: IpcMainInvokeEvent): BrowserWindow {
        const window = getWindow();
        if (disposed || !window || window.isDestroyed() || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame
            || event.senderFrame?.url !== trustedUrl || event.sender.getURL() !== trustedUrl) throw new Error('Untrusted vision workflow sender.');
        if (owner !== window) {
            abandon(); detach(); owner = window;
            const close = () => { abandon(); detach(); owner = undefined; };
            const navigate = (_event: unknown, _url: string, _inPlace: boolean, mainFrame: boolean) => { if (mainFrame) abandon(); };
            window.once('closed', close); window.webContents.on('did-start-navigation', navigate);
            detach = () => { window.removeListener('closed', close); window.webContents.removeListener('did-start-navigation', navigate); };
        }
        return window;
    }
    async function run<T>(work: (signal: AbortSignal) => Promise<T>): Promise<T> {
        if (pending) throw new Error('A vision operation is already running.');
        let finish!: () => void;
        const current = { controller: new AbortController(), done: new Promise<void>(resolve => { finish = resolve; }) }; pending = current;
        try { return await work(current.controller.signal); }
        finally { if (pending === current) pending = undefined; finish(); }
    }
    const handle = (channel: string, work: (window: BrowserWindow, value: unknown) => Promise<unknown> | unknown) => {
        ipcMain.handle(channel, async (event, value) => {
            try { return await work(authenticated(event), value); }
            catch (error) { throw new Error((error instanceof Error ? error.message : 'Vision operation failed.').slice(0, 2048)); }
        });
    };
    const id = (value: unknown) => {
        const result = text(value, 80); if (!engine().models().some(model => model.id === result)) throw new Error('Choose a pinned vision model.'); return result;
    };
    handle(VISION_CHANNELS.models, () => engine().models());
    handle(VISION_CHANNELS.status, (_window, value) => engine().status(id(value)));
    handle(VISION_CHANNELS.image, window => run(async signal => {
        const result = await dialog.showOpenDialog(window, { title: 'Choose one image to ask about', properties: ['openFile', 'dontAddToRecent'], filters: [{ name: 'Still image', extensions: ['png', 'jpg', 'jpeg'] }] });
        if (signal.aborted) throw new Error('Vision selection cancelled.');
        if (result.canceled || result.filePaths.length !== 1) return null;
        const canonical = await fs.promises.realpath(result.filePaths[0]);
        const identity = await fs.promises.lstat(canonical, { bigint: true });
        if (!path.isAbsolute(canonical) || Buffer.byteLength(canonical) > 4096 || !identity.isFile() || identity.isSymbolicLink() || identity.size < 8n || identity.size > 8n * 1024n ** 2n) throw new Error('Choose one ordinary JPEG or PNG of at most 8 MiB.');
        selected = { handle: randomUUID(), path: canonical, identity };
        return { handle: selected.handle, label: path.basename(canonical) };
    }));
    handle(VISION_CHANNELS.install, (window, value) => run(async signal => {
        const modelId = id(value); let reported = -1;
        await engine().install(modelId, signal, fraction => {
            if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1 || signal.aborted || disposed || owner !== window) return;
            const progress = Math.floor(fraction * 1000) / 1000;
            if (progress <= reported) return; reported = progress;
            if (!window.isDestroyed() && window.webContents.getURL() === trustedUrl) window.webContents.send(VISION_CHANNELS.progress, { modelId, fraction: progress });
        });
    }));
    handle(VISION_CHANNELS.verify, (_window, value) => run(signal => engine().verify(id(value), signal)));
    handle(VISION_CHANNELS.answer, (_window, value) => run(async signal => {
        if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).sort().join(',') !== 'imageHandle,modelId,prompt') throw new Error('Invalid vision answer request.');
        const request = value as Record<string, unknown>, image = selected;
        if (!image || request.imageHandle !== image.handle || !same(image.identity, await fs.promises.lstat(image.path, { bigint: true }))) throw new Error('The selected image changed. Choose it again.');
        return engine().answer(id(request.modelId), image.path, text(request.prompt, 8192), signal);
    }));
    handle(VISION_CHANNELS.cancel, () => { pending?.controller.abort(); });
    handle(VISION_CHANNELS.graniteModel, window => run(async signal => {
        const result = await dialog.showOpenDialog(window, { title: 'Choose a converted Granite Switch 4.1 8B GGUF', properties: ['openFile', 'dontAddToRecent'], filters: [{ name: 'Converted GGUF', extensions: ['gguf'] }] });
        signal.throwIfAborted(); if (result.canceled || result.filePaths.length !== 1) return null;
        const file = await fs.promises.realpath(result.filePaths[0]);
        if (!path.isAbsolute(file) || Buffer.byteLength(file) > 4096) throw new Error('Choose a local converted Granite GGUF.');
        const proof = await GraniteArtifactProof.verify(file, signal); signal.throwIfAborted();
        granite = { handle: randomUUID(), proof }; return { handle: granite.handle, label: path.basename(file) };
    }));
    handle(VISION_CHANNELS.graniteAnswer, (_window, value) => run(async signal => {
        if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).sort().join(',') !== 'messages,modelHandle') throw new Error('Invalid Granite request.');
        const request = value as Record<string, unknown>, selectedModel = granite;
        if (!selectedModel || request.modelHandle !== selectedModel.handle) throw new Error('Choose and verify the converted Granite model first.');
        await selectedModel.proof.assertCurrent();
        return graniteEngine.answer(selectedModel.proof.file, request.messages, signal);
    }));
    return { dispose: async () => {
        disposed = true; const done = pending?.done; abandon(); detach();
        for (const channel of Object.values(VISION_CHANNELS)) if (channel !== VISION_CHANNELS.progress) ipcMain.removeHandler(channel);
        if (done) {
            let timer: ReturnType<typeof setTimeout> | undefined;
            await Promise.race([done, new Promise<void>(resolve => { timer = setTimeout(resolve, 5000); })]); if (timer) clearTimeout(timer);
        }
    } };
}
