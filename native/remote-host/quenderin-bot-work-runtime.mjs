import { createHash } from 'node:crypto';
import { types } from 'node:util';
import { mountedBotRead } from './quenderin-bot-runtime.mjs';
import { BotWorkJournal, botWorkPayloadDigest } from './quenderin-bot-work-journal.mjs';
import { BOT_WORK_CAPABILITY, BOT_WORK_LIMITS, botWorkScalar, botWorkReceipt, botWorkResponse,
  botWorkUnavailable, validateBotWorkRequest, validateBotWorkResponse } from './quenderin-bot-work-policy.mjs';

const MOUNT = Symbol.for('quenderin.bot.work.mounted.v1');
const BOT_PIN = '1bebe826f74e9a72cabafd3b80602b05af867b38';
const own = (value, key) => {
  if (value === null || (typeof value !== 'object' && typeof value !== 'function') || types.isProxy(value)) throw new Error('Unavailable');
  const field = Object.getOwnPropertyDescriptor(value, key);
  if (!field || !Object.hasOwn(field, 'value')) throw new Error('Unavailable');
  return field.value;
};
function scopeValid(scope) {
  try {
    botWorkScalar(own(scope, 'hostDeviceId')); botWorkScalar(own(scope, 'peerDeviceId'));
    return /^[a-f0-9]{64}$/.test(own(scope, 'peerKeySHA256')) && typeof own(scope, 'assertAuthorized') === 'function';
  } catch { return false; }
}
/** Created only by the Remote service from its authenticated channel context. */
export function createBotWorkScope(hostDeviceId, peerDeviceId, peerIdentityKey, assertAuthorized) {
  botWorkScalar(hostDeviceId); botWorkScalar(peerDeviceId);
  if (typeof peerIdentityKey !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(peerIdentityKey)
    || Buffer.from(peerIdentityKey, 'base64url').toString('base64url') !== peerIdentityKey || typeof assertAuthorized !== 'function') throw new Error('Unavailable');
  return Object.freeze({ hostDeviceId, peerDeviceId,
    peerKeySHA256: createHash('sha256').update(Buffer.from(peerIdentityKey, 'base64url')).digest('hex'), assertAuthorized });
}
function withAbort(pending, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => reject(new Error('Bot work deadline elapsed'));
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    Promise.resolve(pending).then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}

/** Does not load/bootstrap Bots or install providers. Only an explicit journal opts in. */
export function mountBotWork(rt, writer, options = {}) {
  const connection = rt.ctx.connection;
  const journal = options.journal ?? new BotWorkJournal(options.journalPath ?? process.env.QUENDERIN_BOT_WORK_JOURNAL);
  let active = false;
  const running = new Map();
  const compatible = () => writer?.botRevision === BOT_PIN && typeof writer.prepare === 'function'
    && typeof writer.prompt === 'function' && typeof rt.ensureCapabilities === 'function'
    && typeof rt.ctx.sessionController?.prompt === 'function' && typeof rt.ctx.on === 'function';
  const check = payload => {
    const reader = mountedBotRead(connection);
    if (!active || !reader || !compatible()) return { reason: 'unavailable' };
    const state = own(rt, 'state');
    if (own(state, 'workspaceId') !== payload.workspaceId) return { reason: 'wrongScope' };
    const result = reader.read({ route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: payload.workspaceId } } });
    if (result.status !== 200) return { reason: 'unavailable' };
    const roster = result.json.value;
    if (roster.readOnly) return { reason: 'readOnly' };
    const bot = roster.bots.find(item => item.id === payload.botId);
    if (!bot) return { reason: 'wrongScope' };
    if (bot.sessionId !== payload.expectedSessionId) return { reason: 'staleSession' };
    if (roster.revision !== payload.expectedRevision) return { reason: 'staleRevision' };
    return { sessionId: bot.sessionId, revision: roster.revision };
  };
  const ready = () => {
    try {
      if (!active || !compatible() || !journal.ready()) return false;
      const state = own(rt, 'state'), workspaceId = own(state, 'workspaceId');
      const reader = mountedBotRead(connection);
      if (!reader) return false;
      const result = reader.read({ route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId } } });
      return result.status === 200 && result.json.value.readOnly === false;
    } catch { return false; }
  };
  const reply = (payload, state, reason = null) => botWorkResponse(botWorkReceipt(payload, state, reason));
  const authorization = scope => { try { scope.assertAuthorized(); return true; } catch { return false; } };
  const rejectReservation = (entry, payload, reason) => {
    const receipt = botWorkReceipt(payload, 'rejected', reason);
    try { journal.transition(entry, receipt, false); running.delete(entry.requestId); return botWorkResponse(receipt); }
    catch { return botWorkResponse(entry.receipt); }
  };
  const call = async (params, scope, outerSignal = AbortSignal.timeout(BOT_WORK_LIMITS.dispatchTimeoutMilliseconds)) => {
    const parsed = validateBotWorkRequest(params);
    if (!parsed.ok) return { status: 400, json: { ok: false, error: { code: 'BOT_WORK_INVALID_REQUEST', message: 'Bot work unavailable' } } };
    const request = parsed.value, payload = request.body.payload;
    if (!active || mountedBotWork(connection) !== adapter || !scopeValid(scope)) return botWorkUnavailable();
    if (!authorization(scope)) return reply(payload, 'rejected', 'revoked');
    try {
      // Scope checks are runtime authority, independent of user-controlled payload IDs.
      const state = own(rt, 'state');
      if (own(state, 'workspaceId') !== payload.workspaceId || rt.ctx.workspaceRegistry.get(payload.workspaceId)?.id !== payload.workspaceId) return reply(payload, 'rejected', 'wrongScope');
      const existing = journal.lookup(scope, payload);
      if (request.body.endpoint === 'quenderin-command') return existing ? botWorkResponse(existing.receipt) : reply(payload, 'notFound');
      if (existing) return existing.digest === botWorkPayloadDigest(payload)
        ? botWorkResponse(existing.receipt) : reply(payload, 'rejected', 'payloadConflict');
      if (outerSignal.aborted) return reply(payload, 'rejected', 'unavailable');
      const before = check(payload);
      if (before.reason) return reply(payload, 'rejected', before.reason);
      // Ensure any valid request can produce a bounded receipt before reservation.
      if (!validateBotWorkResponse(botWorkResponse(botWorkReceipt(payload, 'accepted', null, before.sessionId, before.revision)), request).ok) return reply(payload, 'rejected', 'invalidRequest');
      const reservation = journal.reserve(scope, payload);
      if (reservation.kind === 'capacity') return reply(payload, 'rejected', 'capacity');
      if (reservation.kind === 'conflict') return reply(payload, 'rejected', 'payloadConflict');
      if (reservation.kind === 'duplicate') return botWorkResponse(reservation.entry.receipt);
      let entry = reservation.entry;
      const tracked = { entry, seen: false, settled: false, accepted: false }; running.set(entry.requestId, tracked);
      const signal = AbortSignal.any([outerSignal, AbortSignal.timeout(BOT_WORK_LIMITS.dispatchTimeoutMilliseconds)]);
      let dispatched = false;
      try {
        // Preparation uses the stock capability mechanism only after durable admission.
        if (!authorization(scope)) return rejectReservation(entry, payload, 'revoked');
        const immediatelyBefore = check(payload);
        if (immediatelyBefore.reason) return rejectReservation(entry, payload, immediatelyBefore.reason);
        await withAbort(writer.prepare(immediatelyBefore.sessionId, signal), signal);
        if (!authorization(scope)) return rejectReservation(entry, payload, 'revoked');
        if (signal.aborted) return rejectReservation(entry, payload, 'unavailable');
        const target = check(payload);
        if (target.reason) return rejectReservation(entry, payload, target.reason);
        if (target.sessionId !== entry.receipt.sessionId || target.revision !== entry.receipt.revision) return rejectReservation(entry, payload, 'staleSession');
        // One stock queue call with the durable Host-generated ID. Never resend it.
        dispatched = true;
        const acknowledgement = await withAbort(writer.prompt({ requestId: entry.requestId, sessionId: target.sessionId,
          mode: 'queue', content: [{ type: 'text', text: payload.text }] }, signal), signal);
        if (own(acknowledgement, 'accepted') !== true) throw new Error('Queue admission acknowledgement unavailable');
        const receipt = { ...entry.receipt, state: 'accepted', reason: null };
        entry = journal.transition(entry, receipt, !tracked.settled);
        tracked.entry = entry; tracked.accepted = true;
        if (tracked.settled) running.delete(entry.requestId);
        return botWorkResponse(receipt);
      } catch {
        if (!dispatched) return rejectReservation(entry, payload, 'unavailable');
        // An exception/timeout after the call began cannot establish non-execution.
        return botWorkResponse(entry.receipt);
      }
    } catch { return botWorkUnavailable(); }
  };
  const adapter = Object.freeze({ capability: BOT_WORK_CAPABILITY, botRevision: BOT_PIN, call, ready, mounted: () => active });
  rt.ctx.effect(() => {
    if (Object.hasOwn(connection, MOUNT)) throw new Error('A Bot work adapter is already mounted');
    Object.defineProperty(connection, MOUNT, { value: adapter, configurable: true }); active = true;
    return () => { active = false; running.clear(); if (Object.getOwnPropertyDescriptor(connection, MOUNT)?.value === adapter) delete connection[MOUNT]; };
  }, 'quenderin: existing Bot work queue');
  // Official runtime events alone settle a slot. A cancel response never does.
  if (typeof rt.ctx.on === 'function') rt.ctx.on('session/event', (session, event) => {
    if (!active || !session || !event) return;
    for (const [id, tracked] of running) {
      if (session.id !== tracked.entry.receipt.sessionId) continue;
      if (event.type === 'user/message' && event.data?.source?.rpcId === id) tracked.seen = true;
      if (event.type === 'turn/end' && tracked.seen) {
        tracked.settled = true;
        if (tracked.accepted) {
          try { tracked.entry = journal.transition(tracked.entry, tracked.entry.receipt, false); running.delete(id); }
          catch { /* Keep the durable pending slot on every storage failure. */ }
        }
      }
    }
  });
  return adapter;
}
export function mountedBotWork(connection) {
  if (connection === null || (typeof connection !== 'object' && typeof connection !== 'function') || types.isProxy(connection)) return undefined;
  const adapter = Object.getOwnPropertyDescriptor(connection, MOUNT)?.value;
  return adapter?.capability === BOT_WORK_CAPABILITY && adapter.botRevision === BOT_PIN
    && typeof adapter.call === 'function' && adapter.mounted?.() === true ? adapter : undefined;
}
