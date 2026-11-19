import { isPlainBotReadRecord } from './quenderin-bot-read-policy.mjs';

export const BOT_WORK_CAPABILITY = 'quenderin.bot.work.v1';
export const BOT_WORK_ENDPOINTS = Object.freeze(['quenderin-submit', 'quenderin-command']);
export const BOT_WORK_LIMITS = Object.freeze({ identityUTF8Bytes: 1024, commandIdUTF8Bytes: 128,
  textUTF8Bytes: 16384, requestUTF8Bytes: 32768, resultUTF8Bytes: 8192,
  journalRecords: 1024, pendingPerBot: 1, pendingTotal: 32, promptCallsPerCommand: 1,
  dispatchTimeoutMilliseconds: 30000, revisionMaximum: Number.MAX_SAFE_INTEGER });
export const BOT_WORK_REASONS = Object.freeze(['staleSession', 'staleRevision', 'unavailable', 'readOnly',
  'revoked', 'wrongScope', 'payloadConflict', 'capacity', 'storageFailure', 'dispatchUncertain', 'invalidRequest']);
const STATES = Object.freeze(['accepted', 'rejected', 'uncertain', 'notFound']);
export const BOT_WORK_RECEIPT_KEYS = Object.freeze(['schemaVersion', 'workspaceId', 'botId', 'commandId', 'sessionId', 'revision', 'state', 'reason']);
const STATUS_KEYS = ['schemaVersion', 'workspaceId', 'botId', 'commandId'];
const SUBMIT_KEYS = ['schemaVersion', 'workspaceId', 'botId', 'expectedSessionId', 'expectedRevision', 'commandId', 'text'];
const fail = () => { throw new Error('Invalid Bot work value'); };
export function botWorkFields(value, keys) {
  if (!isPlainBotReadRecord(value)) fail();
  const actual = Reflect.ownKeys(value);
  if (actual.length !== keys.length || actual.some(key => !keys.includes(key))) fail();
  const result = {};
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || !descriptor.enumerable) fail();
    result[key] = descriptor.value;
  }
  return result;
}
export function botWorkScalar(value, maximum = BOT_WORK_LIMITS.identityUTF8Bytes) {
  if (typeof value !== 'string' || !value || value.length > maximum || !value.isWellFormed()
    || value.includes('\0') || Buffer.byteLength(value, 'utf8') > maximum) fail();
  return value;
}
const revision = value => Number.isSafeInteger(value) && value >= 0;
const bounded = (value, maximum) => { if (Buffer.byteLength(JSON.stringify(value), 'utf8') > maximum) fail(); return value; };
export function validateBotWorkRequest(params) {
  try {
    const request = botWorkFields(params, ['route', 'body']);
    const body = botWorkFields(request.body, ['endpoint', 'payload']);
    if (request.route !== 'api/bot' || !BOT_WORK_ENDPOINTS.includes(body.endpoint)) fail();
    const payload = botWorkFields(body.payload, body.endpoint === 'quenderin-submit' ? SUBMIT_KEYS : STATUS_KEYS);
    if (payload.schemaVersion !== 1) fail();
    for (const key of ['workspaceId', 'botId']) botWorkScalar(payload[key]);
    botWorkScalar(payload.commandId, BOT_WORK_LIMITS.commandIdUTF8Bytes);
    if (body.endpoint === 'quenderin-submit') {
      botWorkScalar(payload.expectedSessionId);
      if (!revision(payload.expectedRevision)) fail();
      botWorkScalar(payload.text, BOT_WORK_LIMITS.textUTF8Bytes);
      if (!payload.text.trim()) fail();
    }
    return { ok: true, value: bounded({ route: 'api/bot', body: { endpoint: body.endpoint, payload } }, BOT_WORK_LIMITS.requestUTF8Bytes) };
  } catch { return { ok: false }; }
}
export function botWorkReceipt(payload, state, reason = null, sessionId = null, currentRevision = null) {
  return { schemaVersion: 1, workspaceId: payload.workspaceId, botId: payload.botId,
    commandId: payload.commandId, sessionId, revision: currentRevision, state, reason };
}
export function botWorkResponse(receipt) { return { status: 200, json: { ok: true, value: receipt } }; }
export function botWorkUnavailable() {
  return { status: 503, json: { ok: false, error: { code: 'BOT_WORK_UNAVAILABLE', message: 'Bot work unavailable' } } };
}
export function validateBotWorkResponse(result, request) {
  try {
    const checked = validateBotWorkRequest(request);
    if (!checked.ok) fail();
    const outer = botWorkFields(result, ['status', 'json']), json = botWorkFields(outer.json, ['ok', 'value']);
    if (outer.status !== 200 || json.ok !== true) fail();
    const value = botWorkFields(json.value, BOT_WORK_RECEIPT_KEYS), payload = checked.value.body.payload;
    if (value.schemaVersion !== 1 || ['workspaceId', 'botId', 'commandId'].some(key => value[key] !== payload[key])
      || !STATES.includes(value.state) || (value.reason !== null && !BOT_WORK_REASONS.includes(value.reason))) fail();
    if (value.sessionId !== null) botWorkScalar(value.sessionId);
    if (value.revision !== null && !revision(value.revision)) fail();
    if ((value.sessionId === null) !== (value.revision === null)) fail();
    if (value.state === 'accepted' && (value.sessionId === null || value.reason !== null)) fail();
    if (value.state === 'notFound' && (value.sessionId !== null || value.reason !== null)) fail();
    if (value.state === 'rejected' && (value.reason === null || value.sessionId !== null || value.revision !== null)) fail();
    if (checked.value.body.endpoint === 'quenderin-submit' && ['accepted', 'uncertain'].includes(value.state)
      && (value.sessionId !== payload.expectedSessionId || value.revision !== payload.expectedRevision)) fail();
    if (value.state === 'uncertain' && (value.sessionId === null || value.reason !== 'dispatchUncertain')) fail();
    return { ok: true, value: bounded(botWorkResponse(value), BOT_WORK_LIMITS.resultUTF8Bytes) };
  } catch { return { ok: false }; }
}
