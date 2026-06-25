import { contextBridge } from 'electron';

// The per-launch auth token, passed by the main process via webPreferences.additionalArguments
// (audit HIGH #1). Only the trusted renderer sees it — a local attacker process can't read another
// process's argv. The renderer reads window.quenderinAuth.token and sends it on the WS upgrade +
// state-changing fetches. Absent in the CLI/browser build (that path uses the opened URL's ?token=).
const authArg = process.argv.find((a) => a.startsWith('--quenderin-auth='));
const authToken = authArg ? authArg.slice('--quenderin-auth='.length) : '';

// Expose safe APIs to the renderer process securely
// This complies with contextIsolation: true and nodeIntegration: false
contextBridge.exposeInMainWorld('quenderinAPI', {
    // Add any necessary IPC methods here if the dashboard needs them in the future
    getVersion: () => process.env.npm_package_version || "0.0.1"
});

contextBridge.exposeInMainWorld('quenderinAuth', { token: authToken });
