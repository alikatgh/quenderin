import { createServer } from 'http';
import open from 'open';
import { createApp } from './app.js';
import { WebSocketManager } from './websocket/index.js';
import { AgentService } from './services/agent.service.js';
import { AndroidProvider } from './services/providers/android.provider.js';
import { DesktopProvider } from './services/providers/desktop.provider.js';
import { BackgroundDaemonService } from './services/backgroundDaemon.service.js';
import { VoiceService } from './services/voice.service.js';
import { LlmService } from './services/llm.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';

export function startDashboardServer(port: number = 3000, openBrowser: boolean = true): Promise<void> {
    return new Promise(async (resolve) => {
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

        // Boot Voice Control
        voiceService.on('error', (e) => console.log(`[Voice Control] ${e}`));
        // Directly pipe parsed spoken commands into physical robotic action
        voiceService.on('command', (spokenCommand: string) => {
            console.log(`\n\n[Voice Trigger] Executing objective: "${spokenCommand}"...`);
            agentService.runAgentLoop(spokenCommand, 20);
        });
        await voiceService.initialize(process.env.PICOVOICE_ACCESS_KEY || '');

        // 2. Setup Express
        const app = createApp(metricsService, agentService, llmService);
        const server = createServer(app);

        // 3. Initialize WebSockets
        new WebSocketManager(server, agentService, deviceProvider, llmService, voiceService);

        // 4. Boot Server
        server.listen(port, async () => {
            console.log(`\n Dashboard running at http://localhost:${port}`);
            if (openBrowser) {
                await open(`http://localhost:${port}`);
            }
            resolve();
        });
    });
}
