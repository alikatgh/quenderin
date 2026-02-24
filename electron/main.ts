import { app, BrowserWindow } from 'electron';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { startDashboardServer } from '../src/server.js'; // Adjust path based on built TS output

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function createWindow() {
    const win = new BrowserWindow({
        width: 1200,
        height: 800,
        title: 'Quenderin',
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });

    // Load the React app from the public folder or localhost
    // Note: startDashboardServer boots on port 3000
    win.loadURL('http://localhost:3000');
}

app.whenReady().then(async () => {
    // Start the local Quenderin backend *before* opening the window
    console.log("Starting bundled Quenderin backend...");
    try {
        // Provide an empty array for args since we're not running via CLI
        await startDashboardServer(3000);
        await createWindow();
    } catch (err) {
        console.error("Failed to start bundled backend:", err);
    }

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});
