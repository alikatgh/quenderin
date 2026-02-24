import express, { Express } from 'express';
import cors from 'cors';
import path from 'path';
import * as fs from 'fs/promises';
import * as os from 'os';
import { fileURLToPath } from 'url';
import healthRoute from './routes/health.js';
import docsRoute from './routes/docs.js';
import { errorHandler } from './middlewares/errorHandler.js';
import { MetricsService } from './services/metrics.service.js';
import { AgentService } from './services/agent.service.js';
import { LlmService } from './services/llm.service.js';

export function createApp(metricsService?: MetricsService, agentService?: AgentService, llmService?: LlmService): Express {
    const app = express();

    app.use((req, res, next) => {
        res.setHeader(
            'Content-Security-Policy',
            "default-src 'self'; connect-src 'self' http://localhost:* ws://localhost:*; img-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:;"
        );
        next();
    });
    app.use(cors());
    app.use(express.json());

    // Serve strictly static frontend relative to this file to support packaged ASARs
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = path.dirname(__filename);

    // If running compiled from /dist/src/app.js we go up 2 levels. If running raw from /src/app.ts we go up 1 level.
    const isCompiledMode = __filename.includes('/dist/') || __filename.includes('\\dist\\');
    const publicPath = isCompiledMode
        ? path.join(__dirname, '..', '..', 'public')
        : path.join(__dirname, '..', 'public');

    app.use(express.static(publicPath));

    // Routes
    app.use('/', healthRoute);
    app.use('/api/docs', docsRoute);

    if (metricsService) {
        app.get('/api/metrics', async (req, res) => {
            try {
                const metrics = await metricsService.getMetrics();
                res.json(metrics);
            } catch (err) {
                res.status(500).json({ error: 'Failed to fetch metrics' });
            }
        });
    }

    if (agentService) {
        app.post('/api/agent/intervene', (req, res) => {
            agentService.pause();
            res.json({ message: "Agent loop paused for manual intervention." });
        });

        app.post('/api/agent/resume', (req, res) => {
            const { manualAction } = req.body;
            agentService.resume(manualAction);
            res.json({ message: "Agent loop resumed.", manualAction });
        });
    }

    app.post('/api/config/voice', async (req, res) => {
        try {
            const { key } = req.body;
            if (!key || typeof key !== 'string') {
                return res.status(400).json({ error: 'Valid key required' });
            }

            const envPath = path.join(os.homedir(), '.quenderin', '.env');
            await fs.mkdir(path.dirname(envPath), { recursive: true });
            await fs.appendFile(envPath, `\nPICOVOICE_ACCESS_KEY=${key}\n`);

            res.json({ success: true, message: 'Voice key saved to config' });
        } catch (error) {
            console.error('Failed to save voice config:', error);
            res.status(500).json({ error: 'Failed to save configuration' });
        }
    });

    if (llmService) {
        app.post('/api/models/download', (req, res) => {
            llmService.downloadModel().catch(e => console.error("Background model download failed:", e));
            res.json({ message: "Model download initiated." });
        });
    }

    // Error Handling
    app.use(errorHandler);

    return app;
}
