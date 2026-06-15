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

    // Window/navigation hardening (H33): deny new-window/popup requests and block any
    // navigation away from the local app origin.
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.webContents.on('will-navigate', (event, navUrl) => {
        if (!navUrl.startsWith(appOrigin)) {
            event.preventDefault();
        }
    });

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
