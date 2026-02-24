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

    private setupConnection() {
        this.wss.on('connection', (ws) => {
            console.log('Frontend connected to WebSocket');
            this.activeWs = ws;

            ws.send(JSON.stringify({ type: 'log', message: 'Connected to Agent Core.' }));

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
                        return ['MODEL_MISSING', 'ADB_MISSING', 'ADB_UNAUTHORIZED', 'PICOVOICE_MISSING', 'DESKTOP_PERMISSIONS', 'ENOENT'].includes(e?.code);
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
                            await this.agentService.runAgentLoop(data.goal, data.steps || 20, emitter);
                        } catch (e: any) {
                            if (!isActionRequiredError(e)) {
                                ws.send(JSON.stringify({ type: 'error', message: `Fatal Loop Error: ${e.message}` }));
                            }
                        }
                    } else if (data.type === 'chat') {
                        // General Chat Flow
                        ws.send(JSON.stringify({ type: 'status', message: `Thinking...` }));
                        try {
                            const response = await this.llmService.generalChat(data.message);
                            ws.send(JSON.stringify({ type: 'chat_response', message: response }));
                        } catch (e: any) {
                            if (isActionRequiredError(e)) {
                                pushActionRequired({
                                    code: e?.code || 'MODEL_MISSING',
                                    title: 'AI Model Missing',
                                    message: 'Quenderin needs its brain to function. The LLaMA instruction-tuned checkpoint is absent.',
                                    autoTrigger: 'downloadModel'
                                });
                            } else {
                                ws.send(JSON.stringify({ type: 'error', message: `Chat Error: ${e.message}` }));
                            }
                        }
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
