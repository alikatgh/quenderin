import express, { Express } from 'express';
import cors from 'cors';
import path from 'path';
import * as fs from 'fs/promises';
import fsSync from 'fs';
import * as os from 'os';
import { MemoryService } from './services/memory.service.js';
import { fileURLToPath } from 'url';
import healthRoute from './routes/health.js';
import docsRoute from './routes/docs.js';
import { errorHandler } from './middlewares/errorHandler.js';
import { MetricsService } from './services/metrics.service.js';
import { AgentService } from './services/agent.service.js';
import { LlmService } from './services/llm.service.js';
import { SessionService } from './services/session.service.js';
import { MODEL_CATALOG, modelPath as getModelPath, getRecommendedModelIdForTotalRam } from './constants.js';
import { DEFAULT_PRESETS } from './services/presets.js';
import { AVAILABLE_TOOLS } from './services/tools/registry.js';
import { getHardwareProfile } from './utils/hardware.js';

/** Pre-built goal templates to help users get started quickly */
const GOAL_TEMPLATES = [
    { id: 'open-app',         category: 'Navigation',    label: 'Open an app',            template: 'Open {app name} on my phone' },
    { id: 'send-message',     category: 'Communication', label: 'Send a message',         template: 'Send a WhatsApp message to {contact}: "{message}"' },
    { id: 'take-screenshot',  category: 'Utility',       label: 'Describe the screen',    template: 'Describe everything you can see on my phone screen right now' },
    { id: 'search-browser',   category: 'Research',      label: 'Search the web',         template: 'Open the browser and search for "{query}"' },
    { id: 'play-music',       category: 'Media',         label: 'Play music',             template: 'Open Spotify and play {song or artist}' },
    { id: 'set-alarm',        category: 'Productivity',  label: 'Set an alarm',           template: 'Set an alarm for {time} tomorrow morning' },
    { id: 'read-notifications', category: 'Utility',     label: 'Read notifications',     template: 'Open my notification panel and read the latest notifications aloud' },
    { id: 'navigate-settings', category: 'Navigation',   label: 'Change a setting',       template: 'Go to Settings and turn on {setting name}' },
];

export function createApp(metricsService?: MetricsService, agentService?: AgentService, llmService?: LlmService, sessionService?: SessionService, memoryService?: MemoryService): Express {
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
        app.get('/api/models/catalog', async (_req, res) => {
            const catalog = await Promise.all(MODEL_CATALOG.map(async (m) => {
                const filePath = getModelPath(m.id);
                const isDownloaded = fsSync.existsSync(filePath);
                let fileSizeBytes = 0;
                if (isDownloaded) {
                    try { fileSizeBytes = (await fs.stat(filePath)).size; } catch { /* non-fatal */ }
                }
                return { ...m, isDownloaded, fileSizeBytes };
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

        /** Delete a downloaded model file */
        app.delete('/api/models/:modelId', async (req, res) => {
            const { modelId } = req.params;
            const entry = MODEL_CATALOG.find(m => m.id === modelId);
            if (!entry) {
                return res.status(404).json({ error: `Unknown model id: ${modelId}` });
            }
            const filePath = getModelPath(entry.id);
            if (!fsSync.existsSync(filePath)) {
                return res.status(404).json({ error: 'Model file not found on disk.' });
            }
            try {
                await fs.unlink(filePath);
                // Also clean up any stale download metadata
                const metaPath = filePath + '.download.json';
                if (fsSync.existsSync(metaPath)) await fs.unlink(metaPath).catch(() => {});
                res.json({ message: `Model ${entry.label} deleted.` });
            } catch (err) {
                console.error('Failed to delete model:', err);
                res.status(500).json({ error: 'Failed to delete model file.' });
            }
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

    /** Goal templates — pre-built automation starters */
    app.get('/api/templates', (_req, res) => {
        res.json({ templates: GOAL_TEMPLATES });
    });

    /** Session API */
    if (sessionService) {
        app.get('/api/sessions', (_req, res) => {
            res.json({ sessions: sessionService.listSessions() });
        });

        app.get('/api/sessions/:id', (req, res) => {
            const session = sessionService.loadSession(req.params.id);
            if (!session) return res.status(404).json({ error: 'Session not found.' });
            res.json(session);
        });

        app.delete('/api/sessions/:id', (req, res) => {
            const deleted = sessionService.deleteSession(req.params.id);
            if (!deleted) return res.status(404).json({ error: 'Session not found.' });
            res.json({ message: 'Session deleted.' });
        });

        app.get('/api/sessions/:id/export', (req, res) => {
            const md = sessionService.exportMarkdown(req.params.id);
            if (!md) return res.status(404).json({ error: 'Session not found.' });
            const safeId = req.params.id.replace(/[^a-zA-Z0-9\-_]/g, '').slice(0, 20);
            res.setHeader('Content-Type', 'text/markdown; charset=utf-8');
            res.setHeader('Content-Disposition', `attachment; filename="quenderin-session-${safeId}.md"`);
            res.send(md);
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

    /** Notes API — browse/delete notes written by the note_save tool */
    const NOTES_DIR = path.join(os.homedir(), '.quenderin', 'notes');

    app.get('/api/notes', async (_req, res) => {
        try {
            await fs.mkdir(NOTES_DIR, { recursive: true });
            const files = await fs.readdir(NOTES_DIR);
            const notes = await Promise.all(
                files.filter(f => f.endsWith('.md')).map(async (file) => {
                    const filePath = path.join(NOTES_DIR, file);
                    const stat = await fs.stat(filePath);
                    const content = await fs.readFile(filePath, 'utf-8').catch(() => '');
                    const preview = content.split('\n').slice(0, 3).join(' ').slice(0, 200);
                    return {
                        filename: file,
                        title: file.replace(/\.md$/, '').replace(/_/g, ' '),
                        preview,
                        modifiedAt: stat.mtimeMs,
                        sizeBytes: stat.size,
                    };
                })
            );
            notes.sort((a, b) => b.modifiedAt - a.modifiedAt);
            res.json({ notes });
        } catch {
            res.status(500).json({ error: 'Failed to list notes' });
        }
    });

    app.get('/api/notes/:filename', async (req, res) => {
        const safe = path.basename(req.params.filename);
        if (!safe.endsWith('.md')) return res.status(400).json({ error: 'Invalid filename' });
        const filePath = path.join(NOTES_DIR, safe);
        try {
            const content = await fs.readFile(filePath, 'utf-8');
            res.setHeader('Content-Type', 'text/markdown; charset=utf-8');
            res.send(content);
        } catch {
            res.status(404).json({ error: 'Note not found' });
        }
    });

    app.delete('/api/notes/:filename', async (req, res) => {
        const safe = path.basename(req.params.filename);
        if (!safe.endsWith('.md')) return res.status(400).json({ error: 'Invalid filename' });
        const filePath = path.join(NOTES_DIR, safe);
        try {
            await fs.unlink(filePath);
            res.json({ message: 'Note deleted.' });
        } catch {
            res.status(404).json({ error: 'Note not found' });
        }
    });

    /** Agent Memory API — recent learned trajectories */
    if (memoryService) {
        app.get('/api/memory/trajectories', async (_req, res) => {
            try {
                const memPath = path.join(os.homedir(), '.quenderin', 'memory.json');
                const raw = await fs.readFile(memPath, 'utf-8').catch(() => '[]');
                const records = JSON.parse(raw);
                // Return last 20, newest first, without full action arrays for brevity
                const summary = [...records].reverse().slice(0, 20).map((r: any) => ({
                    goal: r.goal,
                    actionCount: r.actions?.length ?? 0,
                    timestamp: r.timestamp,
                }));
                res.json({ trajectories: summary, total: records.length });
            } catch {
                res.status(500).json({ error: 'Failed to read memory' });
            }
        });

        app.delete('/api/memory/trajectories', async (_req, res) => {
            try {
                const memPath = path.join(os.homedir(), '.quenderin', 'memory.json');
                await fs.writeFile(memPath, '[]', 'utf-8');
                res.json({ message: 'Agent memory cleared.' });
            } catch {
                res.status(500).json({ error: 'Failed to clear memory' });
            }
        });
    }

    // Error Handling
    app.use(errorHandler);

    return app;
}
