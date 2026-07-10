import { WebSocketServer, WebSocket } from 'ws';
import { Server } from 'http';
import { AgentService, AgentEventEmitter } from '../services/agent.service.js';
import { IDeviceProvider } from '../types/index.js';
import { LlmService } from '../services/llm.service.js';
import { VoiceService } from '../services/voice.service.js';
import { composeChatMessage } from '../utils/chatCompose.js';
import { sanitizeManualAction } from '../utils/agentControl.js';
import { SessionService } from '../services/session.service.js';
import { ALLOWED_CONTEXT_SIZES, MAX_GOAL_LENGTH, MAX_CHAT_LENGTH, MAX_SEND_BUFFER_BYTES, MAX_ATTACHMENTS, MAX_ATTACHMENT_SIZE, WS_HEARTBEAT_INTERVAL_MS } from '../constants.js';
import { classifyIntent } from '../services/intentClassifier.js';
import { getHardwareProfile } from '../utils/hardware.js';
import logger from '../utils/logger.js';
import { extractWsToken, isAuthorized } from '../security/authToken.js';
import { DashboardTaskService, TaskApprovalRequest } from '../services/capability/dashboardTasks.js';

/** Validate and sanitize attachment arrays from WebSocket messages */
function sanitizeAttachments(raw: unknown): { name: string; content: string }[] {
    if (!Array.isArray(raw)) return [];
    const result: { name: string; content: string }[] = [];
    for (const item of raw.slice(0, MAX_ATTACHMENTS)) {
        if (typeof item !== 'object' || item === null) continue;
        const name = typeof (item as any).name === 'string' ? (item as any).name.slice(0, 255) : '';
        const content = typeof (item as any).content === 'string' ? (item as any).content.slice(0, MAX_ATTACHMENT_SIZE) : '';
        if (name && content) {
            result.push({ name, content });
        }
    }
    return result;
}

/**
 * A WebSocket connection is accepted only from a LOCAL browser origin, and a MISSING Origin header
 * is rejected (audit HIGH #2). The literal "null" origin (sandboxed iframes, file://) fails the URL
 * hostname check, so it's rejected too.
 *
 * NOTE: an Origin header is trivially spoofable by a non-browser client, so this is NOT real
 * authentication — it only removes the trivial "omit Origin → full access" path. The complete fix is
 * a per-launch token required on the WS upgrade (audit HIGH #1), which needs the running renderer to
 * verify end-to-end and is tracked separately.
 */
export function isAllowedLocalWsOrigin(origin: string | undefined): boolean {
    if (!origin) return false;
    try {
        const parsed = new URL(origin);
        return ['localhost', '127.0.0.1', '::1', '[::1]'].includes(parsed.hostname);
    } catch {
        return false;
    }
}

export class WebSocketManager {
    private wss: WebSocketServer;
    private activeWs: WebSocket | null = null;
    // Store active listener refs so we can clean them up on a NEW connection
    // even if the old WebSocket's 'close' event never fires (e.g. network drop).
    private activeActionRequiredHandler: ((payload: any) => void) | null = null;
    private activeDownloadProgressHandler: ((payload: any) => void) | null = null;
    private activeTaskStepHandler: ((line: string) => void) | null = null;
    private activeTaskApprovalHandler: ((req: TaskApprovalRequest) => void) | null = null;

    /** Throttle for the congestion warning so a slow connection doesn't spam the log per token. */
    private lastCongestionWarnMs = 0;

    /** Send with backpressure check — drops messages when the send buffer is full
     *  to prevent unbounded memory growth on slow connections */
    private safeSend(ws: WebSocket, data: string): void {
        if (ws.readyState !== WebSocket.OPEN) return;
        if (ws.bufferedAmount > MAX_SEND_BUFFER_BYTES) {
            // Q-293: congested — drop this streaming frame to avoid OOM. This is NOT data loss: the
            // final `chat_response` is sent via ws.send() with the COMPLETE text, so a slow client
            // still gets the whole message; only the live token-by-token stream is choppy. But don't
            // drop SILENTLY — log it (throttled) so congestion is observable.
            const now = Date.now();
            if (now - this.lastCongestionWarnMs > 2000) {
                this.lastCongestionWarnMs = now;
                logger.warn(`[WS] Send buffer congested (${ws.bufferedAmount} bytes) — dropping stream frames; the final message is still delivered in full.`);
            }
            return;
        }
        ws.send(data);
    }

    /** Ping/pong heartbeat interval — detects dead connections on slow networks */
    private heartbeatInterval: NodeJS.Timeout | null = null;

    constructor(
        server: Server,
        private agentService: AgentService,
        private deviceProvider: IDeviceProvider,
        private llmService: LlmService,
        private voiceService: VoiceService,
        private sessionService?: SessionService,
        /** Per-launch auth token required on the WS upgrade (audit HIGH #1). Empty ⇒ fail closed
         *  (every connection rejected) — never fail open. */
        private authToken: string = '',
        /** The GOVERNED task agent (createGovernedAgent behind approval/undo seams) — the
         *  dashboard twin of `quenderin do`. Optional so tests of the legacy paths are unchanged. */
        private taskService?: DashboardTaskService
    ) {
        // Restrict the upgrade to /ws — without `path`, ws upgrades ANY HTTP path (H19).
        this.wss = new WebSocketServer({ server, path: '/ws' });
        this.wss.on('error', (err) => {
            logger.error('[WebSocket] Server error:', err);
        });
        // Raise max-listeners ceiling to handle reconnection-heavy sessions without Node warnings
        this.llmService.setMaxListeners(30);
        this.voiceService.setMaxListeners(30);
        (this.deviceProvider as any).setMaxListeners?.(30);
        this.setupConnection();
        this.startHeartbeat();
    }

    /** Periodic ping to all connected clients — terminates unresponsive sockets */
    private startHeartbeat(): void {
        this.heartbeatInterval = setInterval(() => {
            this.wss.clients.forEach((ws: WebSocket & { isAlive?: boolean }) => {
                if (ws.isAlive === false) {
                    // Client didn't respond to last ping — terminate
                    return ws.terminate();
                }
                ws.isAlive = false;
                ws.ping();
            });
        }, WS_HEARTBEAT_INTERVAL_MS);
        this.heartbeatInterval.unref(); // Don't block process exit
    }

    private setupConnection() {
        this.wss.on('connection', (ws, request) => {
            const origin = request.headers.origin;
            // Reject a MISSING Origin too (was previously allowed — audit HIGH #2): browsers always
            // send Origin on a WS handshake from an http(s) page, and the Electron renderer is served
            // over http://localhost, so only a non-browser client (curl, a malicious local process)
            // omits it — which was the most direct exploit path to driving the agent.
            if (!isAllowedLocalWsOrigin(origin)) {
                logger.warn(`[WebSocket] Rejected connection (origin=${origin ?? 'absent'}); a local browser Origin is required`);
                ws.close(1008, 'Origin required');
                return;
            }

            // Per-launch token auth (audit HIGH #1) — the real authentication. An Origin is spoofable;
            // only the trusted renderer (which got the token via the preload / opened URL) has this.
            if (!isAuthorized(extractWsToken(request.url), this.authToken)) {
                logger.warn('[WebSocket] Rejected connection: missing or invalid auth token');
                ws.close(1008, 'Unauthorized');
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
            if (this.taskService) {
                if (this.activeTaskStepHandler) this.taskService.off('step', this.activeTaskStepHandler);
                if (this.activeTaskApprovalHandler) this.taskService.off('approval_request', this.activeTaskApprovalHandler);
            }

            this.activeWs = ws;
            // Mark alive for heartbeat
            (ws as WebSocket & { isAlive?: boolean }).isAlive = true;
            ws.on('pong', () => { (ws as WebSocket & { isAlive?: boolean }).isAlive = true; });
            // r14: a per-SOCKET error (client ECONNRESET mid-write, malformed frame) emits 'error' on
            // the ws — unlistened, EventEmitter rethrows it, and the process-level uncaughtException
            // handler EXITS. One flaky tab could kill the whole local server. Log it; 'close' follows
            // and does the real cleanup.
            ws.on('error', (err) => logger.warn('[WS] socket error (client dropped?):', err.message));

            ws.send(JSON.stringify({ type: 'log', message: 'Connected to Agent Core.' }));

            // Q-596: ADOPT the active session rather than unconditionally starting a new one. Every WS
            // connect (a second tab, a page refresh, a reconnect after a network blip) used to call
            // startSession(), which flushed+abandoned the in-progress session and created an empty one —
            // so the first tab's next message landed in the wrong session (hijack), and a reconnect lost
            // the running conversation. activeSessionId() reuses the current session and only creates one
            // when none exists. Starting a fresh conversation is now an explicit client action ('new_session').
            if (this.sessionService) {
                const sessionId = this.sessionService.activeSessionId();
                ws.send(JSON.stringify({ type: 'session_started', sessionId }));
            }

            // Subscriber logic: Re-sync state if backend is already busy
            const { isGenerating, buffer } = this.llmService.isCurrentlyGenerating();
            if (isGenerating) {
                ws.send(JSON.stringify({ type: 'status', message: `Resumed session. AI is currently processing...` }));
                if (buffer) {
                    ws.send(JSON.stringify({ type: 'chat_stream', text: buffer }));
                }
            }

            const pushActionRequired = (payload: any) => {
                this.safeSend(ws, JSON.stringify({ type: 'action_required', data: payload }));
            };

            const pushModelDownloadProgress = (payload: any) => {
                this.safeSend(ws, JSON.stringify({ type: 'model_download_progress', data: payload }));
            };

            // Store refs so a future reconnect can remove them if this ws never emits 'close'
            this.activeActionRequiredHandler = pushActionRequired;
            this.activeDownloadProgressHandler = pushModelDownloadProgress;

            this.deviceProvider.on('action_required', pushActionRequired);
            this.voiceService.on('action_required', pushActionRequired);
            this.llmService.on('action_required', pushActionRequired);
            this.llmService.on('model_download_progress', pushModelDownloadProgress);

            // The governed task channel: steps stream live; an approval question renders the
            // renderer's dialog. Registered per-connection with the same stale-cleanup discipline
            // as the handlers above, so a dead socket never keeps a question addressed to nobody.
            const pushTaskStep = (line: string) => {
                this.safeSend(ws, JSON.stringify({ type: 'task_step', line }));
            };
            const pushTaskApproval = (req: TaskApprovalRequest) => {
                // NOT safeSend: an approval question must never be silently dropped by backpressure —
                // if the socket is congested/dead the send fails and the close handler declines it.
                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'task_approval_request', ...req }));
            };
            if (this.taskService) {
                this.activeTaskStepHandler = pushTaskStep;
                this.activeTaskApprovalHandler = pushTaskApproval;
                this.taskService.on('step', pushTaskStep);
                this.taskService.on('approval_request', pushTaskApproval);
            }

            ws.on('message', async (message) => {
                try {
                    const data = JSON.parse(message.toString());
                    const getErrorCode = (e: unknown): string | undefined =>
                        e instanceof Error ? (e as NodeJS.ErrnoException).code : undefined;
                    const isActionRequiredError = (e: unknown) => {
                        const code = getErrorCode(e);
                        return code !== undefined && ['MODEL_MISSING', 'ADB_MISSING', 'ADB_UNAUTHORIZED', 'PICOVOICE_MISSING', 'DESKTOP_PERMISSIONS', 'ENOENT'].includes(code);
                    };

                    if (data.type === 'start') {
                        // Validate and sanitize goal input
                        const goal = typeof data.goal === 'string' ? data.goal.slice(0, MAX_GOAL_LENGTH).trim() : '';
                        if (!goal) {
                            ws.send(JSON.stringify({ type: 'error', message: 'Goal is required.' }));
                            return;
                        }
                        // Q-539: reject a concurrent start LOUDLY. runAgentLoop's internal guard silently
                        // ignores a second start, so the client (which optimistically flipped to "running")
                        // was left showing a phantom mission. Tell it plainly instead — no 'done', because
                        // the FIRST mission is still running and must not be marked finished.
                        if (this.agentService.isRunning) {
                            ws.send(JSON.stringify({ type: 'error', message: 'An agent task is already running. Stop it before starting a new one.' }));
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

                        // Q-549 Step 2: the bulk brake is a SERVER-initiated pause, so the client must be
                        // told its pause state changed (agent_paused is otherwise only an ack of a client
                        // 'pause'). Reuses the existing Resume/Stop UI — no new client controls needed.
                        emitter.on('bulk_confirm', () => {
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({
                                    type: 'agent_paused',
                                    isPaused: this.agentService.isPaused,
                                    isRunning: this.agentService.isRunning,
                                }));
                            }
                        });

                        // Q-549 Step 3: when mission approval is enabled, push the request to THIS
                        // client so the dashboard can show Allow / Don't-allow. The agent parks until
                        // mission_approve arrives (or stop_agent fails closed).
                        if (this.agentService.requireMissionApproval) {
                            this.agentService.installWaitingMissionApprover((missionGoal) => {
                                if (ws.readyState === WebSocket.OPEN) {
                                    ws.send(JSON.stringify({
                                        type: 'mission_approval_required',
                                        goal: missionGoal,
                                    }));
                                } else {
                                    // No live client to approve → fail closed immediately.
                                    this.agentService.answerMissionApproval(false);
                                }
                            });
                        }

                        try {
                            // SECURITY: Never use client-supplied emitter — always use server-side one
                            const attachments = sanitizeAttachments(data.attachments);
                            await this.agentService.runAgentLoop(goal, emitter, attachments);
                        } catch (e: unknown) {
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
                        // Q-275: single-flight — a rapid double-send would overlap two generalChat calls
                        // and interleave their session writes. Reject while one is already generating.
                        if (this.llmService.isCurrentlyGenerating().isGenerating) {
                            ws.send(JSON.stringify({ type: 'error', message: 'Still generating the previous reply — please wait.' }));
                            return;
                        }

                        // Q-284: fold any attached documents into what the MODEL sees (the chat path
                        // used to drop them); the clean `message` is still what we persist + classify.
                        const chatAttachments = sanitizeAttachments(data.attachments);
                        const modelInput = composeChatMessage(message, chatAttachments);
                        // Q-286: DON'T persist the user turn yet — if generalChat throws, the session
                        // would keep a user message with no assistant reply (an orphan). Persist both
                        // atomically after success (below).
                        // Classify intent so the UI can display routing info
                        const intent = classifyIntent(message);
                        // Q-596/Q-597: PIN the session this turn belongs to, before the await. A
                        // new_session / activate_session that arrives while generalChat() is streaming
                        // switches the ACTIVE session, so persisting to "current" afterward misfiles the
                        // turn (adversarial-verify P1). addMessageTo writes to the pinned session regardless.
                        const turnSessionId = this.sessionService?.activeSessionId();
                        ws.send(JSON.stringify({ type: 'status', message: `Thinking...` }));
                        try {
                            // Streaming tool-call suppression:
                            // The LLM emits <tool_call>...</tool_call> XML mid-stream. Since the regex
                            // needs the full closing tag to match and tokens arrive one-by-one, we
                            // buffer and suppress any <tool_call> block before forwarding to the client.
                            const TOOL_OPEN = '<tool_call>';
                            const TOOL_CLOSE = '</tool_call>';
                            let streamBuf = '';

                            const result = await this.llmService.generalChat(modelInput, (token) => {
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
                                    if (before) this.safeSend(ws, JSON.stringify({ type: 'chat_stream', text: before }));
                                    streamBuf = streamBuf.slice(openIdx);
                                    return;
                                }

                                // Hold back any partial '<tool_call' prefix at the tail to avoid split-token false negatives
                                for (let len = Math.min(TOOL_OPEN.length - 1, streamBuf.length); len >= 1; len--) {
                                    if (TOOL_OPEN.startsWith(streamBuf.slice(-len))) {
                                        const toSend = streamBuf.slice(0, streamBuf.length - len);
                                        if (toSend) this.safeSend(ws, JSON.stringify({ type: 'chat_stream', text: toSend }));
                                        streamBuf = streamBuf.slice(streamBuf.length - len);
                                        return;
                                    }
                                }

                                // Nothing suspicious — flush the buffer
                                this.safeSend(ws, JSON.stringify({ type: 'chat_stream', text: streamBuf }));
                                streamBuf = '';
                            });
                            // Persist the whole turn now that it succeeded — user THEN assistant, so a
                            // failed generation never leaves an orphaned user turn (Q-286). Q-596/Q-597:
                            // to the PINNED session, not "current" — a mid-generation switch must not
                            // misfile this turn.
                            if (turnSessionId && this.sessionService) {
                                this.sessionService.addMessageTo(turnSessionId, 'user', message);
                                this.sessionService.addMessageTo(turnSessionId, 'assistant', result.text);
                            }
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'chat_response', message: result.text, meta: result.meta, intent: intent.intent }));
                        } catch (e: unknown) {
                            const eCode = getErrorCode(e);
                            if (isActionRequiredError(e)) {
                                pushActionRequired({
                                    code: eCode || 'MODEL_MISSING',
                                    title: 'AI Model Missing',
                                    message: 'Download a model to get started. The 1B model works on almost any hardware.',
                                    autoTrigger: 'downloadModel'
                                });
                            } else if (eCode === 'LLM_TIMEOUT' || eCode === 'LLM_INIT_TIMEOUT') {
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
                        // Q-549 Step 3: durable mission-approval toggle (dashboard Settings /
                        // localStorage). When enabled, the next ACTION mission start installs a
                        // waiting approver over this channel; when disabled, prior no-gate behavior.
                        if (typeof data.missionApprovalEnabled === 'boolean') {
                            this.agentService.setMissionApproval(data.missionApprovalEnabled);
                        }
                        logger.log(`[System] settings updated: contextSize=${contextSize}, memorySafety=${memorySafetyEnabled}, missionApproval=${this.agentService.requireMissionApproval}`);
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
                    } else if (data.type === 'pause' || data.type === 'intervene') {
                        // Q-281: the trust loop's "stop and take over" over the LIVE channel. The agent
                        // event stream already flows down this socket, so pausing here (vs. a separate
                        // HTTP round-trip) lets the UI halt a running run the instant the user reacts to
                        // what they see streaming. `intervene` is the trust-loop framing, `pause` the
                        // plain one — same effect. The step loop checks _isPaused between steps, so an
                        // in-flight step finishes, then the loop parks (Q-152 semantics unchanged).
                        this.agentService.pause();
                        if (ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({
                                type: 'agent_paused',
                                isPaused: this.agentService.isPaused,
                                isRunning: this.agentService.isRunning,
                            }));
                        }
                    } else if (data.type === 'resume') {
                        // Optional human override for the next step — same guard as HTTP /api/agent/resume
                        // (a non-string or a paste-bomb would poison the LLM action-history context).
                        const manualAction = sanitizeManualAction(data.manualAction);
                        this.agentService.resume(manualAction);
                        if (ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({
                                type: 'agent_resumed',
                                manualAction: manualAction ?? null,
                                isPaused: this.agentService.isPaused,
                                isRunning: this.agentService.isRunning,
                            }));
                        }
                    } else if (data.type === 'stop_chat') {
                        // Q-292: cancel the in-flight CHAT generation (distinct from the agent's pause).
                        // The generalChat call in progress resolves with its streamed partial, which the
                        // chat handler ships as the normal chat_response — the client just sees the
                        // stream end early, so no special frame is needed here.
                        this.llmService.requestChatCancel();
                    } else if (data.type === 'stop_agent') {
                        // Q-523: the agent kill switch over the live channel. Distinct from pause (which
                        // parks and can resume) — this hard-stops the running mission: it aborts the
                        // in-flight decode and breaks the loop, which then emits its own 'done'.
                        this.agentService.stop();
                    } else if (data.type === 'mission_approve') {
                        // Q-549 Step 3: answer the per-run mission-approval dialog. FAIL-CLOSED:
                        // anything but approved === true is a NO (same shape as task_approve).
                        this.agentService.answerMissionApproval(data.approved === true);
                    } else if (data.type === 'task_start') {
                        // The governed task path — the dashboard twin of `quenderin do`. Distinct
                        // from the legacy 'start' (the continuous device loop): here a local model
                        // proposes discrete capabilities and every mutation needs the user's yes.
                        if (!this.taskService) {
                            ws.send(JSON.stringify({ type: 'task_error', message: 'Tasks are not available in this build.' }));
                            return;
                        }
                        const goal = typeof data.goal === 'string' ? data.goal.slice(0, MAX_GOAL_LENGTH).trim() : '';
                        if (!goal) {
                            ws.send(JSON.stringify({ type: 'task_error', message: 'A goal is required.' }));
                            return;
                        }
                        const workspace = typeof data.workspace === 'string' && data.workspace.trim()
                            ? data.workspace.trim().slice(0, 1024) : null;
                        try {
                            const result = await this.taskService.start(goal, {
                                workspace,
                                gui: data.gui === true,
                                dryRun: data.dryRun === true,
                            });
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'task_done', ...result }));
                            }
                        } catch (e: unknown) {
                            const msg = e instanceof Error ? e.message : 'The task failed.';
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'task_error', message: msg }));
                            }
                        }
                    } else if (data.type === 'task_approve') {
                        // FAIL-CLOSED shape: anything but approved === true is a NO.
                        if (this.taskService && typeof data.id === 'string') {
                            this.taskService.answer(data.id, data.approved === true);
                        }
                    } else if (data.type === 'task_stop') {
                        this.taskService?.stop();
                    } else if (data.type === 'task_undo') {
                        if (!this.taskService) return;
                        try {
                            const report = await this.taskService.undoLast();
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'task_undone', report }));
                            }
                        } catch (e: unknown) {
                            const msg = e instanceof Error ? e.message : 'Undo failed.';
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'task_error', message: msg }));
                            }
                        }
                    } else if (data.type === 'new_session') {
                        // Q-596: the EXPLICIT "start a fresh conversation" path. Connect now adopts the
                        // active session instead of rolling a new one, so the client asks for a new session
                        // deliberately (the "New Conversation" button) rather than by reconnecting.
                        if (this.sessionService) {
                            const sessionId = this.sessionService.startSession();
                            ws.send(JSON.stringify({ type: 'session_started', sessionId }));
                        }
                    } else if (data.type === 'activate_session') {
                        // Q-597: opening a past conversation must also make it the ACTIVE server session —
                        // otherwise the client shows the old transcript while the next message appends to the
                        // still-current one (wrong conversation). Adopt by id; confirm with session_started so
                        // the client's id stays in sync. Unknown/invalid id → no-op (active session unchanged).
                        if (this.sessionService && typeof data.sessionId === 'string') {
                            const adopted = this.sessionService.activateSession(data.sessionId);
                            if (adopted) ws.send(JSON.stringify({ type: 'session_started', sessionId: adopted.id }));
                        }
                    }
                } catch (err) {
                    // Not only parse failures land here — this guards the whole message handler.
                    logger.error("WS message handling failed", err);
                }
            });

            ws.on('close', () => {
                if (this.activeWs === ws) this.activeWs = null;
                this.deviceProvider.off('action_required', pushActionRequired);
                this.voiceService.off('action_required', pushActionRequired);
                this.llmService.off('action_required', pushActionRequired);
                this.llmService.off('model_download_progress', pushModelDownloadProgress);
                if (this.taskService) {
                    this.taskService.off('step', pushTaskStep);
                    this.taskService.off('approval_request', pushTaskApproval);
                    // FAIL-CLOSED: the renderer that was being asked is gone — its open approval
                    // question is answered NO, so the run can't hang (or be approved by nobody).
                    this.taskService.declinePending();
                }
                // Clear instance refs so we don't double-remove on the next connection
                if (this.activeActionRequiredHandler === pushActionRequired) {
                    this.activeActionRequiredHandler = null;
                }
                if (this.activeDownloadProgressHandler === pushModelDownloadProgress) {
                    this.activeDownloadProgressHandler = null;
                }
                if (this.activeTaskStepHandler === pushTaskStep) this.activeTaskStepHandler = null;
                if (this.activeTaskApprovalHandler === pushTaskApproval) this.activeTaskApprovalHandler = null;
            });
        });
    }
}
