// Sandboxed Electron preloads must be CommonJS, including in a type:module package.
// Keep this file self-contained: the sandbox's require only exposes Electron/built-ins.
import { contextBridge, ipcRenderer } from 'electron';
import type { ImageGenerationProgress, ImageWorkflowAPI } from './imageWorkflowTypes.js' with { 'resolution-mode': 'import' };
import type { VisionWorkflowAPI } from './visionWorkflowTypes.js' with { 'resolution-mode': 'import' };

const authArg = process.argv.find(argument => argument.startsWith('--quenderin-auth='));
const authToken = authArg ? authArg.slice('--quenderin-auth='.length) : '';
contextBridge.exposeInMainWorld('quenderinAPI', { getVersion: () => process.env.npm_package_version || '0.0.1' });
contextBridge.exposeInMainWorld('quenderinAuth', { token: authToken });

const subscribers = new Set<(progress: ImageGenerationProgress) => void>();
ipcRenderer.on('quenderin:image:progress', (_event, value: unknown) => {
    if (!value || typeof value !== 'object') return;
    const progress = value as ImageGenerationProgress;
    if (typeof progress.requestId !== 'string' || !/^[a-f0-9-]{36}$/u.test(progress.requestId)
        || !Number.isInteger(progress.step) || !Number.isInteger(progress.steps)
        || progress.steps < 1 || progress.steps > 50 || progress.step < 0 || progress.step > progress.steps) return;
    const safe = { requestId: progress.requestId, step: progress.step, steps: progress.steps };
    for (const subscriber of subscribers) {
        try { subscriber(safe); } catch { /* a renderer callback cannot break other listeners */ }
    }
});

const images: ImageWorkflowAPI = {
    models: () => ipcRenderer.invoke('quenderin:image:models'),
    chooseFolder: () => ipcRenderer.invoke('quenderin:image:folder'),
    verify: request => ipcRenderer.invoke('quenderin:image:verify', request),
    generate: request => ipcRenderer.invoke('quenderin:image:generate', request),
    cancel: () => ipcRenderer.invoke('quenderin:image:cancel'),
    onProgress: callback => {
        if (typeof callback !== 'function' || subscribers.size >= 4) throw new Error('Too many image progress listeners.');
        subscribers.add(callback);
        return () => { subscribers.delete(callback); };
    },
};
contextBridge.exposeInMainWorld('quenderinImages', images);

const visionSubscribers = new Set<(progress: { modelId: string; fraction: number }) => void>();
ipcRenderer.on('quenderin:vision:progress', (_event, value: unknown) => {
    const progress = value as { modelId?: unknown; fraction?: unknown } | null;
    if (!progress || typeof progress.modelId !== 'string' || progress.modelId.length > 80 || typeof progress.fraction !== 'number' || !Number.isFinite(progress.fraction) || progress.fraction < 0 || progress.fraction > 1) return;
    const safe = { modelId: progress.modelId, fraction: progress.fraction };
    for (const subscriber of visionSubscribers) { try { subscriber(safe); } catch { /* isolate renderer callbacks */ } }
});
const vision: VisionWorkflowAPI = {
    models: () => ipcRenderer.invoke('quenderin:vision:models'), status: id => ipcRenderer.invoke('quenderin:vision:status', id),
    chooseImage: () => ipcRenderer.invoke('quenderin:vision:image'), install: id => ipcRenderer.invoke('quenderin:vision:install', id),
    verify: id => ipcRenderer.invoke('quenderin:vision:verify', id), answer: request => ipcRenderer.invoke('quenderin:vision:answer', request),
    chooseGraniteModel: () => ipcRenderer.invoke('quenderin:granite:model'), answerGranite: request => ipcRenderer.invoke('quenderin:granite:answer', request),
    cancel: () => ipcRenderer.invoke('quenderin:vision:cancel'), onProgress: callback => {
        if (typeof callback !== 'function' || visionSubscribers.size >= 4) throw new Error('Too many vision listeners.');
        visionSubscribers.add(callback); return () => { visionSubscribers.delete(callback); };
    },
};
contextBridge.exposeInMainWorld('quenderinVision', vision);
