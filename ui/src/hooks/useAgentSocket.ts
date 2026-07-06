import { useState, useEffect, useRef } from 'react';
import { UIElement, LogEntry, RequiredAction } from '../types/index.js';
import { authToken, apiFetch } from '../lib/api.js';

/** Default settings with safe defaults — used for merge on load and reset */
export const DEFAULT_SETTINGS: AppSettings = {
    contextSize: 2048,
    memorySafetyEnabled: true,
    chatLogDedupeMs: 1000,
    themePreference: 'system',
    privacyLockEnabled: false,
    privacyPassphrase: '',
};

export interface AppSettings {
    contextSize: number;
    memorySafetyEnabled: boolean;
    chatLogDedupeMs: number;
    themePreference: 'light' | 'dark' | 'system';
    privacyLockEnabled: boolean;
    privacyPassphrase: string;
}

/** Shape of a single file attachment sent with a goal or chat message. Named so
 *  `sendGoal` and `sendChatMessage` share one source of truth for the attachment fields. */
export interface Attachment { name: string; content: string; }

/** Build a `settings_update` WS frame WITHOUT the privacy passphrase. The passphrase is a client-side
 *  UI-lock secret the server has no use for; broadcasting it in every settings_update frame leaked it
 *  to the server logs / any WS observer (deep-hunt HIGH). It stays only in the client (state + localStorage). */
function settingsUpdateFrame(s: AppSettings): string {
    const { privacyPassphrase: _omit, ...safe } = s;
    void _omit;
    return JSON.stringify({ type: 'settings_update', ...safe });
}

/** Discriminated union of every inbound WS frame the agent emits. Typing the parsed
 *  message turns the ~20 field accesses in `onmessage` into compiler-checked reads,
 *  catching typos and missing fields at build time (was implicit `any` via JSON.parse). */
type AgentMessage =
    | { type: 'log'; message: string }
    | { type: 'status'; message: string }
    | { type: 'observe'; elements?: UIElement[] }
    | { type: 'decide'; command: string }
    | { type: 'action'; message: string }
    | { type: 'chat_stream'; text: string }
    | { type: 'chat_response'; message: string; meta?: LogEntry['meta']; intent?: string }   // Q-294: server sends intent
    | { type: 'error'; message: string }
    | { type: 'done' }
    | { type: 'action_required'; data: RequiredAction }
    | { type: 'model_download_progress'; data?: { progress?: number } }
    | { type: 'model_switched'; modelId: string; activeModel?: string }   // Q-291: server emits on switch
    | { type: 'agent_paused'; isPaused: boolean; isRunning: boolean }     // Q-281: trust-loop pause ack
    | { type: 'agent_resumed'; manualAction: string | null; isPaused: boolean; isRunning: boolean }
    | { type: 'preset_changed'; presetId: string };

export function useAgentSocket() {
    const MAX_LOG_ENTRIES = 300;
    const capLogs = (next: LogEntry[]) => next.length > MAX_LOG_ENTRIES ? next.slice(-MAX_LOG_ENTRIES) : next;

    const [logs, setLogs] = useState<LogEntry[]>([]);
    const [status, setStatus] = useState<'idle' | 'running' | 'done'>('idle');
    const [currentUI, setCurrentUI] = useState<UIElement[]>([]);
    const [requiredAction, setRequiredAction] = useState<RequiredAction | null>(null);
    const [downloadProgress, setDownloadProgress] = useState<number>(0);
    const [wsReady, setWsReady] = useState(false);
    const [activePresetId, setActivePresetId] = useState<string>('general');
    const [agentPaused, setAgentPaused] = useState(false);   // Q-281: true while a run is parked for intervention
    const [settings, setSettings] = useState<AppSettings>(() => {
        try {
            const saved = localStorage.getItem('quenderin_settings');
            if (!saved) return { ...DEFAULT_SETTINGS };
            const parsed = JSON.parse(saved);
            // Coerce numeric fields: a corrupt localStorage value (e.g. contextSize: "abc") would otherwise
            // spread in verbatim as a string and break the context-size UI / numeric comparisons (deep-hunt).
            const num = (v: unknown, fallback: number) => (Number.isFinite(Number(v)) ? Number(v) : fallback);
            return {
                ...DEFAULT_SETTINGS,
                ...parsed,
                contextSize: num(parsed.contextSize, DEFAULT_SETTINGS.contextSize),
                chatLogDedupeMs: num(parsed.chatLogDedupeMs, DEFAULT_SETTINGS.chatLogDedupeMs),
            };
        } catch { return { ...DEFAULT_SETTINGS }; }
    });
    const wsRef = useRef<WebSocket | null>(null);
    const lastUserChatLogRef = useRef<{ message: string; at: number } | null>(null);
    // Keep a ref to settings so the onmessage handler always reads the latest value
    const settingsRef = useRef(settings);
    useEffect(() => { settingsRef.current = settings; }, [settings]);

    useEffect(() => {
        let reconnectAttempts = 0;
        const MAX_RECONNECT_ATTEMPTS = 15;
        const BASE_DELAY_MS = 1000;
        const MAX_DELAY_MS = 30000;
        let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
        let intentionallyClosed = false;

        function connect() {
        const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        // Per-launch auth token (audit HIGH #1), required on the WS upgrade — see lib/api.ts for how
        // it's sourced (Electron preload / opened-URL). Without it the local server rejects the upgrade.
        const token = authToken();
        const wsUrl = `${wsProtocol}//${window.location.host}/ws${token ? `?token=${encodeURIComponent(token)}` : ''}`;
        const ws = new WebSocket(wsUrl);
        wsRef.current = ws;

        ws.onopen = () => {
            setWsReady(true);
            reconnectAttempts = 0; // Reset on successful connection
        };

        ws.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data) as AgentMessage;
                const time = new Date().toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

                const entry: LogEntry = {
                    id: Math.random().toString(36).slice(2, 11),
                    // `entry` is built upfront for every frame but only PUSHED for log-bearing types; the
                    // non-log frames (action_required / model_download_progress / preset_changed) return
                    // early and never use `entry`, so narrowing the union to LogEntry['type'] here is safe.
                    type: data.type as LogEntry['type'],
                    message: '',
                    timestamp: time
                };

                // Apply settings on initial connection — use ref to avoid stale closure
                if (data.type === 'log' && data.message.includes('Connected')) {
                    ws.send(settingsUpdateFrame(settingsRef.current));
                }

                if (data.type === 'status') {
                    entry.message = data.message;
                } else if (data.type === 'observe') {
                    entry.message = `Scanned Device View Hierarchy. Found ${data.elements?.length || 0} interactable nodes.`;
                    // Do NOT store elements on the log entry — Inspector reads directly from
                    // currentUI state. Storing elements here would retain hundreds of UIElement
                    // objects per observe event in the logs array forever.
                    setCurrentUI(data.elements || []);
                } else if (data.type === 'decide') {
                    entry.message = `Executing command: ${data.command}`;
                    entry.command = data.command;
                } else if (data.type === 'action') {
                    entry.message = `Action successful: ${data.message}`;
                } else if (data.type === 'chat_stream') {
                    setLogs((prev) => {
                        const newLogs = [...prev];
                        const last = newLogs[newLogs.length - 1];
                        if (last && last.type === 'chat_response' && last.isStreaming) {
                            newLogs[newLogs.length - 1] = { ...last, message: last.message + data.text };
                        } else {
                            newLogs.push({ ...entry, type: 'chat_response', message: data.text, isStreaming: true });
                        }
                        return capLogs(newLogs);
                    });
                    setStatus((prev) => (prev === 'running' ? prev : 'running'));
                    return;
                } else if (data.type === 'chat_response') {
                    setLogs((prev) => {
                        const newLogs = [...prev];
                        const last = newLogs[newLogs.length - 1];
                        if (last && last.type === 'chat_response' && last.isStreaming) {
                            newLogs[newLogs.length - 1] = { ...last, message: data.message, isStreaming: false, meta: data.meta };
                            return capLogs(newLogs);
                        } else {
                            entry.message = data.message;
                            entry.isStreaming = false;
                            entry.meta = data.meta;
                            return capLogs([...newLogs, entry]);
                        }
                    });
                    setStatus('done');
                    return;
                } else if (data.type === 'error') {
                    entry.message = data.message;
                    setStatus('done');
                } else if (data.type === 'done') {
                    entry.message = 'Goal reached successfully.';
                    setStatus('done');
                } else if (data.type === 'action_required') {
                    if (data.data?.code === 'OOM_PREVENTION') {
                        setLogs((prev) => prev.filter((log) => {
                            if (log.type !== 'error') return true;
                            const msg = (log.message || '').toLowerCase();
                            return !(
                                msg.includes('not enough free ram for this model') ||
                                msg.includes('enable a smaller model download') ||
                                msg.includes('disable memory safety in settings')
                            );
                        }));
                    }
                    setStatus('done');
                    setRequiredAction(data.data);
                    return; // Don't add to general logs, this is an interactive modal trigger
                } else if (data.type === 'model_download_progress') {
                    setDownloadProgress(data.data?.progress ?? 0);
                    return;
                } else if (data.type === 'preset_changed') {
                    setActivePresetId(data.presetId);
                    return;
                } else if (data.type === 'agent_paused') {
                    setAgentPaused(data.isPaused);   // Q-281: reflect the trust-loop pause in the UI
                    return;
                } else if (data.type === 'agent_resumed') {
                    setAgentPaused(data.isPaused);
                    return;
                }

                // Cap the log buffer at 300 entries so long chat sessions never grow the
                // React state without bound (each spread is O(n), 300 is imperceptible to users).
                setLogs((prev) => {
                    const next = [...prev, entry];
                    return capLogs(next);
                });
            } catch (e) {
                console.error("Invalid WS message", e);
            }
        };

        // Surface socket errors. Reconnect is driven by onclose (bounded by MAX_RECONNECT_ATTEMPTS +
        // backoff); without an onerror handler the error was swallowed silently (deep-hunt).
        ws.onerror = (ev) => {
            console.error('[WS] socket error', ev);
        };

        ws.onclose = () => {
            setWsReady(false);
            if (intentionallyClosed) return;

            if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
                // Exponential backoff with jitter to prevent thundering herd
                const delay = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * Math.pow(2, reconnectAttempts));
                const jitter = delay * 0.3 * Math.random();
                const effectiveDelay = Math.round(delay + jitter);
                reconnectAttempts++;

                setLogs((prev) => capLogs([...prev, {
                    id: `reconnect-${reconnectAttempts}`,
                    type: 'status',
                    message: `Connection lost. Reconnecting in ${Math.round(effectiveDelay / 1000)}s (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})...`,
                    timestamp: new Date().toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' })
                }]));

                reconnectTimer = setTimeout(connect, effectiveDelay);
            } else {
                setLogs((prev) => capLogs([...prev, {
                    // Unique id — a static 'close' collides as a React key if a second
                    // connection cycle also fails after retries (audit re-sweep).
                    id: `close-${crypto.randomUUID()}`,
                    type: 'error',
                    message: "**Connection Lost**\nThe interface lost connection to Quenderin after multiple attempts.\n**How to fix this:**\n1. Check your computer window where Quenderin is running.\n2. If it closed, please restart the application.\n3. Once it's running again, refresh this page.",
                    timestamp: ''
                }]));
                setStatus('idle');
            }
        };
        } // end connect()

        connect();

        return () => {
            intentionallyClosed = true;
            if (reconnectTimer) clearTimeout(reconnectTimer);
            wsRef.current?.close();
        };
    }, []);

    // Shared socket-not-open guard for sendGoal/sendChatMessage — single-sources the
    // 'System Sleeping' user-facing copy so a wording fix lives in one place.
    const ensureSocketOpen = (): WebSocket | null => {
        if (wsRef.current?.readyState === WebSocket.OPEN) return wsRef.current;
        setLogs(prev => capLogs([...prev, {
            // Unique id — every failed send appends a row; a static 'err' would duplicate the key.
            id: `err-${crypto.randomUUID()}`,
            type: 'error',
            message: "**System Sleeping**\nYou're trying to send a command, but the Quenderin system isn't active.\n**How to fix this:**\n1. Ensure the Quenderin application window is open and active on your computer.\n2. If it's not open, please start the application.\n3. Once the system is active, try your request again.",
            timestamp: new Date().toLocaleTimeString()
        }]));
        return null;
    };

    const sendGoal = (goal: string, attachments: Attachment[] = []) => {
        const ws = ensureSocketOpen();
        if (!ws) return false;

        setStatus('running');
        setLogs([{
            id: 'start', type: 'status', message: `Goal set: ${goal}${attachments.length > 0 ? ` (with ${attachments.length} attachments)` : ''}`, timestamp: new Date().toLocaleTimeString()
        }]);
        setCurrentUI([]);
        ws.send(JSON.stringify({ type: 'start', goal, attachments }));
        return true;
    };

    const sendChatMessage = (msg: string, attachments: Attachment[] = []) => {
        const ws = ensureSocketOpen();
        if (!ws) return false;

        setStatus('running');
        const normalized = msg.trim();
        const now = Date.now();
        const recentlyLoggedDuplicate =
            lastUserChatLogRef.current &&
            lastUserChatLogRef.current.message === normalized &&
            (now - lastUserChatLogRef.current.at) < settingsRef.current.chatLogDedupeMs;

        if (!recentlyLoggedDuplicate) {
            setLogs(prev => capLogs([...prev, {
                id: Math.random().toString(36).slice(2, 11), type: 'chat', message: msg, timestamp: new Date().toLocaleTimeString()
            }]));
            lastUserChatLogRef.current = { message: normalized, at: now };
        }

        ws.send(JSON.stringify({ type: 'chat', message: msg, attachments }));
        return true;
    };

    const manualVoiceStart = () => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'manual_voice_start' }));
        }
    };

    const manualVoiceStop = () => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'manual_voice_stop' }));
        }
    };

    const resetSession = () => {
        setLogs([]);
        setStatus('idle');
        setCurrentUI([]);
        setRequiredAction(null);
        lastUserChatLogRef.current = null;
    };

    const clearRequiredAction = () => setRequiredAction(null);

    const updateSettings = (newSettings: AppSettings) => {
        setSettings(newSettings);
        try { localStorage.setItem('quenderin_settings', JSON.stringify(newSettings)); } catch { /* best-effort */ }
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(settingsUpdateFrame(newSettings));
        }
    };

    const resetSettings = () => {
        const fresh = { ...DEFAULT_SETTINGS };
        setSettings(fresh);
        try { localStorage.setItem('quenderin_settings', JSON.stringify(fresh)); } catch { /* best-effort */ }
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(settingsUpdateFrame(fresh));
        }
    };

    const switchPreset = (presetId: string) => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'preset_switch', presetId }));
        }
        setActivePresetId(presetId);
    };

    // Q-281: the trust loop over the live channel. `pauseAgent` parks a running mission for manual
    // takeover; `resumeAgent` continues, optionally handing the agent a one-off human instruction for
    // the next step. Optimistically flips `agentPaused` so the button reacts instantly; the server's
    // agent_paused/agent_resumed ack reconciles it.
    const pauseAgent = () => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'pause' }));
            setAgentPaused(true);
        }
    };

    const resumeAgent = (manualAction?: string) => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            const trimmed = manualAction?.trim();
            wsRef.current.send(JSON.stringify({ type: 'resume', ...(trimmed ? { manualAction: trimmed } : {}) }));
            setAgentPaused(false);
        }
    };

    // Q-292: stop an in-flight chat reply. The server aborts the decode and returns the streamed
    // partial as the normal chat_response, so the stream just ends — no client-side log surgery.
    const stopChat = () => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'stop_chat' }));
        }
    };

    // Q-523: hard-stop a running agent mission (the kill switch — distinct from pause). The server
    // aborts the in-flight decode and breaks the loop, which emits its own 'done'.
    const stopAgent = () => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'stop_agent' }));
        }
    };

    // Q-313: open a past conversation from the Recent list. Fetches the saved transcript and rehydrates
    // the chat log so the user actually SEES it (clicking Recent used to only switch the view). Returns
    // whether it loaded, so the caller can switch to the chat view only on success.
    const loadSession = async (sessionId: string): Promise<boolean> => {
        try {
            const res = await apiFetch(`/api/sessions/${encodeURIComponent(sessionId)}`);
            if (!res.ok) return false;
            const session = await res.json() as { messages?: { role: string; content: string; timestamp?: string }[] };
            const restored: LogEntry[] = (session.messages ?? []).map((m, i) => ({
                id: `restored-${sessionId}-${i}`,
                type: m.role === 'user' ? 'chat' : 'chat_response',
                message: m.content,
                timestamp: m.timestamp ?? '',
            }));
            setLogs(restored);
            setStatus('idle');
            lastUserChatLogRef.current = null;
            return true;
        } catch {
            return false;
        }
    };

    return {
        wsReady,
        logs, status, currentUI, requiredAction, downloadProgress, settings, activePresetId, agentPaused,
        sendGoal, sendChatMessage, resetSession, clearRequiredAction, updateSettings, resetSettings, switchPreset,
        manualVoiceStart, manualVoiceStop, pauseAgent, resumeAgent, stopChat, stopAgent, loadSession
    };
}
