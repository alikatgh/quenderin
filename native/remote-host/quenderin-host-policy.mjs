import { createHash, timingSafeEqual } from 'node:crypto';
import { constants, openSync, closeSync, fstatSync, readFileSync } from 'node:fs';

export const APPROVAL_CAPABILITY = 'quenderin.approvals.v1';
export const APPROVAL_ENDPOINT = 'quenderin/approval';
const MAX_BYTES = 65536;
const MAX_PENDING = 32;
const TTL_MS = 120000;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= 1024 && !value.includes('\0');
const fail = () => { throw new Error('Quenderin Host authorization unavailable'); };

/** Public identities only. This is deliberately independent of provider credentials. */
export function assertPeerAllowed(deviceId, publicKey, path = process.env.QUENDERIN_REMOTE_TRUST_FILE) {
  if (!text(deviceId) || typeof publicKey !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(publicKey)
      || Buffer.from(publicKey, 'base64url').toString('base64url') !== publicKey
      || typeof path !== 'string' || !path.startsWith('/')) fail();
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  let bytes;
  try {
    const stat = fstatSync(descriptor);
    if (!stat.isFile() || stat.size > MAX_BYTES || (stat.mode & 0o022) !== 0
        || (typeof process.getuid === 'function' && stat.uid !== process.getuid())) fail();
    bytes = readFileSync(descriptor);
  } finally { closeSync(descriptor); }
  if (bytes.length > MAX_BYTES) fail();
  const config = JSON.parse(bytes.toString('utf8'));
  if (!record(config) || config.version !== 1 || !Array.isArray(config.peers) || config.peers.length > 64) fail();
  const matches = config.peers.filter(peer => record(peer) && peer.deviceId === deviceId);
  if (matches.length !== 1 || matches[0].publicKey !== publicKey) fail();
}

/** Stable JSON for an action digest; refuses oversized, cyclic or non-JSON values. */
export function actionDigest(request) {
  let nodes = 0;
  const visit = (value, depth) => {
    if (++nodes > 8192 || depth > 32) fail();
    if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (Array.isArray(value)) return value.map(item => visit(item, depth + 1));
    if (!record(value)) fail();
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, visit(value[key], depth + 1)]));
  };
  const encoded = JSON.stringify(visit(request, 0));
  if (Buffer.byteLength(encoded) > MAX_BYTES) fail();
  return createHash('sha256').update(encoded).digest('hex');
}

const BINDING_KEYS = ['actionDigest', 'clientDeviceId', 'eventId', 'expiresAt', 'hostDeviceId', 'runId', 'sessionId', 'workspaceId'];
const sameBinding = (left, right) => record(left) && Object.keys(left).sort().join(',') === BINDING_KEYS.join(',')
  && BINDING_KEYS.every(key => left[key] === right[key]);

/** One instance per authenticated peer connection. No durable replay of approval capabilities. */
export class QuenderinApprovalPolicy {
  #host; #client; #clock; #monotonic; #lastMono; #workspaces = new Map(); #turns = new Map();
  #pending = new Map(); #seen = new Set(); #clientId; #closed = false;
  constructor(hostDeviceId, clientDeviceId, clock = Date.now, monotonic = () => performance.now()) {
    if (!text(hostDeviceId) || !text(clientDeviceId)) fail();
    this.#host = hostDeviceId; this.#client = clientDeviceId; this.#clock = clock; this.#monotonic = monotonic;
    this.#lastMono = this.#nowMono();
  }
  #nowMono() {
    const now = this.#monotonic();
    if (!Number.isFinite(now) || now < 0 || (this.#lastMono !== undefined && now < this.#lastMono)) {
      this.close(); fail();
    }
    this.#lastMono = now;
    return now;
  }
  #prune() {
    if (this.#closed) fail();
    const now = this.#nowMono();
    for (const [id, entry] of this.#pending) if (now >= entry.deadline) this.#pending.delete(id);
    return now;
  }
  #invalidateSession(sessionId) {
    for (const [id, entry] of this.#pending) if (entry.binding.sessionId === sessionId) this.#pending.delete(id);
  }
  #turn(sessionId, event) {
    if (!record(event) || !record(event.data)) return;
    if (event.type === 'turn/end') {
      this.#turns.delete(sessionId); this.#invalidateSession(sessionId);
    } else if (event.type === 'turn/start' && Number.isSafeInteger(event.data.turn) && event.data.turn >= 0) {
      const run = `turn:${event.data.turn}`;
      if (this.#turns.get(sessionId) !== run) this.#invalidateSession(sessionId);
      this.#turns.set(sessionId, run);
    }
  }
  /** Observe only frames emitted by the local official Gateway, never a client payload. */
  observe(endpoint, payload, value) {
    this.#prune();
    if (!record(value)) return value;
    if (endpoint === 'workspace/follow') {
      if (['baseline', 'replace'].includes(value.type) && record(value.value) && Array.isArray(value.value.items)) {
        if (value.value.items.length > 1024) fail();
        const next = new Map();
        for (const workspace of value.value.items) {
          if (!record(workspace) || !text(workspace.workspaceId) || !Array.isArray(workspace.sessionIds)
              || workspace.sessionIds.length > 4096) fail();
          for (const session of workspace.sessionIds) {
            if (!text(session) || next.has(session) || next.size >= 4096) fail();
            next.set(session, workspace.workspaceId);
          }
        }
        for (const [session, workspace] of this.#workspaces) if (next.get(session) !== workspace) this.#invalidateSession(session);
        this.#workspaces = next;
      } else if (value.type === 'upsert' && record(value.workspace) && text(value.workspace.workspaceId)
          && Array.isArray(value.workspace.sessionIds) && value.workspace.sessionIds.length <= 4096) {
        const next = new Map(this.#workspaces);
        for (const [session, workspace] of next) if (workspace === value.workspace.workspaceId) next.delete(session);
        for (const session of value.workspace.sessionIds) {
          if (!text(session) || (next.has(session) && next.get(session) !== value.workspace.workspaceId)) fail();
          next.set(session, value.workspace.workspaceId);
        }
        if (next.size > 4096) fail();
        for (const [session, workspace] of this.#workspaces) if (next.get(session) !== workspace) this.#invalidateSession(session);
        this.#workspaces = next;
      } else if (value.type === 'remove' && text(value.workspaceId)) {
        for (const [session, workspace] of this.#workspaces) if (workspace === value.workspaceId) {
          this.#workspaces.delete(session); this.#invalidateSession(session);
        }
      } else if (!['order', 'archived', 'pinned'].includes(value.type)) {
        // Unknown change formats cannot preserve an authorization claim.
        this.#workspaces.clear(); this.#pending.clear();
      }
    }
    if (endpoint === 'session/follow') {
      const session = payload?.args?.request?.address?.sessionId;
      if (!text(session)) fail();
      if (value.type === 'snapshot') {
        this.#turns.delete(session); this.#invalidateSession(session);
        const records = value.records;
        if (!Array.isArray(records) || records.length > 8192) fail();
        for (const item of records) if (record(item) && item.type === 'event') this.#turn(session, item.event);
        const active = value.assistantStream?.activeAttempt;
        if (record(active) && Number.isSafeInteger(active.turn) && active.turn >= 0) this.#turns.set(session, `turn:${active.turn}`);
      } else if (value.type === 'event') this.#turn(session, value.event);
    }
    if (endpoint !== '$events') return value;
    if (value.type === 'ready') {
      if (!text(value.clientId)) fail();
      this.#pending.clear(); this.#clientId = value.clientId;
    } else if (value.type === 'cancel' && text(value.eventId)) this.#pending.delete(value.eventId);
    else if (value.type === 'waterfall' && value.event === 'approval/request') {
      const session = value.agentId, eventId = value.eventId;
      if (this.#seen.has(eventId)) { this.#pending.delete(eventId); return value; }
      const workspace = this.#workspaces.get(session), run = this.#turns.get(session);
      if (!text(session) || !text(eventId) || !workspace || !run || !this.#clientId || !record(value.request)) return value;
      if (this.#seen.size >= 4096 || this.#pending.size >= MAX_PENDING) fail();
      const epoch = this.#clock();
      if (!Number.isSafeInteger(epoch) || epoch <= 0 || !Number.isSafeInteger(epoch + TTL_MS)) fail();
      const binding = Object.freeze({hostDeviceId:this.#host, clientDeviceId:this.#client, workspaceId:workspace,
        sessionId:session, runId:run, eventId, actionDigest:actionDigest(value.request), expiresAt:epoch + TTL_MS});
      this.#seen.add(eventId);
      this.#pending.set(eventId, {binding, clientId:this.#clientId, deadline:this.#nowMono() + TTL_MS});
      // Never mutate the Gateway's own action object or add client-supplied context.
      return {...value, quenderinBinding:binding};
    }
    return value;
  }
  /** Consume before the first await. Any lost acknowledgement requires reconciliation. */
  consume(input) {
    this.#prune();
    if (!record(input) || Object.keys(input).sort().join(',') !== 'binding,clientId,outcome'
        || !record(input.binding) || !record(input.outcome)
        || Object.keys(input.outcome).sort().join(',') !== 'kind,value'
        || input.outcome.kind !== 'result' || !['allowed-once', 'rejected'].includes(input.outcome.value)) fail();
    const entry = this.#pending.get(input.binding.eventId);
    if (!entry || !sameBinding(input.binding, entry.binding) || input.clientId !== entry.clientId
        || this.#turns.get(entry.binding.sessionId) !== entry.binding.runId
        || this.#workspaces.get(entry.binding.sessionId) !== entry.binding.workspaceId) fail();
    // Compare an encoded digest too, keeping this check independent of presentation.
    const left = Buffer.from(input.binding.actionDigest, 'hex'), right = Buffer.from(entry.binding.actionDigest, 'hex');
    if (left.length !== 32 || right.length !== 32 || !timingSafeEqual(left, right)) fail();
    this.#pending.delete(entry.binding.eventId);
    return {args:{clientId:entry.clientId,eventId:entry.binding.eventId,outcome:{...input.outcome}}};
  }
  streamClosed(endpoint) {
    if (endpoint === '$events' || endpoint === 'workspace/follow' || endpoint === 'session/follow') {
      this.#pending.clear(); this.#turns.clear();
      if (endpoint === '$events') this.#clientId = undefined;
      if (endpoint === 'workspace/follow') this.#workspaces.clear();
    }
  }
  close() { this.#closed = true; this.#pending.clear(); this.#seen.clear(); this.#turns.clear(); this.#workspaces.clear(); this.#clientId = undefined; }
}
