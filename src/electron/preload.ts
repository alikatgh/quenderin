import { contextBridge } from 'electron';

// Expose safe APIs to the renderer process securely
// This complies with contextIsolation: true and nodeIntegration: false
contextBridge.exposeInMainWorld('quenderinAPI', {
    // Add any necessary IPC methods here if the dashboard needs them in the future
    getVersion: () => process.env.npm_package_version || "0.0.1"
});
