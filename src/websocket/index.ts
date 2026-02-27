import { WebSocketServer, WebSocket } from 'ws';
import { Server } from 'http';
import { AgentService, AgentEventEmitter } from '../services/agent.service.js';
import { IDeviceProvider } from '../types/index.js';
import { LlmService } from '../services/llm.service.js';
import { VoiceService } from '../services/voice.service.js';

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

            console.log('Frontend connected to WebSocket');
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
                        // Device ready check removed as IDeviceProvider abstracts this connection natively
                        ws.send(JSON.stringify({ type: 'status', message: `Initializing agent goal: ${data.goal}` }));

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
                            await this.agentService.runAgentLoop(data.goal, data.emitter || emitter, data.attachments || []);
                        } catch (e: any) {
                            if (!isActionRequiredError(e)) {
                                ws.send(JSON.stringify({ type: 'error', message: `**Unexpected System Issue**\nThe agent engine encountered a critical issue. To restore functionality:\n1. Go to your terminal where Quenderin is running.\n2. Press \`Ctrl+C\` to stop the server.\n3. Type \`npm run dev\` and press Enter to restart it.` }));
                            }
                        }
                    } else if (data.type === 'chat') {
                        // General Chat Flow
                        ws.send(JSON.stringify({ type: 'status', message: `Thinking...` }));
                        try {
                            const response = await this.llmService.generalChat(data.message, (token) => {
                                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_stream', text: token }));
                            });
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_response', message: response }));
                        } catch (e: any) {
                            if (isActionRequiredError(e)) {
                                if (e?.code !== 'OOM_PREVENTION') { // OOM_PREVENTION payload already sent by llmService
                                    pushActionRequired({
                                        code: e?.code || 'MODEL_MISSING',
                                        title: 'AI Model Missing',
                                        message: 'Quenderin needs its brain to function. The LLaMA instruction-tuned checkpoint is absent.',
                                        autoTrigger: 'downloadModel'
                                    });
                                }
                            } else {
                                ws.send(JSON.stringify({ type: 'error', message: `**AI Processing Failed**\nThe local language model failed to generate a response. Re-initialize it:\n1. Check your computer's available RAM (needs at least ~5GB free).\n2. Restart the backend server (\`npm run dev\`).\n3. Try sending your message again.` }));
                            }
                        }
                    } else if (data.type === 'settings_update') {
                        this.llmService.updateSettings({
                            contextSize: data.contextSize,
                            memorySafetyEnabled: data.memorySafetyEnabled
                        });
                        console.log(`[System] settings updated: contextSize=${data.contextSize}, memorySafety=${data.memorySafetyEnabled}`);
                    } else if (data.type === 'manual_voice_start') {
                        this.voiceService.manualCaptureStart();
                    } else if (data.type === 'manual_voice_stop') {
                        this.voiceService.manualCaptureStop();
                    }
                } catch (err) {
                    console.error("Failed to parse ws message", err);
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
