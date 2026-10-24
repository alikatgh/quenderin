import { types } from 'node:util';
import { BOT_READ_CAPABILITY, BOT_READ_LIMITS, isPlainBotReadRecord, projectBotReadSnapshot, validateBotReadRequest } from './quenderin-bot-read-policy.mjs';

// Both pinned plugins share a connection service, not an invented ds-bot service.
// The marker is an in-process compatibility/lifecycle seam, never an auth token.
const MOUNT = Symbol.for('quenderin.bot.read.mounted.v1');
const BOT_PIN = '1bebe826f74e9a72cabafd3b80602b05af867b38';
const unavailable = () => ({ status: 503, json: { ok: false, error: { code: 'BOT_READ_UNAVAILABLE', message: 'Bot roster read unavailable' } } });
const invalid = () => ({ status: 400, json: { ok: false, error: { code: 'BOT_READ_INVALID_REQUEST', message: 'Bot roster read unavailable' } } });
function own(value, key, optional = false) {
  if (value === null || typeof value !== 'object' || types.isProxy(value)) throw new Error('Unavailable');
  const descriptor = Object.getOwnPropertyDescriptor(value, key);
  if (descriptor === undefined && optional) return undefined;
  if (!descriptor || !Object.hasOwn(descriptor, 'value')) throw new Error('Unavailable');
  return descriptor.value;
}

// Ownership tables additionally reject accessors, while source projection is
// intentionally allowed to ignore private extra getters.
function plainRuntimeRecord(value) {
  if (!isPlainBotReadRecord(value)) return false;
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) return false;
  }
  return true;
}

/** Mounted only by the real pinned channel.install(rt). No load or execution. */
export function mountBotRead(rt) {
  const connection = rt.ctx.connection;
  let active = false, highestRevision = -1, readPhase = 'binding';
  const read = params => {
    readPhase = 'binding';
    try {
      if (!active || mountedBotRead(connection)?.read !== read) return unavailable();
      readPhase = 'state';
      const state = own(rt, 'state');
      const teamWorkspaceId = own(state, 'workspaceId');
      readPhase = 'request';
      const workspaceId = own(own(own(params, 'body'), 'payload'), 'workspaceId');
      if (!validateBotReadRequest(params, workspaceId).ok) return invalid();
      // This function is added to the pinned store and reads cached scalars only.
      readPhase = 'readiness';
      const status = rt.quenderinReadStatus?.();
      if (status?.ready !== true || typeof status.readOnly !== 'boolean') return unavailable();
      readPhase = 'revision';
      const revision = own(state, 'revision');
      if (!Number.isSafeInteger(revision) || revision < 0 || revision < highestRevision) return unavailable();
      readPhase = 'workspace';
      const workspace = rt.ctx.workspaceRegistry.get(teamWorkspaceId);
      if (workspace?.id !== teamWorkspaceId) return unavailable();
      const requestedWorkspace = workspaceId === teamWorkspaceId ? workspace : rt.ctx.workspaceRegistry.get(workspaceId);
      if (requestedWorkspace?.id !== workspaceId) return invalid();
      // Official rc.1 getter uses its already-built canonical-cwd header index;
      // it does not load persistence, resolve an Agent, or create a workspace.
      readPhase = 'membership';
      const members = workspace.sessionIds;
      if (!Array.isArray(members)) return unavailable();
      readPhase = 'bot-fields';
      const table = own(state, 'bots');
      if (types.isProxy(table) || table === null || typeof table !== 'object' || Array.isArray(table)) return unavailable();
      const keys = Reflect.ownKeys(table);
      if (keys.length > BOT_READ_LIMITS.bots || keys.some(key => typeof key !== 'string')) return unavailable();
      readPhase = 'owners';
      const owners = own(rt, 'chatOwners');
      if (types.isProxy(owners) || !types.isMap(owners)) return unavailable();
      const bots = [];
      for (const key of keys) {
        readPhase = 'bot-fields';
        const bot = own(table, key), id = own(bot, 'id');
        const sessionId = own(bot, 'sessionId', true) ?? id;
        if (id !== key) return unavailable();
        readPhase = 'owners';
        if (Map.prototype.get.call(owners, sessionId) !== id) return unavailable();
        readPhase = 'membership';
        if (!members.includes(sessionId)) return unavailable();
        readPhase = 'bot-fields';
        bots.push({ id, name: own(bot, 'name'), sessionId,
          model: own(bot, 'model', true) ?? null, permission: own(bot, 'permission', true) ?? null });
      }
      readPhase = 'projection';
      const teamResponse = projectBotReadSnapshot({ ready: true, workspaceId: teamWorkspaceId, revision, readOnly: status.readOnly, bots }, teamWorkspaceId);
      if (teamResponse.status !== 200) return teamResponse;
      // A Host-wide capability also serves ordinary authenticated workspaces.
      // Their authoritative empty result classifies ordinary Harness sessions
      // without exporting any other workspace's Bot identifiers or metadata.
      const response = workspaceId === teamWorkspaceId ? teamResponse
        : projectBotReadSnapshot({ ready: true, workspaceId, revision, readOnly: status.readOnly, bots: [] }, workspaceId);
      readPhase = 'state-changed';
      if (state !== own(rt, 'state') || own(state, 'revision') !== revision || !active) return unavailable();
      if (response.status === 200) { highestRevision = revision; readPhase = 'ready'; }
      else readPhase = 'projection';
      return response;
    } catch { return unavailable(); }
  };
  const sessionWritable = sessionId => {
    try {
      if (!active || typeof sessionId !== 'string' || !sessionId) return false;
      const status = rt.quenderinReadStatus?.(), state = own(rt, 'state'), revision = own(state, 'revision');
      if (status?.ready !== true || !Number.isSafeInteger(revision) || revision < 0 || revision < highestRevision) return false;
      const bots = own(state, 'bots'), currentOwners = own(rt, 'chatOwners');
      if (types.isProxy(bots) || bots === null || typeof bots !== 'object' || Array.isArray(bots)
        || types.isProxy(currentOwners) || !types.isMap(currentOwners)) return false;
      const keys = Reflect.ownKeys(bots);
      if (keys.length > BOT_READ_LIMITS.bots) return false;
      for (const key of keys) {
        const bot = own(bots, key), id = own(bot, 'id'), current = own(bot, 'sessionId', true) ?? id;
        if (id !== key || Map.prototype.get.call(currentOwners, current) !== id || sessionId === id || sessionId === current) return false;
      }
      // A room's root Session runs its coordinator/relay loop. It is distinct
      // from the hidden per-member Sessions indexed in groupOwners/pastOwners.
      const rooms = own(state, 'rooms');
      if (!plainRuntimeRecord(rooms)) return false;
      for (const key of Reflect.ownKeys(rooms)) {
        const room = own(rooms, key);
        if (!plainRuntimeRecord(room)) return false;
        const id = own(room, 'id');
        if (typeof id !== 'string' || !id
          || id.length > BOT_READ_LIMITS.identityUTF8Bytes || !id.isWellFormed() || id.includes('\0')
          || Buffer.byteLength(id, 'utf8') > BOT_READ_LIMITS.identityUTF8Bytes || id !== key || sessionId === id) return false;
      }
      for (const key of ['chatOwners', 'groupOwners', 'pastOwners']) {
        const map = own(rt, key);
        if (types.isProxy(map) || !types.isMap(map) || Map.prototype.has.call(map, sessionId)) return false;
      }
      return true;
    } catch { return false; }
  };
  // Host-only diagnosis of the most recent read: fixed enums, never runtime data
  // or exception text. This method is not registered as a route or capability.
  const adapter = Object.freeze({ capability: BOT_READ_CAPABILITY, botRevision: BOT_PIN, read,
    readDiagnostic: () => readPhase, sessionWritable, mounted: () => active });
  rt.ctx.effect(() => {
    if (Object.hasOwn(connection, MOUNT)) throw new Error('A Bot roster adapter is already mounted');
    Object.defineProperty(connection, MOUNT, { value: adapter, configurable: true });
    active = true;
    return () => { active = false; if (Object.getOwnPropertyDescriptor(connection, MOUNT)?.value === adapter) delete connection[MOUNT]; };
  }, 'quenderin: already-mounted Bot roster');
  return read;
}

/** Capability is present only while this exact adapter lifecycle is mounted. */
export function mountedBotRead(connection) {
  if (connection === null || (typeof connection !== 'object' && typeof connection !== 'function')) return undefined;
  const adapter = Object.getOwnPropertyDescriptor(connection, MOUNT)?.value;
  return adapter?.capability === BOT_READ_CAPABILITY && adapter.botRevision === BOT_PIN
    && typeof adapter.read === 'function' && adapter.mounted?.() === true ? adapter : undefined;
}

/** Plain Harness remains available; a mounted Bot keeps ownership of its parts. */
export function botSessionWritable(connection, sessionId) {
  const adapter = mountedBotRead(connection);
  return adapter === undefined ? true : adapter.sessionWritable(sessionId);
}

export { unavailable as botReadUnavailable };
