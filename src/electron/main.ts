import { app, BrowserWindow, Menu, Tray, globalShortcut, nativeImage } from 'electron';
import path from 'path';
import { fileURLToPath } from 'url';
import { startDashboardServer } from '../server.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
const PORT = 3000;

async function bootstrap() {
    // 1. Boot internal Node.js backend (Adb, LLaMA, WebSockets, Express)
    console.log("Booting Quenderin backend...");
    await startDashboardServer(PORT, false); // false = don't open system browser

    // 2. Create the Electron Window
    mainWindow = new BrowserWindow({
        width: 1280,
        height: 800,
        minWidth: 900,
        minHeight: 600,
        titleBarStyle: 'hiddenInset',
        backgroundColor: '#18181b', // Match dark mode default
        show: false, // Wait until ready to show to prevent flashing
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true
        }
    });

    // 3. Load the Dashboard
    mainWindow.loadURL(`http://localhost:${PORT}`);

    mainWindow.once('ready-to-show', () => {
        mainWindow?.show();
    });

    // Native Tray
    // Create a 16x16 empty transparent native image or icon if available
    const icon = nativeImage.createEmpty();
    tray = new Tray(icon);
    tray.setToolTip('Quenderin Agent');
    tray.setContextMenu(Menu.buildFromTemplate([
        { label: 'Show App', click: () => mainWindow?.show() },
        {
            label: 'Quit', click: () => {
                app.quit();
            }
        }
    ]));

    // Register a 'CommandOrControl+Option+Q' shortcut listener.
    globalShortcut.register('CommandOrControl+Option+Q', () => {
        if (mainWindow) {
            if (mainWindow.isVisible()) {
                mainWindow.hide();
            } else {
                mainWindow.show();
                mainWindow.focus();
            }
        }
    });

    // Register 🚨 INTERVENTION HOTKEY 🚨
    globalShortcut.register('CommandOrControl+Option+C', () => {
        console.log("🛠️ Human Intervention Triggered via Hotkey (Cmd+Opt+C)");
        // Ping the local Node server to halt the agent loop
        fetch(`http://localhost:${PORT}/api/agent/intervene`, { method: 'POST' })
            .catch(e => console.error("Failed to trigger intervention route:", e));

        // Pop the UI up immediately so the user can interact
        if (mainWindow && !mainWindow.isVisible()) {
            mainWindow.show();
            mainWindow.focus();
        }
    });

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

app.whenReady().then(async () => {
    // Mac optimization: create application menu
    if (process.platform === 'darwin') {
        const template: any = [
            {
                label: 'Quenderin',
                submenu: [
                    { role: 'about' },
                    { type: 'separator' },
                    { role: 'services' },
                    { type: 'separator' },
                    { role: 'hide' },
                    { role: 'hideOthers' },
                    { role: 'unhide' },
                    { type: 'separator' },
                    { role: 'quit' }
                ]
            },
            {
                label: 'Edit',
                submenu: [
                    { role: 'undo' },
                    { role: 'redo' },
                    { type: 'separator' },
                    { role: 'cut' },
                    { role: 'copy' },
                    { role: 'paste' },
                    { role: 'selectAll' }
                ]
            }
        ];
        Menu.setApplicationMenu(Menu.buildFromTemplate(template));
    }

    await bootstrap();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            bootstrap();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('will-quit', () => {
    // Unregister all shortcuts.
    globalShortcut.unregisterAll();
});
