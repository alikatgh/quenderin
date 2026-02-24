import { WebSocketServer, WebSocket } from 'ws';
import { Server } from 'http';
import { AgentService, AgentEventEmitter } from '../services/agent.service.js';
import { AdbService } from '../services/adb.service.js';
import { LlmService } from '../services/llm.service.js';

export class WebSocketManager {
    private wss: WebSocketServer;
    private activeWs: WebSocket | null = null;

    constructor(
        server: Server,
        private agentService: AgentService,
        private adbService: AdbService,
        private llmService: LlmService
    ) {
        this.wss = new WebSocketServer({ server });
        this.setupConnection();
    }

    private setupConnection() {
        this.wss.on('connection', (ws) => {
            console.log('Frontend connected to WebSocket');
            this.activeWs = ws;

            ws.send(JSON.stringify({ type: 'log', message: 'Connected to Agent Core.' }));

            ws.on('message', async (message) => {
                try {
                    const data = JSON.parse(message.toString());
                    if (data.type === 'start') {
                        const deviceReady = await this.adbService.checkDevice();
                        if (!deviceReady) {
                            ws.send(JSON.stringify({ type: 'error', message: "No Android device/emulator found. Please start one and try again." }));
                            return;
                        }

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

                        try {
                            await this.agentService.runAgentLoop(data.goal, data.steps || 20, emitter);
                        } catch (e: any) {
                            ws.send(JSON.stringify({ type: 'error', message: `Fatal Loop Error: ${e.message}` }));
                        }
                    } else if (data.type === 'chat') {
                        // General Chat Flow
                        ws.send(JSON.stringify({ type: 'status', message: `Thinking...` }));
                        try {
                            const response = await this.llmService.generalChat(data.message);
                            ws.send(JSON.stringify({ type: 'chat_response', message: response }));
                        } catch (e: any) {
                            ws.send(JSON.stringify({ type: 'error', message: `Chat Error: ${e.message}` }));
                        }
                    }
                } catch (err) {
                    console.error("Failed to parse ws message", err);
                }
            });

            ws.on('close', () => {
                if (this.activeWs === ws) this.activeWs = null;
            });
        });
    }
}
