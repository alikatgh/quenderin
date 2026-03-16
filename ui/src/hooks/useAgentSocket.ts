import { useState, useEffect, useRef } from 'react';
import { UIElement, LogEntry, RequiredAction } from '../types/index.js';

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
    const [settings, setSettings] = useState<AppSettings>(() => {
        try {
            const saved = localStorage.getItem('quenderin_settings');
            return saved ? { ...DEFAULT_SETTINGS, ...JSON.parse(saved) } : { ...DEFAULT_SETTINGS };
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
        const ws = new WebSocket(`${wsProtocol}//${window.location.host}/ws`);
        wsRef.current = ws;

        ws.onopen = () => {
            setWsReady(true);
            reconnectAttempts = 0; // Reset on successful connection
        };

        ws.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                const time = new Date().toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

                const entry: LogEntry = {
                    id: Math.random().toString(36).substr(2, 9),
                    type: data.type,
                    message: '',
                    timestamp: time
                };

                // Apply settings on initial connection — use ref to avoid stale closure
                if (data.type === 'log' && data.message.includes('Connected')) {
                    ws.send(JSON.stringify({ type: 'settings_update', ...settingsRef.current }));
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
                    setDownloadProgress(data.data.progress);
                    return;
                } else if (data.type === 'preset_changed') {
                    setActivePresetId(data.presetId);
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
                    id: 'close',
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

    const sendGoal = (goal: string, attachments: { name: string, content: string }[] = []) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => capLogs([...prev, {
                id: 'err',
                type: 'error',
                message: "**System Sleeping**\nYou're trying to send a command, but the Quenderin system isn't active.\n**How to fix this:**\n1. Ensure the Quenderin application window is open and active on your computer.\n2. If it's not open, please start the application.\n3. Once the system is active, try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]));
            return false;
        }

        setStatus('running');
        setLogs([{
            id: 'start', type: 'status', message: `Goal set: ${goal}${attachments.length > 0 ? ` (with ${attachments.length} attachments)` : ''}`, timestamp: new Date().toLocaleTimeString()
        }]);
        setCurrentUI([]);
        wsRef.current.send(JSON.stringify({ type: 'start', goal, attachments }));
        return true;
    };

    const sendChatMessage = (msg: string, attachments: { name: string, content: string }[] = []) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => capLogs([...prev, {
                id: 'err',
                type: 'error',
                message: "**System Sleeping**\nYou're trying to send a command, but the Quenderin system isn't active.\n**How to fix this:**\n1. Ensure the Quenderin application window is open and active on your computer.\n2. If it's not open, please start the application.\n3. Once the system is active, try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]));
            return false;
        }

        setStatus('running');
        const normalized = msg.trim();
        const now = Date.now();
        const recentlyLoggedDuplicate =
            lastUserChatLogRef.current &&
            lastUserChatLogRef.current.message === normalized &&
            (now - lastUserChatLogRef.current.at) < settingsRef.current.chatLogDedupeMs;

        if (!recentlyLoggedDuplicate) {
            setLogs(prev => capLogs([...prev, {
                id: Math.random().toString(36).substr(2, 9), type: 'chat', message: msg, timestamp: new Date().toLocaleTimeString()
            }]));
            lastUserChatLogRef.current = { message: normalized, at: now };
        }

        wsRef.current.send(JSON.stringify({ type: 'chat', message: msg, attachments }));
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

    const updateSettings = (newSettings: typeof settings) => {
        setSettings(newSettings);
        try { localStorage.setItem('quenderin_settings', JSON.stringify(newSettings)); } catch { /* best-effort */ }
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'settings_update', ...newSettings }));
        }
    };

    const resetSettings = () => {
        const fresh = { ...DEFAULT_SETTINGS };
        setSettings(fresh);
        try { localStorage.setItem('quenderin_settings', JSON.stringify(fresh)); } catch { /* best-effort */ }
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'settings_update', ...fresh }));
        }
    };

    const switchPreset = (presetId: string) => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'preset_switch', presetId }));
        }
        setActivePresetId(presetId);
    };

    return {
        wsReady,
        logs, status, currentUI, requiredAction, downloadProgress, settings, activePresetId,
        sendGoal, sendChatMessage, resetSession, clearRequiredAction, updateSettings, resetSettings, switchPreset,
        manualVoiceStart, manualVoiceStop
    };
}
