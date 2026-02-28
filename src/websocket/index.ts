import { WebSocketServer, WebSocket } from 'ws';
import { Server } from 'http';
import { AgentService, AgentEventEmitter } from '../services/agent.service.js';
import { IDeviceProvider } from '../types/index.js';
import { LlmService } from '../services/llm.service.js';
import { VoiceService } from '../services/voice.service.js';
import { ALLOWED_CONTEXT_SIZES } from '../constants.js';
import { classifyIntent } from '../services/intentClassifier.js';
import { getHardwareProfile } from '../utils/hardware.js';
import logger from '../utils/logger.js';

/** Max length for user-supplied goal text (prevents DoS via mega-strings) */
const MAX_GOAL_LENGTH = 4000;
/** Max length for a single chat message */
const MAX_CHAT_LENGTH = 8000;

export class WebSocketManager {
    private wss: WebSocketServer;
    private activeWs: WebSocket | null = null;
    // Store active listener refs so we can clean them up on a NEW connection
    // even if the old WebSocket's 'close' event never fires (e.g. network drop).
    private activeActionRequiredHandler: ((payload: any) => void) | null = null;
    private activeDownloadProgressHandler: ((payload: any) => void) | null = null;

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
        // Raise max-listeners ceiling to handle reconnection-heavy sessions without Node warnings
        this.llmService.setMaxListeners(30);
        this.voiceService.setMaxListeners(30);
        (this.deviceProvider as any).setMaxListeners?.(30);
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
            const origin = request.headers.origin;
            if (origin && !this.isAllowedLocalOrigin(origin)) {
                console.warn(`[WebSocket] Rejected connection from disallowed origin: ${origin}`);
                ws.close(1008, 'Origin not allowed');
                return;
            }

            logger.log('Frontend connected to WebSocket');

            // If the previous ws never fired 'close' (e.g. browser crash / network drop),
            // we must manually remove its stale listeners before registering new ones.
            if (this.activeActionRequiredHandler) {
                this.deviceProvider.off('action_required', this.activeActionRequiredHandler);
                this.voiceService.off('action_required', this.activeActionRequiredHandler);
                this.llmService.off('action_required', this.activeActionRequiredHandler);
            }
            if (this.activeDownloadProgressHandler) {
                this.llmService.off('model_download_progress', this.activeDownloadProgressHandler);
            }

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

            // Store refs so a future reconnect can remove them if this ws never emits 'close'
            this.activeActionRequiredHandler = pushActionRequired;
            this.activeDownloadProgressHandler = pushModelDownloadProgress;

            this.deviceProvider.on('action_required', pushActionRequired);
            this.voiceService.on('action_required', pushActionRequired);
            this.llmService.on('action_required', pushActionRequired);
            this.llmService.on('model_download_progress', pushModelDownloadProgress);

            ws.on('message', async (message) => {
                try {
                    const data = JSON.parse(message.toString());
                    const isActionRequiredError = (e: any) => {
                        return ['MODEL_MISSING', 'ADB_MISSING', 'ADB_UNAUTHORIZED', 'PICOVOICE_MISSING', 'DESKTOP_PERMISSIONS', 'ENOENT'].includes(e?.code);
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
                            // Streaming tool-call suppression:
                            // The LLM emits <tool_call>...</tool_call> XML mid-stream. Since the regex
                            // needs the full closing tag to match and tokens arrive one-by-one, we
                            // buffer and suppress any <tool_call> block before forwarding to the client.
                            const TOOL_OPEN = '<tool_call>';
                            const TOOL_CLOSE = '</tool_call>';
                            let streamBuf = '';

                            const result = await this.llmService.generalChat(message, (token) => {
                                if (ws.readyState !== WebSocket.OPEN) return;
                                streamBuf += token;

                                // Strip any complete <tool_call>...</tool_call> blocks already in the buffer
                                while (streamBuf.includes(TOOL_CLOSE)) {
                                    const closeIdx = streamBuf.indexOf(TOOL_CLOSE);
                                    const openIdx = streamBuf.lastIndexOf(TOOL_OPEN, closeIdx);
                                    if (openIdx !== -1) {
                                        streamBuf = streamBuf.slice(0, openIdx) + streamBuf.slice(closeIdx + TOOL_CLOSE.length).trimStart();
                                    } else { break; }
                                }

                                // If buffer contains an open <tool_call> with no close yet, hold back from the open tag
                                const openIdx = streamBuf.indexOf(TOOL_OPEN);
                                if (openIdx !== -1) {
                                    const before = streamBuf.slice(0, openIdx);
                                    if (before) ws.send(JSON.stringify({ type: 'chat_stream', text: before }));
                                    streamBuf = streamBuf.slice(openIdx);
                                    return;
                                }

                                // Hold back any partial '<tool_call' prefix at the tail to avoid split-token false negatives
                                for (let len = Math.min(TOOL_OPEN.length - 1, streamBuf.length); len >= 1; len--) {
                                    if (TOOL_OPEN.startsWith(streamBuf.slice(-len))) {
                                        const toSend = streamBuf.slice(0, streamBuf.length - len);
                                        if (toSend) ws.send(JSON.stringify({ type: 'chat_stream', text: toSend }));
                                        streamBuf = streamBuf.slice(streamBuf.length - len);
                                        return;
                                    }
                                }

                                // Nothing suspicious — flush the buffer
                                ws.send(JSON.stringify({ type: 'chat_stream', text: streamBuf }));
                                streamBuf = '';
                            });
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_response', message: result.text, meta: result.meta, intent: intent.intent }));
                        } catch (e: any) {
                            if (isActionRequiredError(e)) {
                                pushActionRequired({
                                    code: e?.code || 'MODEL_MISSING',
                                    title: 'AI Model Missing',
                                    message: 'Download a model to get started. The 1B model works on almost any hardware.',
                                    autoTrigger: 'downloadModel'
                                });
                            } else if (e?.code === 'LLM_TIMEOUT' || e?.code === 'LLM_INIT_TIMEOUT') {
                                const hw = getHardwareProfile();
                                const tierHint = hw.tier === 'embedded'
                                    ? 'Your device is low-powered — this is expected. Try sending a shorter message.'
                                    : hw.tier === 'constrained'
                                    ? 'Your device has limited resources. Close other apps and retry.'
                                    : 'Close memory-heavy apps and retry.';
                                ws.send(JSON.stringify({
                                    type: 'error',
                                    message: `**AI Took Too Long To Respond**\nThe local model timed out while preparing a reply.\n\n${tierHint}\n\nIf it persists, restart Quenderin.`
                                }));
                            } else {
                                const hw = getHardwareProfile();
                                const ramHint = hw.tier === 'embedded' || hw.tier === 'constrained'
                                    ? 'On low-powered devices, try the 1B model with Eco context (512 tokens, or 256 on embedded devices).'
                                    : `Check your computer has available RAM (${hw.totalRamGb.toFixed(0)}GB total).`;
                                ws.send(JSON.stringify({ type: 'error', message: `**AI Processing Failed**\nThe local language model failed to generate a response.\n\n1. ${ramHint}\n2. Restart the backend server (\`npm run dev\`).\n3. Try sending your message again.` }));
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
                // Clear instance refs so we don't double-remove on the next connection
                if (this.activeActionRequiredHandler === pushActionRequired) {
                    this.activeActionRequiredHandler = null;
                }
                if (this.activeDownloadProgressHandler === pushModelDownloadProgress) {
                    this.activeDownloadProgressHandler = null;
                }
            });
        });
    }
}
