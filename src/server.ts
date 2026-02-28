import { createServer } from 'http';
import net from 'net';
import open from 'open';
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
import { setHealthLlmService } from './routes/health.js';

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
    const selectedPort = await findAvailablePort(port);
    if (selectedPort !== port) {
        console.warn(`[Server] Port ${port} is busy, starting on port ${selectedPort} instead.`);
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
    const app = createApp(metricsService, agentService, llmService);
    const server = createServer(app);

    // 3. Graceful shutdown handlers
    const shutdown = () => {
        console.log('\n[System] Shutting down gracefully...');
        backgroundDaemon.stop();
        voiceService.shutdown();
        ocrService.terminate().catch(() => { });
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
            backgroundDaemon.stop();
            voiceService.shutdown();
            ocrService.terminate().catch(() => { });
            reject(err);
        });
        server.listen(selectedPort, async () => {
            new WebSocketManager(server, agentService, deviceProvider, llmService, voiceService);
            console.log(`\n Dashboard running at http://localhost:${selectedPort}`);
            if (openBrowser) {
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
