// Sandboxed Electron preloads must be CommonJS, including in a type:module package.
// Keep this file self-contained: the sandbox's require only exposes Electron/built-ins.
import { contextBridge, ipcRenderer } from 'electron';
import type { ImageGenerationProgress, ImageWorkflowAPI } from './imageWorkflowTypes.js' with { 'resolution-mode': 'import' };

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
