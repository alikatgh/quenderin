import { useState, useEffect, useRef } from 'react';
import { UIElement, LogEntry } from '../types/index.js';

export function useAgentSocket() {
    const [logs, setLogs] = useState<LogEntry[]>([]);
    const [status, setStatus] = useState<'idle' | 'running' | 'done'>('idle');
    const [currentUI, setCurrentUI] = useState<UIElement[]>([]);
    const [requiredAction, setRequiredAction] = useState<{ code: string, title: string, message: string } | null>(null);
    const [downloadProgress, setDownloadProgress] = useState<number>(0);
    const [settings, setSettings] = useState<{ contextSize: number, memorySafetyEnabled: boolean, themePreference: 'light' | 'dark' | 'system', privacyLockEnabled: boolean, privacyPassphrase: string }>(() => {
        const saved = localStorage.getItem('quenderin_settings');
        const defaultSettings = { contextSize: 2048, memorySafetyEnabled: true, themePreference: 'system' as const, privacyLockEnabled: false, privacyPassphrase: '' };
        return saved ? { ...defaultSettings, ...JSON.parse(saved) } : defaultSettings;
    });
    const wsRef = useRef<WebSocket | null>(null);

    useEffect(() => {
        const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const ws = new WebSocket(`${wsProtocol}//${window.location.host}/ws`);
        wsRef.current = ws;

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

                // Apply settings on initial connection
                if (data.type === 'log' && data.message.includes('Connected')) {
                    ws.send(JSON.stringify({ type: 'settings_update', ...settings }));
                }

                if (data.type === 'status') {
                    entry.message = data.message;
                } else if (data.type === 'observe') {
                    entry.message = `Scanned Device View Hierarchy. Found ${data.elements?.length || 0} interactable nodes.`;
                    entry.elements = data.elements;
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
                        return newLogs;
                    });
                    if (status !== 'running') setStatus('running');
                    return;
                } else if (data.type === 'chat_response') {
                    setLogs((prev) => {
                        const newLogs = [...prev];
                        const last = newLogs[newLogs.length - 1];
                        if (last && last.type === 'chat_response' && last.isStreaming) {
                            newLogs[newLogs.length - 1] = { ...last, message: data.message, isStreaming: false };
                            return newLogs;
                        } else {
                            entry.message = data.message;
                            entry.isStreaming = false;
                            return [...newLogs, entry];
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
                    setRequiredAction(data.data);
                    return; // Don't add to general logs, this is an interactive modal trigger
                } else if (data.type === 'model_download_progress') {
                    setDownloadProgress(data.data.progress);
                    return;
                }

                setLogs((prev) => [...prev, entry]);
            } catch (e) {
                console.error("Invalid WS message", e);
            }
        };

        ws.onclose = () => {
            setLogs((prev) => [...prev, {
                id: 'close',
                type: 'error',
                message: "**Connection Lost**\nThe interface lost connection to Quenderin.\n**How to fix this:**\n1. Check your computer window where Quenderin is running.\n2. If it closed, please restart the application.\n3. Once it's running again, click \"Reconnect\" or refresh this page.",
                timestamp: ''
            }]);
            setStatus('idle');
        };

        return () => ws.close();
    }, []);

    const sendGoal = (goal: string, attachments: { name: string, content: string }[] = []) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => [...prev, {
                id: 'err',
                type: 'error',
                message: "**System Sleeping**\nYou're trying to send a command, but the Quenderin system isn't active.\n**How to fix this:**\n1. Ensure the Quenderin application window is open and active on your computer.\n2. If it's not open, please start the application.\n3. Once the system is active, try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]);
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
            setLogs(prev => [...prev, {
                id: 'err',
                type: 'error',
                message: "**System Sleeping**\nYou're trying to send a command, but the Quenderin system isn't active.\n**How to fix this:**\n1. Ensure the Quenderin application window is open and active on your computer.\n2. If it's not open, please start the application.\n3. Once the system is active, try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]);
            return false;
        }

        setStatus('running');
        setLogs(prev => [...prev, {
            id: Math.random().toString(36).substr(2, 9), type: 'chat', message: msg, timestamp: new Date().toLocaleTimeString()
        }]);
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
    };

    const clearRequiredAction = () => setRequiredAction(null);

    const updateSettings = (newSettings: typeof settings) => {
        setSettings(newSettings);
        localStorage.setItem('quenderin_settings', JSON.stringify(newSettings));
        if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'settings_update', ...newSettings }));
        }
    };

    return {
        wsReady: wsRef.current?.readyState === WebSocket.OPEN,
        logs, status, currentUI, requiredAction, downloadProgress, settings,
        sendGoal, sendChatMessage, resetSession, clearRequiredAction, updateSettings,
        manualVoiceStart, manualVoiceStop
    };
}
