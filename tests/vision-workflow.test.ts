import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { IpcMainInvokeEvent } from 'electron';
import { registerVisionWorkflow, VISION_CHANNELS } from '../src/electron/visionWorkflow.js';
import { VISION_MODELS } from '../src/visionModels.js';

describe('vision selection and invocation boundary', () => {
    const trustedUrl = 'http://localhost:39491/';
    let root: string, image: string;
    let handlers: Map<string, (event: IpcMainInvokeEvent, value?: unknown) => Promise<unknown>>;
    let window: EventEmitter & { webContents: EventEmitter & { mainFrame: { url: string }; getURL(): string; send: ReturnType<typeof vi.fn> }; isDestroyed(): boolean };
    let event: IpcMainInvokeEvent;
    let bridge: ReturnType<typeof registerVisionWorkflow>;
    let service: { models: ReturnType<typeof vi.fn>; status: ReturnType<typeof vi.fn>; install: ReturnType<typeof vi.fn>; verify: ReturnType<typeof vi.fn>; answer: ReturnType<typeof vi.fn> };
    let dialog: { showOpenDialog: ReturnType<typeof vi.fn> };
    const invoke = (channel: keyof typeof VISION_CHANNELS, value?: unknown, sender = event) => handlers.get(VISION_CHANNELS[channel])!(sender, value);
    beforeEach(async () => {
        root = await fs.promises.realpath(await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-vision-ipc-')));
        image = path.join(root, 'fixture.png'); await fs.promises.writeFile(image, 'tiny image fixture; native decoder is tested separately');
        handlers = new Map();
        const webContents = Object.assign(new EventEmitter(), { mainFrame: { url: trustedUrl }, getURL: () => trustedUrl, send: vi.fn() });
        window = Object.assign(new EventEmitter(), { webContents, isDestroyed: () => false });
        event = { sender: webContents, senderFrame: webContents.mainFrame } as unknown as IpcMainInvokeEvent;
        service = { models: vi.fn(() => VISION_MODELS), status: vi.fn(async () => ({ installed: true, availableMemoryBytes: 1024 ** 4 })),
            install: vi.fn(async () => {}), verify: vi.fn(async () => {}), answer: vi.fn(async () => ({ text: 'Fixture answer', tokens: 3 })) };
        dialog = { showOpenDialog: vi.fn(async () => ({ canceled: false, filePaths: [image] })) };
        bridge = registerVisionWorkflow({ ipcMain: { handle: (channel, work) => handlers.set(channel, work), removeHandler: channel => handlers.delete(channel) } as never,
            dialog: dialog as never, getWindow: () => window as never, trustedUrl, service });
    });
    afterEach(async () => { await bridge.dispose(); await fs.promises.rm(root, { recursive: true, force: true }); });
    it('requires the exact trusted window, main frame and URL before any file dialog', async () => {
        for (const hostile of [{ sender: window.webContents, senderFrame: { url: trustedUrl } }, { sender: {}, senderFrame: window.webContents.mainFrame }]) {
            await expect(invoke('image', undefined, hostile as IpcMainInvokeEvent)).rejects.toThrow(/Untrusted/);
        }
        window.webContents.mainFrame.url = trustedUrl + '?changed=1';
        await expect(invoke('models')).rejects.toThrow(/Untrusted/);
        expect(dialog.showOpenDialog).not.toHaveBeenCalled();
    });
    it('passes only the selected native-dialog image to the real service', async () => {
        const selection = await invoke('image') as { handle: string; label: string };
        expect(selection.label).toBe('fixture.png'); expect(selection.handle).not.toContain(image);
        await expect(invoke('answer', { modelId: VISION_MODELS[0].id, imageHandle: selection.handle, prompt: 'Describe it.' })).resolves.toMatchObject({ text: 'Fixture answer' });
        expect(service.answer.mock.calls[0].slice(0, 3)).toEqual([VISION_MODELS[0].id, image, 'Describe it.']);
        await expect(invoke('answer', { modelId: VISION_MODELS[0].id, imageHandle: image, prompt: 'Describe it.' })).rejects.toThrow(/changed/);
    });
    it('rejects arbitrary paths, models and runtime fields', async () => {
        const selection = await invoke('image') as { handle: string };
        await expect(invoke('install', '../../model')).rejects.toThrow();
        await expect(invoke('answer', { modelId: VISION_MODELS[0].id, imageHandle: selection.handle, prompt: 'Describe.', imagePath: '/private/file' })).rejects.toThrow(/Invalid/);
        expect(service.answer).not.toHaveBeenCalled();
    });
    it('rejects a changed or oversized selected file', async () => {
        const selection = await invoke('image') as { handle: string };
        await fs.promises.writeFile(image, 'changed');
        await expect(invoke('answer', { modelId: VISION_MODELS[0].id, imageHandle: selection.handle, prompt: 'Describe.' })).rejects.toThrow(/changed/);
        const file = await fs.promises.open(image, 'w'); await file.truncate(8 * 1024 ** 2 + 1); await file.close();
        await expect(invoke('image')).rejects.toThrow(/8 MiB/);
    });
    it('cancels in-flight native work on navigation and serializes operations', async () => {
        let finish!: () => void;
        service.install.mockImplementation((_id, signal: AbortSignal) => new Promise<void>(resolve => { finish = resolve; expect(signal.aborted).toBe(false); }));
        const pending = invoke('install', VISION_MODELS[0].id);
        await vi.waitFor(() => expect(service.install).toHaveBeenCalled());
        await expect(invoke('image')).rejects.toThrow(/already running/);
        window.webContents.emit('did-start-navigation', {}, trustedUrl, false, true);
        expect(service.install.mock.calls[0][1].aborted).toBe(true); finish(); await pending;
    });
    it('does not replace a selected image when the user cancels a new selection', async () => {
        const original = await invoke('image') as { handle: string };
        dialog.showOpenDialog.mockResolvedValueOnce({ canceled: true, filePaths: [] });
        await expect(invoke('image')).resolves.toBeNull();
        await expect(invoke('answer', { modelId: VISION_MODELS[0].id, imageHandle: original.handle, prompt: 'Describe.' })).resolves.toMatchObject({ text: 'Fixture answer' });
    });
});
