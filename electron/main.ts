import { app, BrowserWindow } from 'electron';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { startDashboardServer } from '../src/server.js'; // Adjust path based on built TS output

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function createWindow(port: number) {
    const win = new BrowserWindow({
        width: 1200,
        height: 800,
        title: 'Quenderin',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            sandbox: true,
            preload: path.join(__dirname, '..', 'src', 'electron', 'preload.js')
        }
    });

    const appOrigin = `http://localhost:${port}`;

    // Window/navigation hardening: deny popups, and block any navigation OR server-redirect away
    // from the local app origin. Compare PARSED origins — startsWith(appOrigin) would pass for
    // http://localhost:3000.attacker.com (H11). will-navigate covers renderer-initiated nav;
    // will-redirect covers HTTP 3xx redirects that will-navigate misses (H12).
    const sameOrigin = (target: string): boolean => {
        try { return new URL(target).origin === appOrigin; } catch { return false; }
    };
    const blockOffOrigin = (event: { preventDefault: () => void }, navUrl: string) => {
        if (!sameOrigin(navUrl)) event.preventDefault();
    };
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.webContents.on('will-navigate', blockOffOrigin);
    win.webContents.on('will-redirect', blockOffOrigin);

    // Load the React app from the local backend on the port it actually bound to
    // (the server falls back off 3000 when it's busy — loading a hardcoded 3000 would 500).
    win.loadURL(appOrigin);
}

app.whenReady().then(async () => {
    // Start the local Quenderin backend *before* opening the window
    console.log("Starting bundled Quenderin backend...");
    try {
        const port = await startDashboardServer(3000);
        await createWindow(port);

        app.on('activate', async () => {
            if (BrowserWindow.getAllWindows().length === 0) {
                await createWindow(port);
            }
        });
    } catch (err) {
        console.error("Failed to start bundled backend:", err);
    }
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});
