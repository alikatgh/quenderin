import { useState, useEffect, useRef } from 'react';
import { UIElement, LogEntry } from '../types/index.js';

export function useAgentSocket() {
    const [logs, setLogs] = useState<LogEntry[]>([]);
    const [status, setStatus] = useState<'idle' | 'running' | 'done'>('idle');
    const [currentUI, setCurrentUI] = useState<UIElement[]>([]);
    const wsRef = useRef<WebSocket | null>(null);

    useEffect(() => {
        const ws = new WebSocket(`ws://${window.location.host}`);
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
                }

                setLogs((prev) => [...prev, entry]);
            } catch (e) {
                console.error("Invalid WS message", e);
            }
        };

        ws.onclose = () => {
            setLogs((prev) => [...prev, { id: 'close', type: 'error', message: 'Connection to local Quenderin backend severed.', timestamp: '' }]);
            setStatus('idle');
        };

        return () => ws.close();
    }, []);

    const sendGoal = (goal: string) => {
        if (wsRef.current?.readyState !== WebSocket.OPEN) {
            setLogs(prev => [...prev, {
                id: 'err', type: 'error', message: "Not connected to agent backend. Make sure your server is running via terminal.", timestamp: new Date().toLocaleTimeString()
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
                id: 'err', type: 'error', message: "Not connected to backend.", timestamp: new Date().toLocaleTimeString()
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
    };

    return { wsReady: wsRef.current?.readyState === WebSocket.OPEN, logs, status, currentUI, sendGoal, sendChatMessage, resetSession };
}
