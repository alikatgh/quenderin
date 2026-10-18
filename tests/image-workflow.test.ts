import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';
import { PNG } from 'pngjs';
import type { IpcMainInvokeEvent } from 'electron';
import { IMAGE_CHANNELS, registerImageWorkflow } from '../src/electron/imageWorkflow.js';
import type { ImageGenerationRequest, ImageModelPreset } from '../src/services/imageGeneration.js';

const trustedUrl = 'http://localhost:38421/';
const requestId = '12345678-1234-1234-1234-123456789abc';
const preset: ImageModelPreset = { id: 'fixture', label: 'Fixture image', modelKind: 1, license: 'Apache-2.0', licenseUrl: 'https://example.invalid/license',
    requiresPublisherAccess: false, defaults: { width: 2, height: 2, steps: 2 },
    components: [{ role: 'diffusion', localFilename: 'fixture.bin', bytes: 4, sha256: '0'.repeat(64) }] };
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(yes => { resolve = yes; }); return { promise, resolve }; };

describe('desktop image IPC boundary', () => {
    let scratch: string, prepared: string, output: string;
    let handlers: Map<string, (event: IpcMainInvokeEvent, value?: unknown) => Promise<unknown>>;
    let window: EventEmitter & { webContents: EventEmitter & { mainFrame: { url: string }; getURL: () => string; send: ReturnType<typeof vi.fn> }; isDestroyed: () => boolean };
    let event: IpcMainInvokeEvent;
    let service: { models: ReturnType<typeof vi.fn>; verify: ReturnType<typeof vi.fn>; generate: ReturnType<typeof vi.fn> };
    let dialog: { showOpenDialog: ReturnType<typeof vi.fn>; showSaveDialog: ReturnType<typeof vi.fn> };
    let bridge: ReturnType<typeof registerImageWorkflow>;
    const invoke = (channel: keyof typeof IMAGE_CHANNELS, value?: unknown, sender = event) => handlers.get(IMAGE_CHANNELS[channel])!(sender, value);
    async function selected() { return await invoke('folder') as { handle: string; label: string }; }
    async function verified() { const selection = await selected(); await invoke('verify', { modelId: preset.id, folderHandle: selection.handle }); return selection; }
    const generateRequest = (handle: string, extra = {}) => ({ modelId: preset.id, folderHandle: handle, prompt: 'A quiet garden', requestId, ...extra });

    beforeEach(async () => {
        scratch = await fs.promises.realpath(await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-image-ipc-')));
        prepared = path.join(scratch, 'prepared'); output = path.join(scratch, 'new.png');
        await fs.promises.mkdir(prepared);
        handlers = new Map();
        const webContents = Object.assign(new EventEmitter(), { mainFrame: { url: trustedUrl }, getURL: () => trustedUrl, send: vi.fn() });
        window = Object.assign(new EventEmitter(), { webContents, isDestroyed: () => false });
        event = { sender: webContents, senderFrame: webContents.mainFrame } as unknown as IpcMainInvokeEvent;
        service = { models: vi.fn(() => [preset]), verify: vi.fn(async () => ({ model: preset.id, components: 1, bytes: 4 })),
            generate: vi.fn(async (request: ImageGenerationRequest) => {
                const png = new PNG({ width: 2, height: 2 }); png.data.fill(128);
                await fs.promises.writeFile(request.output, PNG.sync.write(png), { flag: 'wx' });
                return { path: request.output, width: 2, height: 2 };
            }) };
        dialog = { showOpenDialog: vi.fn(async () => ({ canceled: false, filePaths: [prepared] })),
            showSaveDialog: vi.fn(async () => ({ canceled: false, filePath: output })) };
        bridge = registerImageWorkflow({ ipcMain: { handle: (channel, callback) => { handlers.set(channel, callback); }, removeHandler: channel => { handlers.delete(channel); } } as never,
            dialog: dialog as never, getWindow: () => window as never, trustedUrl, service });
    });
    afterEach(async () => { vi.restoreAllMocks(); await bridge.dispose(); await fs.promises.rm(scratch, { recursive: true, force: true }); });

    it('checks exact trusted window, sender, main frame and URL before exposing catalog or dialogs', async () => {
        await expect(invoke('models')).resolves.toMatchObject([{ id: 'fixture', totalBytes: 4 }]);
        for (const hostile of [
            { sender: { ...window.webContents }, senderFrame: window.webContents.mainFrame },
            { sender: window.webContents, senderFrame: { url: trustedUrl } },
            { sender: window.webContents, senderFrame: null },
        ]) await expect(invoke('folder', undefined, hostile as unknown as IpcMainInvokeEvent)).rejects.toThrow('Untrusted');
        for (const url of ['http://localhost:38422/', 'http://localhost:38421/?other=1', 'https://evil.invalid/', 'http://localhost:38421/path']) {
            window.webContents.mainFrame.url = url;
            await expect(invoke('models')).rejects.toThrow('Untrusted');
        }
        expect(dialog.showOpenDialog).not.toHaveBeenCalled();
    });
    it('uses only a native-dialog folder and a single opaque, replaceable handle', async () => {
        const first = await selected();
        expect(first.label).toBe(await fs.promises.realpath(prepared));
        expect(first.handle).not.toContain(prepared);
        const second = await selected();
        expect(second.handle).not.toBe(first.handle);
        await expect(invoke('verify', { modelId: preset.id, folderHandle: first.handle })).rejects.toThrow('Choose the prepared');
        await expect(invoke('verify', { modelId: preset.id, folderHandle: prepared })).rejects.toThrow();
        await invoke('verify', { modelId: preset.id, folderHandle: second.handle });
        expect(service.verify.mock.calls[0][1]).toBe(await fs.promises.realpath(prepared));
    });
    it('rejects a changed folder identity and does not reuse the old verification', async () => {
        const selection = await verified();
        await fs.promises.rename(prepared, path.join(scratch, 'original'));
        await fs.promises.mkdir(prepared);
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow('folder changed');
        expect(dialog.showSaveDialog).not.toHaveBeenCalled();
    });
    it('requires successful verification and rejects arbitrary path/runtime fields or oversized captions', async () => {
        const selection = await selected();
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow('Verify');
        await invoke('verify', { modelId: preset.id, folderHandle: selection.handle });
        for (const extra of [{ runtime: '/bin/sh' }, { output: output }, { prompt: 'é'.repeat(4097) }, { prompt: '\0bad' }, { requestId: 'x'.repeat(200) }]) {
            await expect(invoke('generate', generateRequest(selection.handle, extra))).rejects.toThrow();
        }
        expect(dialog.showSaveDialog).not.toHaveBeenCalled();
    });
    it('never overwrites an existing output and keeps prompt input out of command authority', async () => {
        const selection = await verified(); await fs.promises.writeFile(output, 'original');
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow('already exists');
        expect(await fs.promises.readFile(output, 'utf8')).toBe('original'); expect(service.generate).not.toHaveBeenCalled();
    });
    it('returns only the newly validated PNG and saves using the main-process dialog path', async () => {
        const selection = await verified();
        const result = await invoke('generate', generateRequest(selection.handle, { prompt: 'A garden; $(no command)' })) as { previewDataUrl: string; path: string };
        expect(result.path).toBe(output); expect(result.previewDataUrl).toMatch(/^data:image\/png;base64,/u);
        const saved = await fs.promises.readFile(output); expect(result.previewDataUrl.split(',')[1]).toBe(saved.toString('base64'));
        expect(service.generate.mock.calls[0][0]).toMatchObject({ output, directory: await fs.promises.realpath(prepared), prompt: 'A garden; $(no command)' });
        expect(service.generate.mock.calls[0][0]).not.toHaveProperty('runtime');
    });
    it.each(['invalid', 'oversized', 'different-path', 'symlink', 'duplicate-ihdr', 'interlaced'])('rejects %s output without preview filesystem authority', async kind => {
        const selection = await verified();
        const decode = vi.spyOn(PNG.sync, 'read');
        service.generate.mockImplementation(async (request: ImageGenerationRequest) => {
            if (kind === 'oversized') { const fd = await fs.promises.open(output, 'wx'); await fd.truncate(8 * 1024 ** 2 + 1); await fd.close(); }
            else if (kind === 'symlink') { const target = path.join(scratch, 'target'); await fs.promises.writeFile(target, 'private'); await fs.promises.symlink(target, output); }
            else if (kind === 'duplicate-ihdr') {
                const small = PNG.sync.write(new PNG({ width: 2, height: 2 }));
                const larger = PNG.sync.write(new PNG({ width: 64, height: 64 }));
                await fs.promises.writeFile(output, Buffer.concat([small.subarray(0, 33), larger.subarray(8, 33), small.subarray(33)]));
            } else if (kind === 'interlaced') {
                const encoded = PNG.sync.write(new PNG({ width: 2, height: 2 })); encoded[28] = 1;
                await fs.promises.writeFile(output, encoded);
            }
            else await fs.promises.writeFile(output, 'not a PNG');
            return { path: kind === 'different-path' ? path.join(scratch, 'other.png') : request.output, width: 2, height: 2 };
        });
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow();
        expect(decode).not.toHaveBeenCalled();
    });
    it('save cancellation does not start the runtime and keeps verification usable', async () => {
        const selection = await verified(); dialog.showSaveDialog.mockResolvedValueOnce({ canceled: true, filePath: '' });
        await expect(invoke('generate', generateRequest(selection.handle))).resolves.toBeNull();
        expect(service.generate).not.toHaveBeenCalled();
        await expect(invoke('generate', generateRequest(selection.handle))).resolves.toMatchObject({ path: output });
    });
    it('reserves the operation before awaiting the native dialog and cancels without verifying', async () => {
        const selection = await selected(), wait = deferred<{ model: string; components: number; bytes: number }>();
        service.verify.mockImplementation(() => wait.promise);
        const pending = invoke('verify', { modelId: preset.id, folderHandle: selection.handle });
        await vi.waitFor(() => expect(service.verify).toHaveBeenCalled());
        await expect(invoke('folder')).rejects.toThrow('already running');
        await invoke('cancel'); expect(service.verify.mock.calls[0][2].aborted).toBe(true);
        wait.resolve({ model: preset.id, components: 1, bytes: 4 });
        await expect(pending).rejects.toThrow('cancelled');
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow('Verify');
    });
    it.each(['close', 'navigate', 'dispose'])('aborts on %s and retains child cleanup through shutdown', async reason => {
        const selection = await verified(); const wait = deferred<{ path: string; width: number; height: number }>();
        service.generate.mockImplementation(() => wait.promise);
        const pending = invoke('generate', generateRequest(selection.handle));
        await vi.waitFor(() => expect(service.generate).toHaveBeenCalled());
        let disposal: Promise<void> | undefined;
        if (reason === 'close') window.emit('closed');
        else if (reason === 'navigate') window.webContents.emit('did-start-navigation', {}, trustedUrl, false, true);
        else disposal = bridge.dispose();
        expect(service.generate.mock.calls[0][0].signal.aborted).toBe(true);
        if (reason === 'close') disposal = bridge.dispose();
        wait.resolve({ path: output, width: 2, height: 2 });
        await expect(pending).rejects.toThrow('cancelled'); await disposal;
    });
    it('forwards finite validated progress only, tied to the request and trusted page', async () => {
        const selection = await verified();
        const real = service.generate.getMockImplementation()!;
        service.generate.mockImplementation(async (request: ImageGenerationRequest) => {
            request.onProgress?.({ step: 1, steps: 2 }); request.onProgress?.({ step: 999, steps: 999 });
            return real(request);
        });
        await invoke('generate', generateRequest(selection.handle));
        expect(window.webContents.send.mock.calls).toEqual([[IMAGE_CHANNELS.progress, { requestId, step: 1, steps: 2 }]]);
    });
    it('aborts a runtime flooding progress and bounds forwarded IPC', async () => {
        const selection = await verified();
        service.generate.mockImplementation(async (request: ImageGenerationRequest) => {
            for (let i = 0; i < 1000; i++) request.onProgress?.({ step: 1, steps: 2 });
            expect(request.signal!.aborted).toBe(true);
            return { path: output, width: 2, height: 2 };
        });
        await expect(invoke('generate', generateRequest(selection.handle))).rejects.toThrow('cancelled');
        expect(window.webContents.send).toHaveBeenCalledTimes(200);
    });
    it('bounds service errors and removes handlers/listeners on dispose', async () => {
        service.models.mockImplementation(() => { throw new Error('a'.repeat(50_000)); });
        await expect(invoke('models')).rejects.toHaveProperty('message', 'a'.repeat(2048));
        await bridge.dispose(); expect(handlers.size).toBe(0);
        expect(window.listenerCount('closed')).toBe(0); expect(window.webContents.listenerCount('did-start-navigation')).toBe(0);
    });
});

describe('sandboxed CommonJS preload', () => {
    it('emits .cjs, needs only sandbox Electron, preserves launch auth and exposes fixed IPC methods', async () => {
        const scratch = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-preload-'));
        try {
            const root = process.cwd(); const source = path.join(root, 'src/electron/sandboxPreload.cts');
            const config = ts.readConfigFile(path.join(root, 'tsconfig.json'), ts.sys.readFile);
            const included = ts.parseJsonConfigFileContent(config.config, ts.sys, root);
            expect(included.fileNames).toContain(source);
            const program = ts.createProgram([source], { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.NodeNext, moduleResolution: ts.ModuleResolutionKind.NodeNext,
                types: ['node'], strict: true, skipLibCheck: true, rootDir: root, outDir: scratch });
            expect(ts.getPreEmitDiagnostics(program).map(diagnostic => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'))).toEqual([]);
            program.emit();
            const emitted = await fs.promises.readFile(path.join(scratch, 'src/electron/sandboxPreload.cjs'), 'utf8');
            const exposed: Record<string, any> = {}, listeners = new Map<string, Function>(), invokes = vi.fn(async () => undefined);
            const requireModule = vi.fn((module: string) => {
                if (module !== 'electron') throw new Error(`Sandbox cannot require ${module}`);
                return { contextBridge: { exposeInMainWorld: (key: string, value: unknown) => { exposed[key] = value; } },
                    ipcRenderer: { invoke: invokes, on: (channel: string, listener: Function) => { listeners.set(channel, listener); } } };
            });
            vm.runInNewContext(emitted, { exports: {}, require: requireModule, process: { argv: ['electron', '--quenderin-auth=fixture-launch-token'], env: { npm_package_version: 'test-version' } } });
            expect(requireModule.mock.calls).toEqual([['electron']]); expect(exposed.quenderinAuth.token).toBe('fixture-launch-token');
            expect(exposed.quenderinAPI.getVersion()).toBe('test-version');
            expect(Object.keys(exposed.quenderinImages).sort()).toEqual(['cancel', 'chooseFolder', 'generate', 'models', 'onProgress', 'verify']);
            await exposed.quenderinImages.chooseFolder(); await exposed.quenderinImages.cancel();
            expect(invokes.mock.calls.map(call => call[0])).toEqual([IMAGE_CHANNELS.folder, IMAGE_CHANNELS.cancel]);
            const callback = vi.fn(), unsubscribe = exposed.quenderinImages.onProgress(callback);
            const progress = listeners.get(IMAGE_CHANNELS.progress)!;
            progress({ sender: 'never forwarded' }, { requestId, step: 1, steps: 2, path: '/private' });
            progress({}, { requestId, step: 400, steps: 400 });
            expect(callback.mock.calls).toEqual([[{ requestId, step: 1, steps: 2 }]]);
            unsubscribe(); progress({}, { requestId, step: 2, steps: 2 }); expect(callback).toHaveBeenCalledTimes(1);
            for (let i = 0; i < 4; i++) exposed.quenderinImages.onProgress(() => {});
            expect(() => exposed.quenderinImages.onProgress(() => {})).toThrow('Too many');
            const main = await fs.promises.readFile('src/electron/main.ts', 'utf8');
            expect(main).toContain("'sandboxPreload.cjs'"); expect(main).toContain('sandbox: true'); expect(main).toContain('contextIsolation: true');
            expect(await fs.promises.readFile('electron-builder.yaml', 'utf8')).toContain('  - dist/**/*');
        } finally { await fs.promises.rm(scratch, { recursive: true, force: true }); }
    });
});
