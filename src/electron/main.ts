import { app, BrowserWindow, Menu, Tray, globalShortcut, nativeImage } from 'electron';
import path from 'path';
import { fileURLToPath } from 'url';
import net from 'net';
import { startDashboardServer } from '../server.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;

async function findFreePort(startPort: number, attempt = 0): Promise<number> {
    // Bound the search: without this, a host where every probed port errors (EACCES on a locked-down
    // box, or startPort climbing past 65535) bumps forever. Only EADDRINUSE is worth retrying — any
    // other error won't clear by trying the next port, so fail fast with the real cause.
    if (attempt > 100 || startPort > 65535) {
        throw new Error(`Could not find a free port near ${startPort - attempt} after ${attempt} attempts`);
    }
    return new Promise((resolve, reject) => {
        const s = net.createServer();
        s.once('error', (err: NodeJS.ErrnoException) => {
            if (err.code === 'EADDRINUSE') {
                findFreePort(startPort + 1, attempt + 1).then(resolve, reject);
            } else {
                reject(err);
            }
        });
        s.listen(startPort, () => {
            const port = (s.address() as net.AddressInfo).port;
            s.close(() => resolve(port));
        });
    });
}

/** (Re)create the dashboard window. Split out from bootstrap so a macOS dock re-activate makes a
 *  fresh window WITHOUT re-booting the backend server / Tray / global shortcuts. */
function createWindow() {
    const isMac = process.platform === 'darwin';
    mainWindow = new BrowserWindow({
        width: 1280,
        height: 800,
        minWidth: 900,
        minHeight: 600,
        // hiddenInset only works on macOS; use default frame elsewhere
        ...(isMac ? { titleBarStyle: 'hiddenInset' as const } : { frame: true }),
        backgroundColor: '#18181b', // Match dark mode default
        show: false, // Wait until ready to show to prevent flashing
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true
        }
    });

    mainWindow.loadURL(`http://localhost:${PORT}`);

    // Pin all navigation + new-window requests to the trusted local origin. The renderer displays
    // untrusted agent/LLM/on-screen content; without these guards a reflected link or injected
    // `window.location`/`window.open` could navigate the window to a remote or file:// URL and escape
    // the security boundary (deep-hunt HIGH).
    const trustedOrigin = `http://localhost:${PORT}`;
    mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    mainWindow.webContents.on('will-navigate', (event, navUrl) => {
        if (navUrl !== trustedOrigin && !navUrl.startsWith(trustedOrigin + '/')) {
            event.preventDefault();
        }
    });

    mainWindow.once('ready-to-show', () => {
        mainWindow?.show();
    });

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

async function bootstrap() {
    // Determine dynamic port gracefully
    PORT = await findFreePort(PORT);

    // 1. Boot internal Node.js backend (Adb, LLaMA, WebSockets, Express)
    console.log(`Booting Quenderin backend on port ${PORT}...`);
    await startDashboardServer(PORT, false); // false = don't open system browser

    // 2. Create the Electron Window — platform-aware chrome
    createWindow();

    // 3. Native Tray (created once for the app lifetime)
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

    // 4. Global shortcuts (registered once)
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
}

app.whenReady().then(async () => {
    // Platform-aware application menu
    const editSubmenu = [
        { role: 'undo' as const },
        { role: 'redo' as const },
        { type: 'separator' as const },
        { role: 'cut' as const },
        { role: 'copy' as const },
        { role: 'paste' as const },
        { role: 'selectAll' as const }
    ];

    if (process.platform === 'darwin') {
        Menu.setApplicationMenu(Menu.buildFromTemplate([
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
            { label: 'Edit', submenu: editSubmenu }
        ]));
    } else {
        // Linux & Windows: simpler menu without macOS-specific roles
        Menu.setApplicationMenu(Menu.buildFromTemplate([
            {
                label: 'File',
                submenu: [
                    { role: 'quit' }
                ]
            },
            { label: 'Edit', submenu: editSubmenu }
        ]));
    }

    try {
        await bootstrap();
    } catch (err) {
        // findFreePort exhaustion or a backend boot failure is fatal — surface it and exit cleanly
        // instead of leaving a half-initialized app (deep-hunt: previously an unhandled rejection).
        console.error('Fatal: Quenderin failed to start:', err);
        app.quit();
        return;
    }

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            // Backend + Tray + shortcuts already exist — only the window was closed; just remake it.
            createWindow();
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
