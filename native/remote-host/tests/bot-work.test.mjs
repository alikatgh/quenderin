import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { spawnSync } from 'node:child_process';
import { mountBotRead, botSessionWritable } from '../quenderin-bot-runtime.mjs';
import { mountBotWork, mountedBotWork, createBotWorkScope } from '../quenderin-bot-work-runtime.mjs';
import { BotWorkJournal, initializeBotWorkJournal } from '../quenderin-bot-work-journal.mjs';
import { BOT_WORK_LIMITS, validateBotWorkRequest, validateBotWorkResponse } from '../quenderin-bot-work-policy.mjs';
import { assertBotReadWireBytes } from '../quenderin-bot-read-wire.mjs';

const pin = '1bebe826f74e9a72cabafd3b80602b05af867b38';
const payload = { schemaVersion: 1, workspaceId: 'workspace-a', botId: 'bot-a', expectedSessionId: 'part-a', expectedRevision: 7, commandId: 'command-a', text: 'A synthetic task' };
const submit = value => ({ route: 'api/bot', body: { endpoint: 'quenderin-submit', payload: value } });
const status = (value = payload) => ({ route: 'api/bot', body: { endpoint: 'quenderin-command', payload: { schemaVersion: 1, workspaceId: value.workspaceId, botId: value.botId, commandId: value.commandId } } });
const key = Buffer.alloc(32, 9).toString('base64url');
const scope = (peer = 'peer-a', authorize = () => undefined, host = 'host-a') => createBotWorkScope(host, peer, key, authorize);
function fixture(options = {}) {
  const root = fs.mkdtempSync(join(tmpdir(), 'bot-work-test-')), path = join(root, 'journal');
  initializeBotWorkJournal(path);
  const journal = options.journalFactory?.(path) ?? new BotWorkJournal(path);
  const calls = [], disposers = [], handlers = [];
  const rt = { state: { workspaceId: 'workspace-a', revision: 7, rooms: {}, bots: { 'bot-a': { id: 'bot-a', sessionId: 'part-a', name: 'Synthetic Bot', model: 'fixture/scripted', permission: 'read-only' } } },
    chatOwners: new Map([['part-a', 'bot-a']]), groupOwners: new Map(), pastOwners: new Map(),
    ensureCapabilities: async () => undefined,
    quenderinReadStatus: () => ({ ready: true, readOnly: false }),
    ctx: { connection: {}, workspaceRegistry: { get: id => id === 'workspace-a' ? { id, sessionIds: ['part-a', 'part-b'] } : undefined },
      sessionController: { prompt: async request => { calls.push(request); return { accepted: true }; } },
      effect: effect => { disposers.push(effect()); }, on: (name, handler) => { if (name === 'session/event') handlers.push(handler); } } };
  mountBotRead(rt);
  const writer = { botRevision: pin, prepare: (id, signal) => rt.ensureCapabilities(id, signal), prompt: (request, signal) => rt.ctx.sessionController.prompt(request, signal) };
  const adapter = mountBotWork(rt, writer, { journal });
  const event = (type, data = {}, sessionId = 'part-a') => handlers.forEach(handler => handler({ id: sessionId }, { type, data }));
  const cleanup = () => { disposers.forEach(dispose => dispose()); fs.rmSync(root, { recursive: true, force: true }); };
  return { root, path, journal, rt, calls, writer, adapter, event, cleanup };
}
const state = response => response.json.value?.state;
const receipt = response => response.json.value;
const settle = f => { f.event('user/message', { source: { rpcId: f.calls.at(-1).requestId } }); f.event('turn/end'); };

test('two sequential admitted commands use the existing queue and settle only through matching official events', async () => {
  const f = fixture();
  try {
    assert.equal(mountedBotWork(f.rt.ctx.connection), f.adapter);
    assert.equal(f.adapter.ready(), true);
    assert.equal(botSessionWritable(f.rt.ctx.connection, 'part-a'), false);
    const first = await f.adapter.call(submit(payload), scope());
    assert.equal(state(first), 'accepted');
    assert.equal(receipt(first).sessionId, 'part-a'); assert.equal(receipt(first).revision, 7);
    assert.equal(f.calls[0].mode, 'queue'); assert.equal(f.calls[0].content[0].text, payload.text);
    assert.notEqual(f.calls[0].requestId, payload.commandId);
    const second = { ...payload, commandId: 'command-b' };
    assert.equal(receipt(await f.adapter.call(submit(second), scope())).reason, 'capacity');
    // Unrelated turns, another Bot's message and cancel acknowledgements do not settle this command.
    f.event('turn/end'); f.event('user/message', { source: { rpcId: 'unrelated' } }); f.event('turn/end');
    f.event('user/message', { source: { rpcId: f.calls[0].requestId } }, 'part-b'); f.event('turn/end', {}, 'part-b');
    assert.equal(receipt(await f.adapter.call(submit(second), scope())).reason, 'capacity');
    settle(f);
    assert.equal(state(await f.adapter.call(submit(second), scope())), 'accepted');
    settle(f);
    assert.equal(f.calls.length, 2);
    assert.equal(new BotWorkJournal(f.path).lookup(scope(), second).pending, false);
  } finally { f.cleanup(); }
});

test('concurrent duplicate and lost ACK/status recovery dispatch exactly once and preserve the original receipt on conflicts', async () => {
  const f = fixture(); let release;
  try {
    f.rt.ensureCapabilities = () => new Promise(resolve => { release = resolve; });
    const first = f.adapter.call(submit(payload), scope());
    const duplicate = await f.adapter.call(submit(payload), scope());
    assert.equal(state(duplicate), 'uncertain'); assert.equal(f.calls.length, 0);
    const conflict = await f.adapter.call(submit({ ...payload, text: 'Changed synthetic task' }), scope());
    assert.equal(receipt(conflict).reason, 'payloadConflict'); assert.equal(receipt(conflict).sessionId, null);
    release(); const accepted = await first; // Client can lose this ACK.
    const cold = new BotWorkJournal(f.path);
    assert.deepEqual(cold.lookup(scope(), payload).receipt, receipt(accepted));
    assert.deepEqual(receipt(await f.adapter.call(status(), scope())), receipt(accepted));
    assert.deepEqual(receipt(await f.adapter.call(submit(payload), scope())), receipt(accepted));
    assert.equal(f.calls.length, 1);
    assert.equal(JSON.stringify(fs.readdirSync(f.path).map(name => fs.readFileSync(join(f.path, name), 'utf8'))).includes(payload.text), false);
    // A stable Bot's receipt stays bound to its original admitted part after rotation.
    f.rt.state.bots['bot-a'].sessionId = 'part-b'; f.rt.chatOwners.set('part-b', 'bot-a'); f.rt.state.revision++;
    assert.deepEqual(receipt(await f.adapter.call(status(), scope())), receipt(accepted));
    assert.equal(state(await f.adapter.call(status(), scope('peer-b'))), 'notFound');
    assert.equal(state(await f.adapter.call(status(), scope('peer-a', () => undefined, 'host-b'))), 'notFound');
  } finally { release?.(); f.cleanup(); }
});

test('reservation survives a simulated crash and restart without prompt replay or slot eviction', async () => {
  const f = fixture();
  try {
    const entry = f.journal.reserve(scope(), payload).entry;
    const restarted = new BotWorkJournal(f.path);
    assert.equal(restarted.ready(), true); assert.deepEqual(restarted.lookup(scope(), payload), entry);
    assert.equal(state(await f.adapter.call(submit(payload), scope())), 'uncertain');
    assert.equal(receipt(await f.adapter.call(submit({ ...payload, commandId: 'next' }), scope())).reason, 'capacity');
    assert.equal(f.calls.length, 0);
  } finally { f.cleanup(); }
});

test('wrong scope, stale revision/session, writer takeover and revocation refuse before dispatch', async () => {
  for (const [change, expected] of [
    [f => { f.rt.state.revision++; }, 'staleRevision'],
    [f => { f.rt.state.bots['bot-a'].sessionId = 'part-b'; f.rt.chatOwners.set('part-b', 'bot-a'); }, 'staleSession'],
    [f => { f.rt.quenderinReadStatus = () => ({ ready: true, readOnly: true }); }, 'readOnly'],
    [f => { f.rt.state.workspaceId = 'workspace-b'; }, 'wrongScope'],
  ]) {
    const f = fixture();
    try { change(f); assert.equal(receipt(await f.adapter.call(submit(payload), scope())).reason, expected); assert.equal(f.calls.length, 0); }
    finally { f.cleanup(); }
  }
  const f = fixture();
  try {
    assert.equal(receipt(await f.adapter.call(submit(payload), scope('peer-a', () => { throw new Error('Private revocation detail'); }))).reason, 'revoked');
    assert.equal(f.calls.length, 0);
  } finally { f.cleanup(); }
});

test('revalidates current part, revision, writer and authority after awaited capability preparation', async () => {
  for (const [change, reason] of [
    [f => { f.rt.state.bots['bot-a'].sessionId = 'part-b'; f.rt.chatOwners.set('part-b', 'bot-a'); }, 'staleSession'],
    [f => { f.rt.state.revision++; }, 'staleRevision'],
    [f => { f.rt.quenderinReadStatus = () => ({ ready: true, readOnly: true }); }, 'readOnly'],
    [f => { f.revoked = true; }, 'revoked'],
  ]) {
    const f = fixture();
    try {
      f.rt.ensureCapabilities = async () => { change(f); };
      const s = scope('peer-a', () => { if (f.revoked) throw new Error('Revoked'); });
      const response = await f.adapter.call(submit(payload), s);
      assert.equal(receipt(response).reason, reason); assert.equal(receipt(response).sessionId, null); assert.equal(f.calls.length, 0);
      assert.deepEqual(new BotWorkJournal(f.path).lookup(s, payload).receipt, receipt(response));
    } finally { f.cleanup(); }
  }
});

test('disk full before durable reservation prevents preparation and dispatch; missing/corrupt/locked journals fail closed', async () => {
  const f = fixture({ journalFactory: path => new BotWorkJournal(path, { filesystem: { ...fs, writeSync() { throw Object.assign(new Error('Synthetic ENOSPC'), { code: 'ENOSPC' }); } } }) });
  try {
    let prepared = 0; f.rt.ensureCapabilities = async () => { prepared++; };
    assert.equal((await f.adapter.call(submit(payload), scope())).status, 503);
    assert.equal(prepared, 0); assert.equal(f.calls.length, 0); assert.equal(f.journal.ready(), false);
  } finally { f.cleanup(); }
  for (const damage of [
    f => fs.unlinkSync(join(f.path, '.initialized.json')),
    f => fs.writeFileSync(join(f.path, '.initialized.json'), '{', { mode: 0o600 }),
    f => fs.writeFileSync(join(f.path, '.admission.lock'), '', { mode: 0o600 }),
  ]) {
    const f = fixture();
    try { damage(f); assert.equal(f.adapter.ready(), false); assert.equal((await f.adapter.call(submit(payload), scope())).status, 503); assert.equal(f.calls.length, 0); assert.throws(() => initializeBotWorkJournal(f.path)); }
    finally { f.cleanup(); }
  }
});

test('a failed dispatch and an ACK persistence failure remain uncertain, never replayable', async () => {
  const f = fixture();
  try {
    f.rt.ctx.sessionController.prompt = async request => { f.calls.push(request); throw new Error('Synthetic lost result'); };
    assert.equal(state(await f.adapter.call(submit(payload), scope())), 'uncertain');
    assert.equal(state(await f.adapter.call(submit(payload), scope())), 'uncertain'); assert.equal(f.calls.length, 1);
  } finally { f.cleanup(); }
  let writes = 0;
  const g = fixture({ journalFactory: path => new BotWorkJournal(path, { filesystem: { ...fs, writeSync(...args) {
    if (++writes === 2) throw Object.assign(new Error('Synthetic ENOSPC on ACK'), { code: 'ENOSPC' });
    return fs.writeSync(...args);
  } } }) });
  try {
    assert.equal(state(await g.adapter.call(submit(payload), scope())), 'uncertain');
    assert.equal(state(await g.adapter.call(submit(payload), scope())), 'uncertain'); assert.equal(g.calls.length, 1);
  } finally { g.cleanup(); }
});

test('oversized/malformed values and duplicate raw wire fields are rejected without runtime effects', async () => {
  const f = fixture();
  try {
    for (const invalid of [{ ...payload, text: 'x'.repeat(BOT_WORK_LIMITS.textUTF8Bytes + 1) }, { ...payload, text: ' ' },
      { ...payload, text: '\ud800' }, { ...payload, expectedRevision: -1 }, { ...payload, commandId: 'x'.repeat(129) }, { ...payload, hostDeviceId: 'spoof' }]) {
      assert.equal(validateBotWorkRequest(submit(invalid)).ok, false);
      assert.equal((await f.adapter.call(submit(invalid), scope())).status, 400);
    }
    const maximum = submit({ ...payload, text: 'x'.repeat(16384) });
    assert.equal(validateBotWorkRequest(maximum).ok, true);
    assert.doesNotThrow(() => assertBotReadWireBytes(JSON.stringify({ payload: { method: 'plugin.route.call', params: maximum } })));
    const raw = JSON.stringify({ payload: { method: 'plugin.route.call', params: submit(payload) } }).replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1');
    assert.throws(() => assertBotReadWireBytes(raw)); assert.equal(f.calls.length, 0);
    const accepted = { status: 200, json: { ok: true, value: { schemaVersion: 1, workspaceId: payload.workspaceId, botId: payload.botId, commandId: payload.commandId, sessionId: 'part-b', revision: 7, state: 'accepted', reason: null } } };
    assert.equal(validateBotWorkResponse(accepted, submit(payload)).ok, false);
  } finally { f.cleanup(); }
});

test('no configured journal or incompatible/unmounted writer advertises readiness', () => {
  const f = fixture();
  try {
    f.writer.botRevision = 'unreviewed'; assert.equal(f.adapter.ready(), false);
    f.writer.botRevision = pin;
    assert.equal(new BotWorkJournal(undefined).ready(), false);
    assert.equal(new BotWorkJournal(join(f.root, 'absent')).ready(), false);
  } finally { f.cleanup(); }
});


test('independent runtime workers serialize durable reservation of the same scoped command', { timeout: 5000 }, async () => {
  const f = fixture(), workers = [];
  try {
    const code = `const { parentPort, workerData } = require('node:worker_threads');
      (async () => {
        const { BotWorkJournal } = await import(workerData.module);
        const journal = new BotWorkJournal(workerData.path);
        parentPort.postMessage('ready');
        parentPort.once('message', () => {
          try { parentPort.postMessage(journal.reserve(workerData.scope, workerData.payload).kind); }
          catch { parentPort.postMessage('storageUnavailable'); }
        });
      })().catch(() => process.exit(1));`;
    const start = [];
    for (let i = 0; i < 2; i++) {
      const worker = new Worker(code, { eval: true, workerData: { module: new URL('../quenderin-bot-work-journal.mjs', import.meta.url).href,
        path: f.path, payload, scope: { hostDeviceId: 'host-a', peerDeviceId: 'peer-a', peerKeySHA256: scope().peerKeySHA256 } } });
      workers.push(worker);
      start.push(new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); }));
    }
    await Promise.all(start);
    const results = workers.map(worker => new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); worker.postMessage('reserve'); }));
    const kinds = await Promise.all(results);
    assert.equal(kinds.filter(kind => kind === 'reserved').length, 1);
    assert.equal(kinds.every(kind => ['reserved', 'duplicate', 'storageUnavailable'].includes(kind)), true);
    assert.equal(new BotWorkJournal(f.path).lookup(scope(), payload).receipt.state, 'uncertain');
    assert.equal(fs.readdirSync(f.path).filter(name => name.endsWith('.record')).length, 1);
  } finally { await Promise.all(workers.map(worker => worker.terminate())); f.cleanup(); }
});

test('journal capacity retains prior receipts and never evicts a command to admit another', () => {
  const f = fixture();
  try {
    const first = f.journal.reserve(scope(), payload).entry;
    for (let index = 0; index < BOT_WORK_LIMITS.journalRecords; index++) {
      const commandId = index ? `capacity-${index}` : payload.commandId;
      const entry = structuredClone(first); entry.receipt.commandId = commandId;
      entry.key = createHash('sha256').update(JSON.stringify(['host-a', 'peer-a', scope().peerKeySHA256, payload.workspaceId, payload.botId, commandId])).digest('hex');
      const accepted = { ...entry, receipt: { ...entry.receipt, state: 'accepted', reason: null }, pending: false };
      fs.writeFileSync(join(f.path, entry.key + '.record'), JSON.stringify(entry) + '\n' + JSON.stringify(accepted) + '\n', { mode: 0o600 });
    }
    assert.equal(f.journal.ready(), true);
    assert.equal(f.journal.reserve(scope(), { ...payload, commandId: 'beyond-capacity' }).kind, 'capacity');
    assert.equal(f.journal.reserve(scope(), payload).kind, 'duplicate');
    assert.equal(f.journal.lookup(scope(), payload).receipt.state, 'accepted');
    assert.equal(fs.readdirSync(f.path).filter(name => name.endsWith('.record')).length, 1024);
  } finally { f.cleanup(); }
});

test('global pending capacity is finite across Bots and per-Bot admission is shared across Peers', () => {
  const f = fixture();
  try {
    assert.equal(f.journal.reserve(scope(), payload).kind, 'reserved');
    assert.equal(f.journal.reserve(scope('peer-b'), { ...payload, commandId: 'other-peer' }).kind, 'capacity');
    for (let index = 1; index < BOT_WORK_LIMITS.pendingTotal; index++) assert.equal(f.journal.reserve(scope(), { ...payload, botId: `bot-${index}` }).kind, 'reserved');
    assert.equal(f.journal.reserve(scope(), { ...payload, botId: 'beyond' }).kind, 'capacity');
  } finally { f.cleanup(); }
});


test('the actual queue must acknowledge admission before an accepted receipt is persisted', async () => {
  for (const acknowledgement of [undefined, false, { accepted: false }, { ok: true }, { accepted: 'true' }]) {
    const f = fixture();
    try {
      f.rt.ctx.sessionController.prompt = async request => { f.calls.push(request); return acknowledgement; };
      assert.equal(state(await f.adapter.call(submit(payload), scope())), 'uncertain');
      assert.equal(state(await f.adapter.call(submit(payload), scope())), 'uncertain'); assert.equal(f.calls.length, 1);
    } finally { f.cleanup(); }
  }
});

test('portable shared fixtures and every numeric limit match the frozen work contract', () => {
  const shared = JSON.parse(fs.readFileSync(new URL('../../../shared/remote-harness-bot-command-fixtures.json', import.meta.url), 'utf8'));
  const contract = JSON.parse(fs.readFileSync(new URL('../../../shared/remote-harness-bot-command-contract.json', import.meta.url), 'utf8'));
  assert.deepEqual(BOT_WORK_LIMITS, contract.limits);
  for (const name of ['submit', 'status']) assert.equal(validateBotWorkRequest(shared.valid[name]).ok, true, name);
  for (const name of ['accepted', 'rejected', 'uncertain', 'notFound', 'payloadConflict']) assert.equal(validateBotWorkResponse(shared.valid[name], shared.valid.submit).ok, true, name);
  for (const example of shared.invalidRequests) assert.equal(validateBotWorkRequest(example.params).ok, false, example.id);
  for (const example of shared.invalidResponses) assert.equal(validateBotWorkResponse(example.result, example.request ?? shared.valid.submit).ok, false, example.id);
  for (const example of shared.generatedLimits) {
    const request = structuredClone(shared.valid.submit); request.body.payload[example.field] = example.value.repeat(example.count);
    assert.equal(validateBotWorkRequest(request).ok, example.expectedValid, example.id);
  }
});


test('nonsecret journal setup CLI creates only a new private directory and refuses reset or linked paths', () => {
  const f = fixture();
  try {
    const target = join(f.root, 'operator-journal'), helper = new URL('../tools/initialize_bot_work_journal.mjs', import.meta.url);
    const invoke = path => spawnSync(process.execPath, [helper.pathname, path], { encoding: 'utf8' });
    assert.equal(invoke(target).status, 0);
    assert.equal(fs.statSync(target).mode & 0o777, 0o700);
    assert.equal(new BotWorkJournal(target).ready(), true);
    const original = fs.readFileSync(join(target, '.initialized.json'), 'utf8');
    assert.equal(invoke(target).status, 1);
    assert.equal(fs.readFileSync(join(target, '.initialized.json'), 'utf8'), original);
    fs.symlinkSync(target, join(f.root, 'linked-journal'));
    assert.equal(new BotWorkJournal(join(f.root, 'linked-journal')).ready(), false);
    assert.equal(invoke(join(f.root, 'linked-journal', 'new')).status, 1);
    assert.equal(fs.readdirSync(target).length, 1);
  } finally { f.cleanup(); }
});

test('work structural validators reject accessors and proxies without inspecting private fields', () => {
  let calls = 0;
  const unexpected = () => { calls++; throw new Error('SYNTHETIC_PRIVATE'); };
  const accessor = Object.defineProperty({ ...payload }, 'text', { enumerable: true, get: unexpected });
  assert.equal(validateBotWorkRequest(submit(accessor)).ok, false);
  const proxy = new Proxy({}, { get: unexpected, getPrototypeOf: unexpected, ownKeys: unexpected, getOwnPropertyDescriptor: unexpected });
  assert.equal(validateBotWorkRequest(proxy).ok, false);
  assert.equal(calls, 0);
});
