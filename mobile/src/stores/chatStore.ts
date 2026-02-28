// =============================================================================
// Chat Store — logs, streaming state, preset (NOT persisted)
// =============================================================================

import { create } from 'zustand';
import type { LogEntry, PresetId, RequiredAction, MetricRecord } from '../types';
import { CHAT_LOG_DEDUPE_WINDOW_MS } from '../constants';

interface ChatState {
  // Logs
  logs: LogEntry[];
  addLog: (entry: LogEntry) => void;
  appendStreamToken: (token: string) => void;
  clearLogs: () => void;

  // Streaming
  isGenerating: boolean;
  setIsGenerating: (v: boolean) => void;

  // Status
  statusText: string;
  setStatusText: (text: string) => void;

  // Preset
  activePreset: PresetId;
  setActivePreset: (id: PresetId) => void;

  // Required action (model download, etc.)
  requiredAction: RequiredAction | null;
  setRequiredAction: (action: RequiredAction | null) => void;

  // Metrics
  metrics: MetricRecord[];
  addMetric: (m: MetricRecord) => void;
  setMetrics: (m: MetricRecord[]) => void;
}

export const useChatStore = create<ChatState>()((set, get) => ({
  // Logs
  logs: [],
  addLog: (entry) => {
    const { logs } = get();
    // Dedupe by message within window
    const isDupe = logs.some(
      (l) =>
        l.message === entry.message &&
        l.type === entry.type &&
        entry.timestamp - l.timestamp < CHAT_LOG_DEDUPE_WINDOW_MS,
    );
    if (isDupe) return;
    set({ logs: [...logs, entry] });
  },

  appendStreamToken: (token) => {
    set((state) => {
      const logs = [...state.logs];
      const targetIdx = [...logs]
        .reverse()
        .findIndex((entry) => entry.type === 'chat_stream' && entry.isStreaming);
      if (targetIdx < 0) return state;
      const idx = logs.length - 1 - targetIdx;
      const target = logs[idx];
      logs[idx] = { ...target, message: target.message + token };
      return { logs };
    });
  },

  clearLogs: () => set({ logs: [], statusText: '' }),

  // Streaming
  isGenerating: false,
  setIsGenerating: (isGenerating) => set({ isGenerating }),

  // Status
  statusText: '',
  setStatusText: (statusText) => set({ statusText }),

  // Preset
  activePreset: 'general',
  setActivePreset: (activePreset) => set({ activePreset }),

  // Required action
  requiredAction: null,
  setRequiredAction: (requiredAction) => set({ requiredAction }),

  // Metrics
  metrics: [],
  addMetric: (m) => set((state) => ({ metrics: [...state.metrics, m] })),
  setMetrics: (metrics) => set({ metrics }),
}));
