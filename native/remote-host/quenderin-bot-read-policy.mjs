import { types } from 'node:util';

// Source foundation only: importing this module installs no route or capability.
export const BOT_READ_CAPABILITY = 'quenderin.bot.read.v1';
export const BOT_READ_CARRIER_CAPABILITY = 'plugin.route.v1';
export const BOT_READ_ROUTE = 'api/bot';
export const BOT_READ_ENDPOINT = 'quenderin-roster';
export const BOT_READ_LIMITS = Object.freeze({
  requestUTF8Bytes: 4096, resultUTF8Bytes: 262144, bots: 100,
  identityUTF8Bytes: 1024, nameUTF8Bytes: 256, modelUTF8Bytes: 256,
  permissionUTF8Bytes: 64, revisionMaximum: Number.MAX_SAFE_INTEGER,
});

const INVALID = Symbol('invalid bot read');
const MESSAGE = 'Bot roster read unavailable';
const SOURCE_KEYS = ['ready', 'workspaceId', 'revision', 'readOnly', 'bots'];
const VALUE_KEYS = ['schemaVersion', 'workspaceId', 'revision', 'readOnly', 'bots'];
const BOT_KEYS = ['id', 'name', 'sessionId', 'model', 'permission'];
const OBJECT_CONSTRUCTOR_SOURCE = Function.prototype.toString.call(Object);
const reject = () => { throw INVALID; };
const error = code => ({ code, message: MESSAGE });
const failure = code => ({ ok: false, error: error(code) });
const failedResponse = (status, code) => ({ status, json: failure(code) });

// JSON records can originate in another plugin-loader realm. Verify only their
// genuine Object/null prototype here; required own data and exact-key checks
// remain separate so source-only private getters are still ignored.
export function isPlainBotReadRecord(value) {
  if (value === null || typeof value !== 'object' || types.isProxy(value) || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  if (prototype === null) return true;
  if (types.isProxy(prototype) || Object.getPrototypeOf(prototype) !== null) return false;
  const constructor = Object.getOwnPropertyDescriptor(prototype, 'constructor');
  if (!constructor || !Object.hasOwn(constructor, 'value') || typeof constructor.value !== 'function'
    || types.isProxy(constructor.value)) return false;
  const backlink = Object.getOwnPropertyDescriptor(constructor.value, 'prototype');
  return !!backlink && Object.hasOwn(backlink, 'value') && backlink.value === prototype
    && Function.prototype.toString.call(constructor.value) === OBJECT_CONSTRUCTOR_SOURCE;
}

// Do not coerce values, invoke accessors, or inspect the values of extra fields.
function fields(value, required, exact = false) {
  if (!isPlainBotReadRecord(value)) reject();
  if (exact) {
    const keys = Reflect.ownKeys(value);
    if (keys.length !== required.length || keys.some(key => !required.includes(key))) reject();
  }
  const result = Object.create(null);
  for (const key of required) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || (exact && !descriptor.enumerable)) reject();
    result[key] = descriptor.value;
  }
  return result;
}

// Count UTF-8 explicitly: lone UTF-16 surrogates must not become replacement bytes.
function scalarBytes(value, maximum, nonempty = true) {
  if (typeof value !== 'string' || (nonempty && value.length === 0) || value.length > maximum) reject();
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit === 0) reject();
    if (unit < 0x80) bytes++;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) reject();
      bytes += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) reject();
    else bytes += 3;
    if (bytes > maximum) reject();
  }
  return bytes;
}

function workspace(value) {
  scalarBytes(value, BOT_READ_LIMITS.identityUTF8Bytes);
  return value;
}

function serializedWithin(value, maximum) {
  // Only freshly projected plain JSON reaches serialization, never raw input.
  scalarBytes(JSON.stringify(value), maximum);
  return value;
}

function botArray(value, exact) {
  if (value === null || typeof value !== 'object' || types.isProxy(value) || !Array.isArray(value)) reject();
  const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  if (!lengthDescriptor || !Object.hasOwn(lengthDescriptor, 'value')) reject();
  const length = lengthDescriptor.value;
  if (!Number.isSafeInteger(length) || length < 0 || length > BOT_READ_LIMITS.bots) reject();
  if (exact) {
    const keys = Reflect.ownKeys(value);
    if (keys.length !== length + 1 || keys.some(key => key !== 'length'
        && (typeof key !== 'string' || !/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= length))) reject();
  }
  const bots = [], botIds = new Set(), sessionIds = new Set();
  for (let index = 0; index < length; index++) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || (exact && !descriptor.enumerable)) reject();
    const bot = fields(descriptor.value, BOT_KEYS, exact);
    scalarBytes(bot.id, BOT_READ_LIMITS.identityUTF8Bytes);
    scalarBytes(bot.sessionId, BOT_READ_LIMITS.identityUTF8Bytes);
    scalarBytes(bot.name, BOT_READ_LIMITS.nameUTF8Bytes);
    if (bot.model !== null) scalarBytes(bot.model, BOT_READ_LIMITS.modelUTF8Bytes);
    if (bot.permission !== null) scalarBytes(bot.permission, BOT_READ_LIMITS.permissionUTF8Bytes);
    if (botIds.has(bot.id) || sessionIds.has(bot.sessionId)) reject();
    botIds.add(bot.id); sessionIds.add(bot.sessionId);
    bots.push({ id: bot.id, name: bot.name, sessionId: bot.sessionId, model: bot.model, permission: bot.permission });
  }
  return bots;
}

function roster(value, expectedWorkspaceId, exact) {
  const snapshot = fields(value, exact ? VALUE_KEYS : SOURCE_KEYS, exact);
  if ((exact ? snapshot.schemaVersion !== 1 : snapshot.ready !== true) || typeof snapshot.readOnly !== 'boolean') reject();
  workspace(snapshot.workspaceId);
  if (snapshot.workspaceId !== expectedWorkspaceId || !Number.isSafeInteger(snapshot.revision)
      || snapshot.revision < 0 || snapshot.revision > BOT_READ_LIMITS.revisionMaximum) reject();
  return { schemaVersion: 1, workspaceId: snapshot.workspaceId, revision: snapshot.revision,
    readOnly: snapshot.readOnly, bots: botArray(snapshot.bots, exact) };
}

/** Exact materialized route request. The transport must separately cap raw wire bytes. */
export function validateBotReadRequest(params, expectedWorkspaceId) {
  try {
    workspace(expectedWorkspaceId);
    const request = fields(params, ['route', 'body'], true);
    const body = fields(request.body, ['endpoint', 'payload'], true);
    const payload = fields(body.payload, ['schemaVersion', 'workspaceId'], true);
    if (request.route !== BOT_READ_ROUTE || body.endpoint !== BOT_READ_ENDPOINT || payload.schemaVersion !== 1) reject();
    workspace(payload.workspaceId);
    if (payload.workspaceId !== expectedWorkspaceId) reject();
    const value = { route: BOT_READ_ROUTE, body: { endpoint: BOT_READ_ENDPOINT,
      payload: { schemaVersion: 1, workspaceId: payload.workspaceId } } };
    return { ok: true, value: serializedWithin(value, BOT_READ_LIMITS.requestUTF8Bytes) };
  } catch {
    return failure('BOT_READ_INVALID_REQUEST');
  }
}

/** Passive projection only; callers must supply already-current authoritative ownership. */
export function projectBotReadSnapshot(source, expectedWorkspaceId) {
  try {
    workspace(expectedWorkspaceId);
    const value = roster(source, expectedWorkspaceId, false);
    return serializedWithin({ status: 200, json: { ok: true, value } }, BOT_READ_LIMITS.resultUTF8Bytes);
  } catch {
    return failedResponse(503, 'BOT_READ_UNAVAILABLE');
  }
}

/** Pure route boundary for a future explicitly installed Host adapter. */
export function handleBotReadRequest(params, source, expectedWorkspaceId) {
  const request = validateBotReadRequest(params, expectedWorkspaceId);
  if (!request.ok) return failedResponse(400, 'BOT_READ_INVALID_REQUEST');
  return projectBotReadSnapshot(source, expectedWorkspaceId);
}

/** Strict success-envelope check, also shared by the portable contract fixtures. */
export function validateBotReadResponse(result, expectedWorkspaceId) {
  try {
    workspace(expectedWorkspaceId);
    const response = fields(result, ['status', 'json'], true);
    const json = fields(response.json, ['ok', 'value'], true);
    if (response.status !== 200 || json.ok !== true) reject();
    const value = roster(json.value, expectedWorkspaceId, true);
    const projected = { status: 200, json: { ok: true, value } };
    return { ok: true, value: serializedWithin(projected, BOT_READ_LIMITS.resultUTF8Bytes) };
  } catch {
    return failure('BOT_READ_INVALID_RESPONSE');
  }
}
