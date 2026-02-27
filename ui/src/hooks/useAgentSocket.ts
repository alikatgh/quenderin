import { useState, useEffect, useRef } from 'react';
import { UIElement, LogEntry } from '../types/index.js';

export function useAgentSocket() {
    const [logs, setLogs] = useState<LogEntry[]>([]);
    const [status, setStatus] = useState<'idle' | 'running' | 'done'>('idle');
    const [currentUI, setCurrentUI] = useState<UIElement[]>([]);
    const [requiredAction, setRequiredAction] = useState<{ code: string, title: string, message: string } | null>(null);
    const [downloadProgress, setDownloadProgress] = useState<number>(0);
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
                } else if (data.type === 'chat_response') {
                    entry.message = data.message;
                    setStatus('done');
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
                message: "**Server Disconnected**\nThe user interface lost connection to the Quenderin brain.\n**How to fix this:**\n1. Open your computer's terminal program.\n2. Navigate to your Quenderin project folder.\n3. Start the engine by typing `npm run dev` and pressing Enter.\n4. Once the terminal shows it's running, click \"Reconnect\" or refresh this page.",
                timestamp: ''
            }]);
            setStatus('idle');
        };

        return () => ws.close();
    }, []);

    const sendGoal = (goal: string) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => [...prev, {
                id: 'err',
                type: 'error',
                message: "**Engine Not Running**\nYou are trying to send a command, but the local engine isn't running.\n**How to fix this:**\n1. Open your terminal/command prompt.\n2. Go to the Quenderin directory.\n3. Type `npm run dev` and press Enter.\n4. Wait for the success message in the terminal, then try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]);
            return false;
        }

        setStatus('running');
        setLogs([{
            id: 'start', type: 'status', message: `Goal set: ${goal}`, timestamp: new Date().toLocaleTimeString()
        }]);
        setCurrentUI([]);
        wsRef.current.send(JSON.stringify({ type: 'start', goal }));
        return true;
    };

    const sendChatMessage = (msg: string) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => [...prev, {
                id: 'err',
                type: 'error',
                message: "**Engine Not Running**\nYou are trying to send a command, but the local engine isn't running.\n**How to fix this:**\n1. Open your terminal/command prompt.\n2. Go to the Quenderin directory.\n3. Type `npm run dev` and press Enter.\n4. Wait for the success message in the terminal, then try your request again.",
                timestamp: new Date().toLocaleTimeString()
            }]);
            return false;
        }

        setStatus('running');
        setLogs(prev => [...prev, {
            id: Math.random().toString(36).substr(2, 9), type: 'chat', message: msg, timestamp: new Date().toLocaleTimeString()
        }]);
        wsRef.current.send(JSON.stringify({ type: 'chat', message: msg }));
        return true;
    };

    const resetSession = () => {
        setLogs([]);
        setStatus('idle');
        setCurrentUI([]);
        setRequiredAction(null);
    };

    const clearRequiredAction = () => setRequiredAction(null);

    return {
        wsReady: wsRef.current?.readyState === WebSocket.OPEN,
        logs, status, currentUI, requiredAction, downloadProgress,
        sendGoal, sendChatMessage, resetSession, clearRequiredAction
    };
}
