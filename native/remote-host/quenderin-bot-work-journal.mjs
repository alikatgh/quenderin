import * as filesystem from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { BOT_WORK_LIMITS, botWorkFields, botWorkScalar, botWorkReceipt, validateBotWorkResponse } from './quenderin-bot-work-policy.mjs';

const MARKER = '.initialized.json', LOCK = '.admission.lock';
const MAX_RECORD_BYTES = 98304, MAX_LINES = 3;
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const recordKeys = ['version', 'key', 'scope', 'digest', 'requestId', 'receipt', 'pending'];
const scopeKeys = ['hostDeviceId', 'peerDeviceId', 'peerKeySHA256'];
const failure = () => { throw new Error('Bot work journal unavailable'); };
function privateDirectory(path, fs) {
  if (typeof path !== 'string' || path !== resolve(path) || path === '/') failure();
  // Refuse symlinked ancestors as well as a linked final directory.
  for (let cursor = path; ; cursor = dirname(cursor)) {
    const stat = fs.lstatSync(cursor);
    if (!stat.isDirectory() || stat.isSymbolicLink()) failure();
    if (cursor === path && ((stat.mode & 0o077) !== 0 || (typeof process.getuid === 'function' && stat.uid !== process.getuid()))) failure();
    if (cursor === '/') return fs.lstatSync(path);
  }
}
function readBounded(path, maximum, fs) {
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > maximum || (stat.mode & 0o077) !== 0
      || (typeof process.getuid === 'function' && stat.uid !== process.getuid())) failure();
    const bytes = fs.readFileSync(fd);
    if (bytes.length !== stat.size || bytes.length > maximum) failure();
    const text = bytes.toString('utf8');
    if (!Buffer.from(text, 'utf8').equals(bytes)) failure();
    return text;
  } finally { fs.closeSync(fd); }
}
function writeAll(fd, content, fs) {
  const bytes = Buffer.from(content, 'utf8'); let offset = 0;
  while (offset < bytes.length) {
    const count = fs.writeSync(fd, bytes, offset, bytes.length - offset);
    if (!Number.isSafeInteger(count) || count <= 0) failure();
    offset += count;
  }
  fs.fsyncSync(fd);
}
function publicScope(scope) {
  for (const key of ['hostDeviceId', 'peerDeviceId']) botWorkScalar(scope[key]);
  if (typeof scope.peerKeySHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(scope.peerKeySHA256)) failure();
  return Object.fromEntries(scopeKeys.map(key => [key, scope[key]]));
}
const commandKey = (scope, payload) => hash([scope.hostDeviceId, scope.peerDeviceId, scope.peerKeySHA256, payload.workspaceId, payload.botId, payload.commandId]);
const botKey = entry => hash([entry.scope.hostDeviceId, entry.receipt.workspaceId, entry.receipt.botId]);
export const botWorkPayloadDigest = payload => hash([payload.schemaVersion, payload.workspaceId, payload.botId,
  payload.expectedSessionId, payload.expectedRevision, payload.commandId, payload.text]);

/** Explicit, nonsecret operator setup. Existing paths are never adopted/reset. */
export function initializeBotWorkJournal(path, fs = filesystem) {
  if (typeof path !== 'string' || path !== resolve(path) || path === '/') failure();
  const parent = dirname(path);
  for (let cursor = parent; ; cursor = dirname(cursor)) {
    const stat = fs.lstatSync(cursor);
    if (!stat.isDirectory() || stat.isSymbolicLink()) failure();
    if (cursor === '/') break;
  }
  fs.mkdirSync(path, { mode: 0o700 });
  const directory = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  try {
    const fd = fs.openSync(join(path, MARKER), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { writeAll(fd, JSON.stringify({ schemaVersion: 1, journalId: randomUUID(), records: BOT_WORK_LIMITS.journalRecords }) + '\n', fs); }
    finally { fs.closeSync(fd); }
    fs.fsyncSync(directory);
  } finally { fs.closeSync(directory); }
}

/** Append-only reservations; no prompt text, eviction, stale-lock takeover or replay. */
export class BotWorkJournal {
  #path; #fs; #identity; #poisoned = false;
  constructor(path, options = {}) {
    this.#path = path; this.#fs = options.filesystem ?? filesystem;
    try { this.#identity = privateDirectory(path, this.#fs); this.#scan(); }
    catch { this.#poisoned = true; }
  }
  #directory() {
    if (this.#poisoned || !this.#identity) failure();
    const stat = privateDirectory(this.#path, this.#fs);
    if (stat.dev !== this.#identity.dev || stat.ino !== this.#identity.ino) failure();
    return this.#fs.openSync(this.#path, this.#fs.constants.O_RDONLY | this.#fs.constants.O_DIRECTORY | this.#fs.constants.O_NOFOLLOW);
  }
  #read(name) {
    const raw = readBounded(join(this.#path, name), MAX_RECORD_BYTES, this.#fs);
    if (!raw.endsWith('\n')) failure();
    const lines = raw.slice(0, -1).split('\n');
    if (lines.length < 1 || lines.length > MAX_LINES) failure();
    let previous;
    for (const line of lines) {
      const decoded = JSON.parse(line);
      if (JSON.stringify(decoded) !== line) failure();
      const entry = botWorkFields(decoded, recordKeys), scope = botWorkFields(entry.scope, scopeKeys);
      publicScope(scope);
      if (entry.version !== 1 || typeof entry.pending !== 'boolean' || !/^[a-f0-9]{64}$/.test(entry.key)
        || !/^[a-f0-9]{64}$/.test(entry.digest) || !/^[a-f0-9-]{36}$/.test(entry.requestId)
        || name !== entry.key + '.record') failure();
      const request = { route: 'api/bot', body: { endpoint: 'quenderin-command', payload: { schemaVersion: 1,
        workspaceId: entry.receipt.workspaceId, botId: entry.receipt.botId, commandId: entry.receipt.commandId } } };
      if (!validateBotWorkResponse({ status: 200, json: { ok: true, value: entry.receipt } }, request).ok
        || !['accepted', 'uncertain', 'rejected'].includes(entry.receipt.state)
        || entry.key !== commandKey(scope, entry.receipt)
        || (entry.receipt.state === 'rejected' && entry.pending)
        || (entry.receipt.state === 'uncertain' && !entry.pending)) failure();
      if (!previous) {
        if (entry.receipt.state !== 'uncertain' || !entry.pending || entry.receipt.reason !== 'dispatchUncertain') failure();
      } else if (['key', 'digest', 'requestId'].some(key => entry[key] !== previous[key])
        || JSON.stringify(scope) !== JSON.stringify(previous.scope)
        || ['schemaVersion', 'workspaceId', 'botId', 'commandId'].some(key => entry.receipt[key] !== previous.receipt[key])
        || (entry.receipt.state !== 'rejected' && ['sessionId', 'revision'].some(key => entry.receipt[key] !== previous.receipt[key]))
        || (entry.receipt.state === 'rejected' && (entry.receipt.sessionId !== null || entry.receipt.revision !== null))
        || !previous.pending || previous.receipt.state === 'rejected'
        || (previous.receipt.state === 'accepted' && (entry.receipt.state !== 'accepted' || entry.pending))) failure();
      previous = entry;
    }
    return previous;
  }
  #scan(locked = false) {
    const fd = this.#directory();
    try {
      const marker = botWorkFields(JSON.parse(readBounded(join(this.#path, MARKER), 512, this.#fs)), ['schemaVersion', 'journalId', 'records']);
      if (marker.schemaVersion !== 1 || marker.records !== BOT_WORK_LIMITS.journalRecords
        || typeof marker.journalId !== 'string' || !/^[a-f0-9-]{36}$/.test(marker.journalId)) failure();
      const entries = this.#fs.readdirSync(this.#path);
      if (entries.length > BOT_WORK_LIMITS.journalRecords + 2 || (!locked && entries.includes(LOCK))) failure();
      const result = new Map();
      for (const name of entries) {
        if (name === MARKER || (locked && name === LOCK)) continue;
        if (!/^[a-f0-9]{64}\.record$/.test(name)) failure();
        const entry = this.#read(name); result.set(entry.key, entry);
      }
      if (result.size > BOT_WORK_LIMITS.journalRecords) failure();
      return result;
    } finally { this.#fs.closeSync(fd); }
  }
  #locked(action) {
    const fs = this.#fs, directory = this.#directory(); let lock;
    try {
      lock = fs.openSync(join(this.#path, LOCK), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
      const result = action(this.#scan(true));
      fs.fsyncSync(directory);
      return result;
    } finally {
      if (lock !== undefined) {
        fs.closeSync(lock); fs.unlinkSync(join(this.#path, LOCK)); fs.fsyncSync(directory);
      }
      fs.closeSync(directory);
    }
  }
  ready() { try { this.#scan(); return true; } catch { return false; } }
  lookup(scope, payload) {
    const entries = this.#scan();
    return entries.get(commandKey(publicScope(scope), payload));
  }
  reserve(scope, payload) {
    return this.#locked(entries => {
      const binding = publicScope(scope), key = commandKey(binding, payload), digest = botWorkPayloadDigest(payload);
      const prior = entries.get(key);
      if (prior) return { kind: prior.digest === digest ? 'duplicate' : 'conflict', entry: prior };
      const target = hash([binding.hostDeviceId, payload.workspaceId, payload.botId]);
      const pending = [...entries.values()].filter(entry => entry.pending);
      if (entries.size >= BOT_WORK_LIMITS.journalRecords || pending.length >= BOT_WORK_LIMITS.pendingTotal
        || pending.some(entry => botKey(entry) === target)) return { kind: 'capacity' };
      const entry = { version: 1, key, scope: binding, digest, requestId: randomUUID(),
        receipt: botWorkReceipt(payload, 'uncertain', 'dispatchUncertain', payload.expectedSessionId, payload.expectedRevision), pending: true };
      const fd = this.#fs.openSync(join(this.#path, key + '.record'), this.#fs.constants.O_WRONLY | this.#fs.constants.O_CREAT | this.#fs.constants.O_EXCL | this.#fs.constants.O_NOFOLLOW, 0o600);
      try { writeAll(fd, JSON.stringify(entry) + '\n', this.#fs); }
      finally { this.#fs.closeSync(fd); }
      return { kind: 'reserved', entry };
    });
  }
  transition(entry, receipt, pending) {
    return this.#locked(entries => {
      const current = entries.get(entry.key);
      if (!current || JSON.stringify(current) !== JSON.stringify(entry)) failure();
      const updated = { ...entry, receipt, pending }, path = join(this.#path, entry.key + '.record');
      const before = this.#fs.lstatSync(path);
      const text = JSON.stringify(updated) + '\n';
      if (before.size + Buffer.byteLength(text, 'utf8') > MAX_RECORD_BYTES) failure();
      const fd = this.#fs.openSync(path, this.#fs.constants.O_WRONLY | this.#fs.constants.O_APPEND | this.#fs.constants.O_NOFOLLOW);
      try {
        const opened = this.#fs.fstatSync(fd);
        if (opened.dev !== before.dev || opened.ino !== before.ino || opened.nlink !== 1) failure();
        writeAll(fd, text, this.#fs);
      } finally { this.#fs.closeSync(fd); }
      // Validate every append with the same strict cold-read validator.
      this.#read(entry.key + '.record');
      return updated;
    });
  }
}
