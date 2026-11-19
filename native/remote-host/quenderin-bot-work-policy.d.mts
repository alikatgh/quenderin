export const BOT_WORK_CAPABILITY: 'quenderin.bot.work.v1';
export const BOT_WORK_ENDPOINTS: readonly ['quenderin-submit', 'quenderin-command'];
export const BOT_WORK_LIMITS: Readonly<{ identityUTF8Bytes: 1024; commandIdUTF8Bytes: 128; textUTF8Bytes: 16384; requestUTF8Bytes: 32768; resultUTF8Bytes: 8192; journalRecords: 1024; pendingPerBot: 1; pendingTotal: 32; promptCallsPerCommand: 1; dispatchTimeoutMilliseconds: 30000; revisionMaximum: number }>;
export const BOT_WORK_REASONS: readonly string[];
export const BOT_WORK_RECEIPT_KEYS: readonly string[];
export interface BotWorkPayload { schemaVersion: 1; workspaceId: string; botId: string; commandId: string; expectedSessionId?: string; expectedRevision?: number; text?: string }
export interface BotWorkRequest { route: 'api/bot'; body: { endpoint: 'quenderin-submit' | 'quenderin-command'; payload: BotWorkPayload } }
export interface BotWorkReceipt { schemaVersion: 1; workspaceId: string; botId: string; commandId: string; sessionId: string | null; revision: number | null; state: 'accepted' | 'rejected' | 'uncertain' | 'notFound'; reason: string | null }
export function botWorkFields(value: unknown, keys: readonly string[]): Record<string, any>;
export function botWorkScalar(value: unknown, maximum?: number): string;
export function validateBotWorkRequest(value: unknown): { ok: true; value: BotWorkRequest } | { ok: false };
export function botWorkReceipt(payload: BotWorkPayload, state: BotWorkReceipt['state'], reason?: string | null, sessionId?: string | null, revision?: number | null): BotWorkReceipt;
export function botWorkResponse(value: BotWorkReceipt): { status: 200; json: { ok: true; value: BotWorkReceipt } };
export function botWorkUnavailable(): { status: 503; json: unknown };
export function validateBotWorkResponse(value: unknown, request: unknown): { ok: true; value: { status: 200; json: { ok: true; value: BotWorkReceipt } } } | { ok: false };
