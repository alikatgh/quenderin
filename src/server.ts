import { createServer } from 'http';
import net from 'net';
import open from 'open';
import fs from 'fs/promises';
import fsSync from 'fs';
import path from 'path';
import os from 'os';
import { createApp } from './app.js';
import { WebSocketManager } from './websocket/index.js';
import { generateAuthToken } from './security/authToken.js';
import { AgentService } from './services/agent.service.js';
import { AgentEventEmitter } from './services/agent.service.js';
import { redactSecrets } from './services/capability/redaction.js';
import { DashboardTaskService } from './services/capability/dashboardTasks.js';
import { createGovernedAgent } from './services/capability/desktopAgent.js';
import { InMemoryConsentStore } from './services/capability/capability.js';
import { OsascriptAutomation } from './services/capability/macAutomation.js';
import { OsascriptMacUi } from './services/capability/macUi.js';
import { macCapabilities } from './services/capability/macCapabilities.js';
import { macUiCapabilities } from './services/capability/macUiCapabilities.js';
import { fileCapabilities } from './services/capability/fileCapabilities.js';
import { FileAuditLedger, loadSkillMemory, saveSkillMemory } from './services/capability/persistence.js';
import { ExecFileRunner } from './services/capability/platformAutomation.js';
import { platformCapabilities } from './services/capability/platformCapabilities.js';
import { AndroidProvider } from './services/providers/android.provider.js';
import { DesktopProvider } from './services/providers/desktop.provider.js';
import { BackgroundDaemonService } from './services/backgroundDaemon.service.js';
import { VoiceService } from './services/voice.service.js';
import { LlmService } from './services/llm.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService, setSharedMemoryService } from './services/memory.service.js';
import { SessionService } from './services/session.service.js';
import { setHealthLlmService } from './routes/health.js';
import { resetReadinessForStartup, setReadiness } from './services/readiness.service.js';
import logger from './utils/logger.js';
import { TEMP_FILE_MAX_AGE_MS, TEMP_CLEANUP_INTERVAL_MS } from './constants.js';

// Bind to loopback only by default — this is a local dashboard/agent that controls the
// machine and a connected device, so it must not be reachable from the LAN. Set
// QUENDERIN_HOST=0.0.0.0 to deliberately expose it (e.g. trusted dev network).
const BIND_HOST = process.env.QUENDERIN_HOST || '127.0.0.1';

// Global safety net — log unhandled rejections instead of crashing silently
process.on('unhandledRejection', (reason) => {
    logger.error('[Process] Unhandled promise rejection:', reason);
});
process.on('uncaughtException', (err) => {
    logger.critical('[Process] Uncaught exception — shutting down:', err.message);
    // r39 (from r18): leave a durable artifact — the terminal is gone after an Electron relaunch,
    // so the critical log line alone vanishes with the process. Sync append, best-effort.
    try {
        const crashLine = `${new Date().toISOString()} uncaughtException: ${err.stack ?? err.message}\n`;
        fsSync.appendFileSync(path.join(os.homedir(), '.quenderin', 'crash.log'), crashLine);
    } catch { /* the crash path must never throw */ }
    process.exit(1);
});

/**
 * Periodically clean up orphaned Quenderin temp files (screenshots, WAV recordings)
 * to prevent /tmp from filling up on devices with small storage.
 */
async function cleanupOrphanedTempFiles(): Promise<void> {
    try {
        const tmpDir = os.tmpdir();
        const entries = await fs.readdir(tmpDir);
        const now = Date.now();
        const maxAgeMs = TEMP_FILE_MAX_AGE_MS;

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
            .listen(port, BIND_HOST);
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

export async function startDashboardServer(port: number = 3000, openBrowser: boolean = true): Promise<{ port: number; authToken: string }> {
    resetReadinessForStartup('Dashboard startup initiated');
    setReadiness(false, 'initializing-services', 'Initializing core services');

    // Per-launch auth token (audit HIGH #1) — required on the WS upgrade + state-changing routes,
    // and handed only to the trusted renderer (Electron preload / the CLI's opened URL).
    const authToken = generateAuthToken();

    const selectedPort = await findAvailablePort(port);
    if (selectedPort !== port) {
        logger.warn(`[Server] Port ${port} is busy, starting on port ${selectedPort} instead.`);
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
        logger.info(`[Server] Browser auto-open disabled (${reason}).`);
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
    setSharedMemoryService(memoryService);
    const agentService = new AgentService(llmService, deviceProvider, uiParserService, metricsService, ocrService, memoryService);
    const backgroundDaemon = new BackgroundDaemonService(deviceProvider, metricsService);
    const voiceService = new VoiceService();
    const sessionService = new SessionService();

    // The GOVERNED task agent behind the dashboard — the same assembly as the CLI's
    // `quenderin do` (createGovernedAgent over the real LlmService + osascript seams), with the
    // renderer's dialog as the approver. Consent mirrors the CLI: the capabilities in play are
    // granted because the PER-RUN approval is the real gate; skill memory is shared and persisted
    // after each run so the agent improves across tasks and relaunches.
    const skillMemory = loadSkillMemory();
    const taskService = new DashboardTaskService((deps) => {
        const mac = new OsascriptAutomation();
        const macAvailable = mac.available();
        // Windows/Linux OS automation — the same governed tasks on every desktop OS (the mission).
        const shell = new ExecFileRunner();
        const workspaceDir = deps.workspace;
        const consent = new InMemoryConsentStore();
        if (macAvailable) macCapabilities(mac).forEach(c => consent.setGranted(c.name, true));
        if (shell.available()) platformCapabilities(shell).forEach(c => consent.setGranted(c.name, true));
        if (workspaceDir) fileCapabilities(() => workspaceDir).forEach(c => consent.setGranted(c.name, true));
        const macUi = deps.gui && macAvailable ? new OsascriptMacUi(mac) : undefined;
        if (macUi) macUiCapabilities(macUi).forEach(c => consent.setGranted(c.name, true));
        return createGovernedAgent({
            llm: llmService,
            mac: macAvailable ? mac : undefined,
            macUi,
            shell: shell.available() ? shell : undefined,
            workspace: workspaceDir ? () => workspaceDir : undefined,
            consent,
            approve: deps.approve,
            signal: deps.signal,
            ledger: new FileAuditLedger(),
            memory: skillMemory,
            dryRun: deps.dryRun,
        });
    });
    taskService.on('finished', () => saveSkillMemory(skillMemory));

    // Wire LlmService into /health so it reports the real loaded model
    setHealthLlmService(llmService);

    // Start background passive observation
    backgroundDaemon.on('error', (e) => logger.warn(`[Background Observer] ${e}`));
    backgroundDaemon.start();

    // Boot Voice Control — pipe spoken commands into the agent with the correct signature
    voiceService.on('error', (e) => logger.warn(`[Voice Control] ${e}`));
    voiceService.on('command', (spokenCommand: string) => {
        // Q-357: don't persist a spoken credential in the log — redactSecrets masks secret shapes
        // (the agent loop redacts the same goal again at its own mission-start log).
        logger.info(`[Voice Trigger] Executing objective: "${redactSecrets(spokenCommand)}"`);
        agentService.runAgentLoop(spokenCommand, new AgentEventEmitter(), [], 20)
            .catch((e) => logger.error(`[Voice Trigger] Agent loop failed for "${spokenCommand}":`, e));
    });
    const picovoiceAccessKey = process.env.PICOVOICE_ACCESS_KEY;
    if (picovoiceAccessKey) {
        await voiceService.initialize(picovoiceAccessKey);
    } else {
        logger.info('[Voice Control] PICOVOICE_ACCESS_KEY not set — voice controls disabled.');
    }

    // 2. Setup Express
    setReadiness(false, 'starting-http-server', `Binding HTTP server on port ${selectedPort}`);
    const app = createApp(metricsService, agentService, llmService, sessionService, memoryService, authToken);
    const server = createServer(app);

    // 2b. Start periodic temp file cleanup (every 30 min)
    const cleanupTimer = setInterval(cleanupOrphanedTempFiles, TEMP_CLEANUP_INTERVAL_MS);
    cleanupTimer.unref();
    // Run once at startup to clean up leftovers from previous crashes
    cleanupOrphanedTempFiles();

    // 3. Graceful shutdown handlers
    const shutdown = () => {
        setReadiness(false, 'shutting-down', 'Shutdown signal received');
        logger.info('[System] Shutting down gracefully...');
        clearInterval(cleanupTimer);
        backgroundDaemon.stop();
        voiceService.shutdown();
        // Q-298/Q-348: flush buffered session writes to disk BEFORE exit. SessionService debounces
        // saves on a timer, so a SIGINT between the last message and the timer firing would drop the
        // tail of the conversation. destroy() does a SYNCHRONOUS flushNow() + clears the timer, so it
        // completes here (unlike the fire-and-forget async teardown below).
        sessionService.destroy();
        // Free the native llama model/context AND the llama engine itself — shutdown() disposes the
        // engine handle that unloadModel() leaves alive, avoiding the ggml-metal atexit assert on a
        // graceful shutdown / in-process restart (Q-145). Fire-and-forget like the other async teardown.
        void Promise.resolve(llmService.shutdown()).catch((e) => logger.debug('[Shutdown] model shutdown error:', e));
        ocrService.terminate().catch((e) => logger.debug('[Shutdown] OCR terminate error:', e));
        // Final cleanup of temp files on shutdown
        cleanupOrphanedTempFiles().catch((e) => logger.debug('[Shutdown] Temp cleanup error:', e));
        server.close(() => {
            logger.info('[System] HTTP server closed.');
            process.exit(0);
        });
        // Force-kill after 10 s if something hangs
        setTimeout(() => process.exit(1), 10_000).unref();
    };
    process.once('SIGTERM', shutdown);
    process.once('SIGINT', shutdown);

    // 4. Boot Server
    return new Promise<{ port: number; authToken: string }>((resolve, reject) => {
        server.once('error', (err: NodeJS.ErrnoException) => {
            if (err.code === 'EADDRINUSE') {
                logger.error(`[Server] Port ${selectedPort} is already in use. Kill the existing process (lsof -ti:${selectedPort} | xargs kill) and retry.`);
            }
            setReadiness(false, 'server-error', err.message);
            backgroundDaemon.stop();
            voiceService.shutdown();
            ocrService.terminate().catch((e) => logger.debug('[Startup] OCR terminate error:', e));
            reject(err);
        });
        // Set HTTP timeouts for slow networks/devices — prevent connection starvation
        server.timeout = 2 * 60 * 1000;        // 2 min for request processing
        server.keepAliveTimeout = 65 * 1000;    // Slightly above typical LB idle timeout (60s)
        server.headersTimeout = 70 * 1000;      // Must be > keepAliveTimeout

        server.listen(selectedPort, BIND_HOST, async () => {
            new WebSocketManager(server, agentService, deviceProvider, llmService, voiceService, sessionService, authToken, taskService);
            setReadiness(true, 'serving', `Listening on ${BIND_HOST}:${selectedPort}`);
            logger.critical(`Dashboard running at http://localhost:${selectedPort}`);
            if (effectiveOpenBrowser) {
                try {
                    // The CLI's browser has no preload — deliver the token via the opened URL (the
                    // renderer reads `?token=` from location.search). A local attacker never sees it.
                    await open(`http://localhost:${selectedPort}/?token=${authToken}`);
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    logger.warn(`[Server] Failed to auto-open browser: ${message}`);
                    logger.critical(`Open this URL manually: http://localhost:${selectedPort}/?token=${authToken}`);
                }
            } else {
                // Without the auto-open, the tokened URL was never communicated AT ALL — the auth
                // is fail-closed, so `--no-open` (or any non-interactive launch) locked the user out
                // of their own dashboard. Printing it to the local terminal is the same exposure as
                // handing it to `open`: both are visible only to the local user.
                logger.critical(`Open this URL to connect: http://localhost:${selectedPort}/?token=${authToken}`);
            }
            resolve({ port: selectedPort, authToken });
        });
    });
}
