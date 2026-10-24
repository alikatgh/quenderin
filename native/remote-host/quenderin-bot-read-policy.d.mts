export const BOT_READ_CAPABILITY: 'quenderin.bot.read.v1';
export const BOT_READ_CARRIER_CAPABILITY: 'plugin.route.v1';
export const BOT_READ_ROUTE: 'api/bot';
export const BOT_READ_ENDPOINT: 'quenderin-roster';
export const BOT_READ_LIMITS: Readonly<{
  requestUTF8Bytes: 4096; resultUTF8Bytes: 262144; bots: 100;
  identityUTF8Bytes: 1024; nameUTF8Bytes: 256; modelUTF8Bytes: 256;
  permissionUTF8Bytes: 64; revisionMaximum: number;
}>;
export interface BotReadRequest {
  route: 'api/bot';
  body: { endpoint: 'quenderin-roster'; payload: { schemaVersion: 1; workspaceId: string } };
}
export interface BotRosterValue {
  schemaVersion: 1; workspaceId: string; revision: number; readOnly: boolean;
  bots: Array<{ id: string; name: string; sessionId: string; model: string | null; permission: string | null }>;
}
export interface BotReadError {
  code: 'BOT_READ_INVALID_REQUEST' | 'BOT_READ_UNAVAILABLE' | 'BOT_READ_INVALID_RESPONSE';
  message: 'Bot roster read unavailable';
}
export type BotReadValidation<T> = { ok: true; value: T } | { ok: false; error: BotReadError };
export type BotReadSuccess = { status: 200; json: { ok: true; value: BotRosterValue } };
export type BotReadFailure = { status: 400 | 503; json: { ok: false; error: BotReadError } };
export function validateBotReadRequest(params: unknown, expectedWorkspaceId: unknown): BotReadValidation<BotReadRequest>;
export function projectBotReadSnapshot(source: unknown, expectedWorkspaceId: unknown): BotReadSuccess | BotReadFailure;
export function handleBotReadRequest(params: unknown, source: unknown, expectedWorkspaceId: unknown): BotReadSuccess | BotReadFailure;
export function validateBotReadResponse(result: unknown, expectedWorkspaceId: unknown): BotReadValidation<BotReadSuccess>;
