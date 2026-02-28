// =============================================================================
// Quenderin Mobile — Shared Types
// =============================================================================

export interface GenerationMeta {
  tokenCount: number;
  durationMs: number;
  tokensPerSecond: number;
  timeToFirstTokenMs: number;
}

export interface LogEntry {
  id: string;
  type:
    | 'log'
    | 'status'
    | 'observe'
    | 'decide'
    | 'action'
    | 'done'
    | 'chat'
    | 'chat_response'
    | 'chat_stream'
    | 'error';
  message: string;
  timestamp: number;
  isStreaming?: boolean;
  meta?: GenerationMeta;
}

export interface RequiredAction {
  code: string;
  title: string;
  message: string;
  autoTrigger?: boolean;
  downloadedModels?: string[];
  allModels?: { id: string; label: string; ramGb: number; sizeLabel: string }[];
}

export interface AppSettings {
  contextSize: number;
  memorySafetyEnabled: boolean;
  chatLogDedupeMs: number;
  themePreference: 'light' | 'dark' | 'system';
  privacyLockEnabled: boolean;
  privacyPassphrase: string;
}

export const DEFAULT_SETTINGS: AppSettings = {
  contextSize: 2048,
  memorySafetyEnabled: true,
  chatLogDedupeMs: 1000,
  themePreference: 'system',
  privacyLockEnabled: false,
  privacyPassphrase: '',
};

export interface MetricRecord {
  id: string;
  goal_text: string;
  success: boolean;
  total_steps: number;
  duration_ms: number;
  total_retries: number;
  timestamp: string;
}

export type PresetId =
  | 'general'
  | 'code-review'
  | 'creative-writer'
  | 'tutor'
  | 'summarizer';

export interface Preset {
  id: PresetId;
  label: string;
  icon: string; // Feather icon name
}

export const PRESETS: Preset[] = [
  { id: 'general', label: 'General', icon: 'message-square' },
  { id: 'code-review', label: 'Code Review', icon: 'code' },
  { id: 'creative-writer', label: 'Writer', icon: 'edit-3' },
  { id: 'tutor', label: 'Tutor', icon: 'book-open' },
  { id: 'summarizer', label: 'Summary', icon: 'file-text' },
];
