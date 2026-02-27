import { createServer } from 'http';
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

export async function startDashboardServer(port: number = 3000, openBrowser: boolean = true): Promise<void> {
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

    // 3. Initialize WebSockets
    new WebSocketManager(server, agentService, deviceProvider, llmService, voiceService);

    // 4. Graceful shutdown handlers
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

    // 5. Boot Server
    return new Promise<void>((resolve, reject) => {
        server.once('error', (err: NodeJS.ErrnoException) => {
            if (err.code === 'EADDRINUSE') {
                console.error(`\n[Server] Port ${port} is already in use. Kill the existing process (lsof -ti:${port} | xargs kill) and retry.`);
            }
            reject(err);
        });
        server.listen(port, async () => {
            console.log(`\n Dashboard running at http://localhost:${port}`);
            if (openBrowser) {
                await open(`http://localhost:${port}`);
            }
            resolve();
        });
    });
}
