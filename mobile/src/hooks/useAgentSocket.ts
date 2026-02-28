// =============================================================================
// useAgentSocket — connects to backend, routes WS messages to stores
// Mirrors desktop ui/src/hooks/useAgentSocket behaviour
// =============================================================================

import { useEffect, useRef, useCallback } from 'react';
import WebSocketService, { WSMessage } from '../services/websocket';
import { useChatStore } from '../stores/chatStore';
import { useAppStore } from '../stores/appStore';
import { TOKEN_BATCH_INTERVAL_MS } from '../constants';
import type { LogEntry, MetricRecord, RequiredAction } from '../types';

interface UseAgentSocketOptions {
  subscribe?: boolean;
}

export function useAgentSocket(options: UseAgentSocketOptions = {}) {
  const { subscribe = true } = options;
  const ws = useRef(WebSocketService.shared()).current;
  const tokenBuffer = useRef('');
  const batchTimer = useRef<ReturnType<typeof setInterval> | null>(null);

  // Zustand selectors (stable refs via getState inside callbacks)
  const flushTokens = useCallback(() => {
    if (tokenBuffer.current.length > 0) {
      const tokens = tokenBuffer.current;
      tokenBuffer.current = '';
      useChatStore.getState().appendStreamToken(tokens);
    }
  }, []);

  // Start token batch flush timer
  useEffect(() => {
    if (!subscribe) return;
    batchTimer.current = setInterval(flushTokens, TOKEN_BATCH_INTERVAL_MS);
    return () => {
      if (batchTimer.current) clearInterval(batchTimer.current);
      flushTokens();
    };
  }, [flushTokens, subscribe]);

  // Subscribe to WS messages
  useEffect(() => {
    if (!subscribe) return;

    const handleMessage = (msg: WSMessage) => {
      const chat = useChatStore.getState();

      switch (msg.type) {
        // --- Chat response complete ---
        case 'chat_response': {
          flushTokens();
          chat.setIsGenerating(false);
          const currentLogs = [...useChatStore.getState().logs];
          const streamReverseIdx = [...currentLogs]
            .reverse()
            .findIndex((entry) => entry.type === 'chat_stream' && entry.isStreaming);
          if (streamReverseIdx >= 0) {
            const idx = currentLogs.length - 1 - streamReverseIdx;
            currentLogs[idx] = {
              ...currentLogs[idx],
              type: 'chat_response',
              isStreaming: false,
              message:
                typeof msg.text === 'string' && msg.text.length > 0
                  ? (msg.text as string)
                  : currentLogs[idx].message,
              meta: msg.meta as LogEntry['meta'],
            };
            useChatStore.setState({ logs: currentLogs });
          } else {
            const log: LogEntry = {
              id: `resp-${Date.now()}`,
              type: 'chat_response',
              message: (msg.text as string) ?? '',
              timestamp: Date.now(),
              meta: msg.meta as LogEntry['meta'],
            };
            chat.addLog(log);
          }
          break;
        }

        // --- Streaming token ---
        case 'stream_token': {
          tokenBuffer.current += msg.token as string;
          break;
        }

        // --- Streaming chunk (desktop protocol variant) ---
        case 'chat_stream': {
          const chunk = typeof msg.text === 'string' ? msg.text : '';
          if (!chunk) break;

          const logs = useChatStore.getState().logs;
          const hasActiveStream = [...logs].some(
            (entry) => entry.type === 'chat_stream' && entry.isStreaming,
          );

          if (!hasActiveStream) {
            chat.setIsGenerating(true);
            chat.addLog({
              id: `stream-${Date.now()}`,
              type: 'chat_stream',
              message: '',
              timestamp: Date.now(),
              isStreaming: true,
            });
          }

          tokenBuffer.current += chunk;
          break;
        }

        // --- Stream start ---
        case 'stream_start': {
          chat.setIsGenerating(true);
          const streamLog: LogEntry = {
            id: `stream-${Date.now()}`,
            type: 'chat_stream',
            message: '',
            timestamp: Date.now(),
            isStreaming: true,
          };
          chat.addLog(streamLog);
          break;
        }

        // --- Stream end ---
        case 'stream_end': {
          flushTokens();
          chat.setIsGenerating(false);
          // Mark last streaming log as complete
          const logs = [...useChatStore.getState().logs];
          const streamReverseIdx = [...logs]
            .reverse()
            .findIndex((entry) => entry.type === 'chat_stream' && entry.isStreaming);
          if (streamReverseIdx >= 0) {
            const idx = logs.length - 1 - streamReverseIdx;
            logs[idx] = {
              ...logs[idx],
              isStreaming: false,
              meta: msg.meta as LogEntry['meta'],
            };
            useChatStore.setState({ logs });
          }
          break;
        }

        // --- Status updates ---
        case 'status': {
          chat.setStatusText(msg.text as string);
          const statusLog: LogEntry = {
            id: `status-${Date.now()}`,
            type: 'status',
            message: msg.text as string,
            timestamp: Date.now(),
          };
          chat.addLog(statusLog);
          break;
        }

        // --- Generic logs ---
        case 'log': {
          const logMessage =
            typeof msg.message === 'string' ? msg.message : String(msg.message ?? '');
          if (!logMessage) break;
          chat.addLog({
            id: `log-${Date.now()}`,
            type: 'log',
            message: logMessage,
            timestamp: Date.now(),
          });
          break;
        }

        // --- Agent lifecycle: observe / decide / action / done ---
        case 'observe':
        case 'decide':
        case 'action':
        case 'done': {
          const lifecycleLog: LogEntry = {
            id: `${msg.type}-${Date.now()}`,
            type: msg.type as LogEntry['type'],
            message: msg.text as string,
            timestamp: Date.now(),
          };
          chat.addLog(lifecycleLog);
          if (msg.type === 'done') chat.setIsGenerating(false);
          break;
        }

        // --- Error ---
        case 'error': {
          chat.setIsGenerating(false);
          const errorLog: LogEntry = {
            id: `err-${Date.now()}`,
            type: 'error',
            message: msg.message as string,
            timestamp: Date.now(),
          };
          chat.addLog(errorLog);
          break;
        }

        // --- Required action (e.g., download model) ---
        case 'required_action': {
          chat.setRequiredAction(msg.action as RequiredAction);
          break;
        }

        // --- Metrics ---
        case 'metrics': {
          chat.setMetrics(msg.records as MetricRecord[]);
          break;
        }

        // --- Settings sync ---
        case 'settings_sync': {
          if (msg.settings) {
            useAppStore.getState().updateSettings(
              msg.settings as Partial<import('../types').AppSettings>,
            );
          }
          break;
        }

        default:
          break;
      }
    };

    const unsub = ws.subscribe(handleMessage);
    return unsub;
  }, [ws, flushTokens, subscribe]);

  // Actions
  const sendChat = useCallback(
    (text: string) => {
      const chat = useChatStore.getState();
      if (!ws.isConnected) {
        chat.addLog({
          id: `err-disconnected-${Date.now()}`,
          type: 'error',
          message: 'Not connected to server. Open Settings and verify the WebSocket URL.',
          timestamp: Date.now(),
        });
        chat.setIsGenerating(false);
        return;
      }
      const userLog: LogEntry = {
        id: `user-${Date.now()}`,
        type: 'chat',
        message: text,
        timestamp: Date.now(),
      };
      chat.addLog(userLog);
      chat.setIsGenerating(true);
      ws.send({
        type: 'chat',
        message: text,
        preset: chat.activePreset,
      });
    },
    [ws],
  );

  const stopGeneration = useCallback(() => {
    ws.send({ type: 'stop_generation' });
    useChatStore.getState().setIsGenerating(false);
  }, [ws]);

  const triggerAction = useCallback(
    (code: string, payload?: Record<string, unknown>) => {
      ws.send({ type: 'trigger_action', code, ...payload });
    },
    [ws],
  );

  const requestMetrics = useCallback(() => {
    ws.send({ type: 'get_metrics' });
  }, [ws]);

  return {
    sendChat,
    stopGeneration,
    triggerAction,
    requestMetrics,
    connect: ws.connect.bind(ws),
    disconnect: ws.disconnect.bind(ws),
  };
}
