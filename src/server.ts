import { createServer } from 'http';
import open from 'open';
import { createApp } from './app.js';
import { WebSocketManager } from './websocket/index.js';
import { AgentService } from './services/agent.service.js';
import { AdbService } from './services/adb.service.js';
import { LlmService } from './services/llm.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';

export function startDashboardServer(port: number = 3000, openBrowser: boolean = true): Promise<void> {
    return new Promise((resolve) => {
        // 1. Dependency Injection / Initialize Services
        const adbService = new AdbService();
        const uiParserService = new UiParserService();
        const llmService = new LlmService();
        const metricsService = new MetricsService();
        const ocrService = new OcrService();
        const memoryService = new MemoryService();
        const agentService = new AgentService(llmService, adbService, uiParserService, metricsService, ocrService, memoryService);

        // 2. Setup Express
        const app = createApp(metricsService, agentService);
        const server = createServer(app);

        // 3. Initialize WebSockets
        new WebSocketManager(server, agentService, adbService, llmService);

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
