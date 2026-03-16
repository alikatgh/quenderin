import express, { Express } from 'express';
import cors from 'cors';
import path from 'path';
import * as fs from 'fs/promises';
import fsSync from 'fs';
import * as os from 'os';
import { fileURLToPath } from 'url';
import healthRoute from './routes/health.js';
import docsRoute from './routes/docs.js';
import { errorHandler } from './middlewares/errorHandler.js';
import { MetricsService } from './services/metrics.service.js';
import { AgentService } from './services/agent.service.js';
import { LlmService } from './services/llm.service.js';
import { MODEL_CATALOG, modelPath as getModelPath, getRecommendedModelIdForTotalRam } from './constants.js';
import { DEFAULT_PRESETS } from './services/presets.js';
import { AVAILABLE_TOOLS } from './services/tools/registry.js';
import { getHardwareProfile } from './utils/hardware.js';

export function createApp(metricsService?: MetricsService, agentService?: AgentService, llmService?: LlmService): Express {
    const app = express();

    const isAllowedLocalOrigin = (origin: string): boolean => {
        if (origin === 'null') return true; // Some embedded/Electron contexts
        try {
            const parsed = new URL(origin);
            return ['localhost', '127.0.0.1', '::1', '[::1]'].includes(parsed.hostname);
        } catch {
            return false;
        }
    };

    app.use((req, res, next) => {
        res.setHeader(
            'Content-Security-Policy',
            "default-src 'self'; connect-src 'self' http://localhost:* ws://localhost:*; img-src 'self' data: blob:; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' data: https://fonts.gstatic.com;"
        );
        next();
    });
    // Restrict CORS to same-machine origins only — this is a local-only server
    app.use(cors({
        origin: (origin, callback) => {
            // Allow requests with no origin (curl, Electron, server-to-server)
            if (!origin) return callback(null, true);
            if (isAllowedLocalOrigin(origin)) return callback(null, true);
            callback(new Error(`CORS: origin '${origin}' is not allowed`));
        }
    }));
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
            } catch {
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


    if (llmService) {
        app.get('/api/models/catalog', (_req, res) => {
            const catalog = MODEL_CATALOG.map((m) => ({
                ...m,
                isDownloaded: fsSync.existsSync(getModelPath(m.id))
            }));
            res.json({ catalog });
        });

        app.post('/api/models/download', (req, res) => {
            const modelId = req.body?.modelId as string | undefined;
            const hw = getHardwareProfile();
            const fallbackModelId = getRecommendedModelIdForTotalRam(hw.totalRamGb);
            const requestedModelId = modelId ?? fallbackModelId;
            llmService.downloadModel(requestedModelId).catch(e => console.error("Background model download failed:", e));
            res.json({ message: "Model download initiated.", modelId: requestedModelId });
        });

        /** Presets catalog — returns all available personas */
        app.get('/api/presets', (_req, res) => {
            res.json({ presets: DEFAULT_PRESETS, activePresetId: llmService.getActivePresetId() });
        });

        /** Available tools catalog */
        app.get('/api/tools', (_req, res) => {
            res.json({ tools: AVAILABLE_TOOLS });
        });
    }

    app.post('/api/voice/download', async (req, res) => {
        try {
            const voiceDir = path.join(os.homedir(), '.quenderin', 'models', 'voice');
            const targetPath = path.join(voiceDir, 'vosk-model-small-en-us-0.15');

            if (await fs.stat(targetPath).catch(() => null)) {
                return res.json({ message: "Voice model already exists.", progress: 100 });
            }

            await fs.mkdir(voiceDir, { recursive: true });

            // Fire and forget the download stream pipeline
            const downloadAndExtract = async (): Promise<void> => {
                const url = 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';
                try {
                    // Timeout for initial connection — 60s should be enough even on slow networks
                    const controller = new AbortController();
                    const fetchTimer = setTimeout(() => controller.abort(), 60_000);
                    let response: Response;
                    try {
                        response = await fetch(url, { signal: controller.signal });
                    } finally {
                        clearTimeout(fetchTimer);
                    }
                    if (!response.ok || !response.body) throw new Error("Failed to download Vosk model");

                    const { default: unzipper } = await import('unzipper');

                    // Consume the Web Stream using Node's stream.Readable
                    const { Readable } = await import('stream');
                    const nodeStream = Readable.fromWeb(response.body as any);

                    nodeStream
                        .pipe(unzipper.Extract({ path: voiceDir }))
                        .on('close', () => console.log('Voice model extracted.'))
                        .on('error', (e) => console.error('Failed to extract voice model:', e));

                } catch (e) {
                    console.error("Voice download pipeline failed:", e);
                }
            };

            downloadAndExtract();
            res.json({ message: "Voice model download initiated." });

        } catch (error) {
            console.error('Failed to init voice download:', error);
            res.status(500).json({ error: 'Failed to init download' });
        }
    });

    // Error Handling
    app.use(errorHandler);

    return app;
}
