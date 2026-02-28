import { WebSocketServer, WebSocket } from 'ws';
import { Server } from 'http';
import { AgentService, AgentEventEmitter } from '../services/agent.service.js';
import { IDeviceProvider } from '../types/index.js';
import { LlmService } from '../services/llm.service.js';
import { VoiceService } from '../services/voice.service.js';
import { ALLOWED_CONTEXT_SIZES, MODEL_CATALOG } from '../constants.js';
import { classifyIntent } from '../services/intentClassifier.js';
import logger from '../utils/logger.js';

/** Max length for user-supplied goal text (prevents DoS via mega-strings) */
const MAX_GOAL_LENGTH = 4000;
/** Max length for a single chat message */
const MAX_CHAT_LENGTH = 8000;

export class WebSocketManager {
    private wss: WebSocketServer;
    private activeWs: WebSocket | null = null;

    constructor(
        server: Server,
        private agentService: AgentService,
        private deviceProvider: IDeviceProvider,
        private llmService: LlmService,
        private voiceService: VoiceService
    ) {
        this.wss = new WebSocketServer({ server });
        this.wss.on('error', (err) => {
            logger.error('[WebSocket] Server error:', err);
        });
        this.setupConnection();
    }

    private isAllowedLocalOrigin(origin: string): boolean {
        if (origin === 'null') return true;
        try {
            const parsed = new URL(origin);
            return ['localhost', '127.0.0.1', '::1', '[::1]'].includes(parsed.hostname);
        } catch {
            return false;
        }
    }

    private setupConnection() {
        this.wss.on('connection', (ws, request) => {
            // Validate origin to block cross-site WebSocket hijacking.
            // Allow connections with no origin header (Electron, curl, etc.).
            const origin = request.headers.origin;
            if (origin && !this.isAllowedLocalOrigin(origin)) {
                console.warn(`[WebSocket] Rejected connection from disallowed origin: ${origin}`);
                ws.close(1008, 'Origin not allowed');
                return;
            }

            logger.log('Frontend connected to WebSocket');
            this.activeWs = ws;

            ws.send(JSON.stringify({ type: 'log', message: 'Connected to Agent Core.' }));

            // Subscriber logic: Re-sync state if backend is already busy
            const { isGenerating, buffer } = this.llmService.isCurrentlyGenerating();
            if (isGenerating) {
                ws.send(JSON.stringify({ type: 'status', message: `Resumed session. AI is currently processing...` }));
                if (buffer) {
                    ws.send(JSON.stringify({ type: 'chat_stream', text: buffer }));
                }
            }

            const pushActionRequired = (payload: any) => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({ type: 'action_required', data: payload }));
                }
            };

            const pushModelDownloadProgress = (payload: any) => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({ type: 'model_download_progress', data: payload }));
                }
            };

            this.deviceProvider.on('action_required', pushActionRequired);
            this.voiceService.on('action_required', pushActionRequired);
            this.llmService.on('action_required', pushActionRequired);
            this.llmService.on('model_download_progress', pushModelDownloadProgress);

            ws.on('message', async (message) => {
                try {
                    const data = JSON.parse(message.toString());
                    const isActionRequiredError = (e: any) => {
                        return ['MODEL_MISSING', 'ADB_MISSING', 'ADB_UNAUTHORIZED', 'PICOVOICE_MISSING', 'DESKTOP_PERMISSIONS', 'ENOENT', 'OOM_PREVENTION'].includes(e?.code);
                    };

                    if (data.type === 'start') {
                        // Validate and sanitize goal input
                        const goal = typeof data.goal === 'string' ? data.goal.slice(0, MAX_GOAL_LENGTH).trim() : '';
                        if (!goal) {
                            ws.send(JSON.stringify({ type: 'error', message: 'Goal is required.' }));
                            return;
                        }
                        ws.send(JSON.stringify({ type: 'status', message: `Initializing agent goal: ${goal}` }));

                        const emitter = new AgentEventEmitter();

                        emitter.on('status', (msg) => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'status', message: msg }));
                        });

                        emitter.on('error', (msg) => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'error', message: msg }));
                        });

                        emitter.on('observe', (elements) => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'observe', elements }));
                        });

                        emitter.on('decide', (command) => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'decide', command }));
                        });

                        emitter.on('action', (msg) => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'action', message: msg }));
                        });

                        emitter.on('done', () => {
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'done' }));
                        });
                        emitter.on('action_required', pushActionRequired);

                        try {
                            // SECURITY: Never use client-supplied emitter — always use server-side one
                            await this.agentService.runAgentLoop(goal, emitter, data.attachments || []);
                        } catch (e: any) {
                            if (!isActionRequiredError(e)) {
                                ws.send(JSON.stringify({ type: 'error', message: `**Unexpected System Issue**\nThe agent engine encountered a critical issue. To restore functionality:\n1. Go to your terminal where Quenderin is running.\n2. Press \`Ctrl+C\` to stop the server.\n3. Type \`npm run dev\` and press Enter to restart it.` }));
                            }
                        }
                    } else if (data.type === 'chat') {
                        // Validate chat input
                        const message = typeof data.message === 'string' ? data.message.slice(0, MAX_CHAT_LENGTH).trim() : '';
                        if (!message) {
                            ws.send(JSON.stringify({ type: 'error', message: 'Message is required.' }));
                            return;
                        }

                        // Classify intent so the UI can display routing info
                        const intent = classifyIntent(message);
                        ws.send(JSON.stringify({ type: 'status', message: `Thinking...` }));
                        try {
                            const result = await this.llmService.generalChat(message, (token) => {
                                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_stream', text: token }));
                            });
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_response', message: result.text, meta: result.meta, intent: intent.intent }));
                        } catch (e: any) {
                            if (isActionRequiredError(e)) {
                                if (e?.code === 'OOM_PREVENTION') {
                                    // Fallback: always notify UI here as well to prevent silent "Thinking..." hangs.
                                    pushActionRequired({
                                        code: 'OOM_PREVENTION',
                                        title: 'Not Enough Free RAM',
                                        message: e?.message || 'None of your downloaded models fit safely in available memory. Try a smaller model or close some apps.',
                                        autoTrigger: null,
                                        downloadedModels: e?.downloadedModels || [],
                                        allModels: MODEL_CATALOG
                                    });
                                } else {
                                    pushActionRequired({
                                        code: e?.code || 'MODEL_MISSING',
                                        title: 'AI Model Missing',
                                        message: 'Quenderin needs its brain to function. The LLaMA instruction-tuned checkpoint is absent.',
                                        autoTrigger: 'downloadModel'
                                    });
                                }
                            } else if (e?.code === 'LLM_TIMEOUT' || e?.code === 'LLM_INIT_TIMEOUT') {
                                ws.send(JSON.stringify({
                                    type: 'error',
                                    message: `**AI Took Too Long To Respond**\nThe local model timed out while preparing a reply.\n\nTry this:\n1. Click **System Settings** and reduce context size to 1024.\n2. Close memory-heavy apps and retry.\n3. If it persists, restart Quenderin.`
                                }));
                            } else {
                                ws.send(JSON.stringify({ type: 'error', message: `**AI Processing Failed**\nThe local language model failed to generate a response. Re-initialize it:\n1. Check your computer's available RAM (needs at least ~5GB free).\n2. Restart the backend server (\`npm run dev\`).\n3. Try sending your message again.` }));
                            }
                        }
                    } else if (data.type === 'settings_update') {
                        // Validate settings to prevent DoS (e.g. contextSize: 999999999)
                        const contextSize = ALLOWED_CONTEXT_SIZES.includes(data.contextSize) ? data.contextSize : 2048;
                        const memorySafetyEnabled = data.memorySafetyEnabled === true;
                        this.llmService.updateSettings({ contextSize, memorySafetyEnabled });
                        logger.log(`[System] settings updated: contextSize=${contextSize}, memorySafety=${memorySafetyEnabled}`);
                    } else if (data.type === 'preset_switch') {
                        // Switch active preset (persona)
                        const presetId = typeof data.presetId === 'string' ? data.presetId.slice(0, 50).trim() : '';
                        if (presetId) {
                            this.llmService.setPreset(presetId);
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'preset_changed', presetId }));
                            }
                        }
                    } else if (data.type === 'manual_voice_start') {
                        this.voiceService.manualCaptureStart();
                    } else if (data.type === 'manual_voice_stop') {
                        this.voiceService.manualCaptureStop();
                    }
                } catch (err) {
                    logger.error("Failed to parse ws message", err);
                }
            });

            ws.on('close', () => {
                if (this.activeWs === ws) this.activeWs = null;
                this.deviceProvider.off('action_required', pushActionRequired);
                this.voiceService.off('action_required', pushActionRequired);
                this.llmService.off('action_required', pushActionRequired);
                this.llmService.off('model_download_progress', pushModelDownloadProgress);
            });
        });
    }
}
