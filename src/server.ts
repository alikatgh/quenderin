import { createServer } from 'http';
import net from 'net';
import open from 'open';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import { createApp } from './app.js';
import { WebSocketManager } from './websocket/index.js';
import { AgentService } from './services/agent.service.js';
import { AgentEventEmitter } from './services/agent.service.js';
import { AndroidProvider } from './services/providers/android.provider.js';
import { DesktopProvider } from './services/providers/desktop.provider.js';
import { BackgroundDaemonService } from './services/backgroundDaemon.service.js';
import { VoiceService } from './services/voice.service.js';
import { LlmService } from './services/llm.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';
import { SessionService } from './services/session.service.js';
import { setHealthLlmService } from './routes/health.js';
import { resetReadinessForStartup, setReadiness } from './services/readiness.service.js';

/**
 * Periodically clean up orphaned Quenderin temp files (screenshots, WAV recordings)
 * to prevent /tmp from filling up on devices with small storage.
 */
async function cleanupOrphanedTempFiles(): Promise<void> {
    try {
        const tmpDir = os.tmpdir();
        const entries = await fs.readdir(tmpDir);
        const now = Date.now();
        const maxAgeMs = 60 * 60 * 1000; // 1 hour

        for (const entry of entries) {
            if (!entry.startsWith('desktop_screen_') &&
                !entry.startsWith('screen_') &&
                !entry.startsWith('window_dump_') &&
                !entry.startsWith('quenderin_voice_')) {
                continue;
            }
            try {
                const filePath = path.join(tmpDir, entry);
                const stat = await fs.stat(filePath);
                if (now - stat.mtimeMs > maxAgeMs) {
                    await fs.unlink(filePath);
                }
            } catch { /* file may have been deleted by another process */ }
        }
    } catch { /* non-fatal */ }
}

async function isPortFree(port: number): Promise<boolean> {
    return new Promise((resolve) => {
        const tester = net.createServer()
            .once('error', () => resolve(false))
            .once('listening', () => {
                tester.close(() => resolve(true));
            })
            .listen(port, '::');
    });
}

async function findAvailablePort(startPort: number, maxTries: number = 20): Promise<number> {
    for (let candidate = startPort; candidate < startPort + maxTries; candidate++) {
        if (await isPortFree(candidate)) {
            return candidate;
        }
    }
    throw new Error(`No available port found in range ${startPort}-${startPort + maxTries - 1}`);
}

export async function startDashboardServer(port: number = 3000, openBrowser: boolean = true): Promise<void> {
    resetReadinessForStartup('Dashboard startup initiated');
    setReadiness(false, 'initializing-services', 'Initializing core services');

    const selectedPort = await findAvailablePort(port);
    if (selectedPort !== port) {
        console.warn(`[Server] Port ${port} is busy, starting on port ${selectedPort} instead.`);
    }
    const isCi = process.env.CI === 'true' || process.env.GITHUB_ACTIONS === 'true';
    const isInteractiveShell = Boolean(process.stdout.isTTY && process.stdin.isTTY);
    const browserDisabledByEnv = process.env.QUENDERIN_NO_BROWSER === '1' || process.env.BROWSER === 'none';
    const effectiveOpenBrowser = openBrowser && !isCi && isInteractiveShell && !browserDisabledByEnv;

    if (openBrowser && !effectiveOpenBrowser) {
        const reason = isCi
            ? 'CI environment detected'
            : !isInteractiveShell
                ? 'non-interactive shell detected'
                : 'browser disabled by environment';
        console.log(`[Server] Browser auto-open disabled (${reason}).`);
    }

    // 1. Dependency Injection / Initialize Services
    const targetOS = process.env.TARGET_OS || 'android';

    const deviceProvider = targetOS === 'desktop'
        ? new DesktopProvider()
        : new AndroidProvider();

    const uiParserService = new UiParserService();
    const llmService = new LlmService();
    const metricsService = new MetricsService();
    const ocrService = new OcrService();
    const memoryService = new MemoryService();
    const agentService = new AgentService(llmService, deviceProvider, uiParserService, metricsService, ocrService, memoryService);
    const backgroundDaemon = new BackgroundDaemonService(deviceProvider, llmService, metricsService);
    const voiceService = new VoiceService();
    const sessionService = new SessionService();

    // Wire LlmService into /health so it reports the real loaded model
    setHealthLlmService(llmService);

    // Start background passive observation
    backgroundDaemon.on('error', (e) => console.log(`[Background Observer] ${e}`));
    backgroundDaemon.start();

    // Boot Voice Control — pipe spoken commands into the agent with the correct signature
    voiceService.on('error', (e) => console.log(`[Voice Control] ${e}`));
    voiceService.on('command', (spokenCommand: string) => {
        console.log(`\n\n[Voice Trigger] Executing objective: "${spokenCommand}"...`);
        agentService.runAgentLoop(spokenCommand, new AgentEventEmitter(), [], 20);
    });
    const picovoiceAccessKey = process.env.PICOVOICE_ACCESS_KEY;
    if (picovoiceAccessKey) {
        await voiceService.initialize(picovoiceAccessKey);
    } else {
        console.warn('[Voice Control] PICOVOICE_ACCESS_KEY is not set. Voice controls are disabled.');
    }

    // 2. Setup Express
    setReadiness(false, 'starting-http-server', `Binding HTTP server on port ${selectedPort}`);
    const app = createApp(metricsService, agentService, llmService, sessionService, memoryService);
    const server = createServer(app);

    // 2b. Start periodic temp file cleanup (every 30 min)
    const cleanupTimer = setInterval(cleanupOrphanedTempFiles, 30 * 60 * 1000);
    cleanupTimer.unref();
    // Run once at startup to clean up leftovers from previous crashes
    cleanupOrphanedTempFiles();

    // 3. Graceful shutdown handlers
    const shutdown = () => {
        setReadiness(false, 'shutting-down', 'Shutdown signal received');
        console.log('\n[System] Shutting down gracefully...');
        clearInterval(cleanupTimer);
        backgroundDaemon.stop();
        voiceService.shutdown();
        ocrService.terminate().catch(() => { });
        // Final cleanup of temp files on shutdown
        cleanupOrphanedTempFiles().catch(() => {});
        server.close(() => {
            console.log('[System] HTTP server closed.');
            process.exit(0);
        });
        // Force-kill after 10 s if something hangs
        setTimeout(() => process.exit(1), 10_000).unref();
    };
    process.once('SIGTERM', shutdown);
    process.once('SIGINT', shutdown);

    // 4. Boot Server
    return new Promise<void>((resolve, reject) => {
        server.once('error', (err: NodeJS.ErrnoException) => {
            if (err.code === 'EADDRINUSE') {
                console.error(`\n[Server] Port ${selectedPort} is already in use. Kill the existing process (lsof -ti:${selectedPort} | xargs kill) and retry.`);
            }
            setReadiness(false, 'server-error', err.message);
            backgroundDaemon.stop();
            voiceService.shutdown();
            ocrService.terminate().catch(() => { });
            reject(err);
        });
        // Set HTTP timeouts for slow networks/devices — prevent connection starvation
        server.timeout = 2 * 60 * 1000;        // 2 min for request processing
        server.keepAliveTimeout = 65 * 1000;    // Slightly above typical LB idle timeout (60s)
        server.headersTimeout = 70 * 1000;      // Must be > keepAliveTimeout

        server.listen(selectedPort, async () => {
            new WebSocketManager(server, agentService, deviceProvider, llmService, voiceService, sessionService);
            setReadiness(true, 'serving', `Listening on port ${selectedPort}`);
            console.log(`\n Dashboard running at http://localhost:${selectedPort}`);
            if (effectiveOpenBrowser) {
                try {
                    await open(`http://localhost:${selectedPort}`);
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    console.warn(`[Server] Failed to auto-open browser: ${message}`);
                }
            }
            resolve();
        });
    });
}
