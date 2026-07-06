import { app, BrowserWindow, Menu, Tray, globalShortcut, nativeImage } from 'electron';
import path from 'path';
import { fileURLToPath } from 'url';
import { startDashboardServer } from '../server.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
// Set from startDashboardServer()'s return — the ACTUAL bound port and the per-launch auth
// token. The old code pre-probed a port with its own all-interfaces net.createServer and threw
// the server's return away, so the window could load the wrong port with no token, breaking all
// WS/API auth (Q-001/Q-128/Q-130). The server binds BIND_HOST and is the single source of truth.
let PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;
let AUTH_TOKEN = '';

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
            contextIsolation: true,
            // Q-524: run the renderer in a sandbox. The renderer displays untrusted agent/LLM/on-screen
            // content, so a sandboxed OS process is the right blast radius. Safe here because the preload
            // only touches process.argv/process.env — both available in Electron's sandboxed preload
            // polyfill — and talks to the renderer purely through contextBridge.
            sandbox: true,
            // Hand the per-launch token to the renderer via argv — preload.ts reads
            // `--quenderin-auth=` and exposes it on window.quenderinAuth (Q-001/Q-011). A local
            // attacker process cannot read another process's argv. Set before every createWindow()
            // (incl. the activate re-create), so a remade window is never token-less (Q-129).
            additionalArguments: [`--quenderin-auth=${AUTH_TOKEN}`]
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
    // 1. Boot internal Node.js backend (Adb, LLaMA, WebSockets, Express). It picks the actual
    //    free port (findAvailablePort, bound to BIND_HOST) and mints the auth token — capture
    //    BOTH from the return instead of pre-probing our own port (which bound all interfaces and
    //    could disagree) and discarding the token (Q-001/Q-128).
    console.log(`Booting Quenderin backend near port ${PORT}...`);
    const { port, authToken } = await startDashboardServer(PORT, false); // false = don't open system browser
    PORT = port;
    AUTH_TOKEN = authToken;

    // 2. Create the Electron Window — platform-aware chrome (loads PORT, carries AUTH_TOKEN)
    createWindow();

    // 3. Native Tray (created once for the app lifetime). Q-534: use a REAL icon — createEmpty() rendered
    //    an invisible menu-bar item. favicon.png ships in the bundle (public/** is in electron-builder
    //    `files:`, unlike brand/). main.js compiles to dist/src/electron/main.js (tsconfig outDir ./dist,
    //    rootDir ./, so src/ is preserved), so __dirname is dist/src/electron and public/ is THREE levels
    //    up (dist/src/electron -> dist/src -> dist -> root/public); the same relative path holds inside the
    //    packaged asar. (The adversarial-verify pass caught the earlier ../../public — that resolved to the
    //    non-existent dist/public, so the icon stayed empty and Q-534 was effectively unfixed.) Guarded:
    //    an unreadable asset falls back to the empty icon rather than aborting boot.
    let icon = nativeImage.createEmpty();
    try {
        const loaded = nativeImage.createFromPath(path.join(__dirname, '..', '..', '..', 'public', 'favicon.png'));
        if (!loaded.isEmpty()) icon = loaded.resize({ width: 18, height: 18 });
    } catch { /* keep the empty fallback */ }
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
        // Ping the local Node server to halt the agent loop. /api/agent/intervene is a mutating
        // POST, so it now requires the token — without the header this silently 401'd and the
        // hotkey did nothing (Q-008).
        fetch(`http://localhost:${PORT}/api/agent/intervene`, {
            method: 'POST',
            headers: { 'X-Auth-Token': AUTH_TOKEN }
        }).catch(e => console.error("Failed to trigger intervention route:", e));

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
