import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mountBotRead, mountedBotRead, botSessionWritable } from '../quenderin-bot-runtime.mjs';
import { assertBotReadWireBytes } from '../quenderin-bot-read-wire.mjs';

const params = { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: 'workspace-a' } } };
function mounted() {
  const disposers = [], effects = [];
  const rt = { state: { workspaceId: 'workspace-a', revision: 7, rooms: {}, bots: { 'bot-a': { id: 'bot-a', name: 'Researcher', sessionId: 'session-a', model: 'fixture/scripted', permission: 'read-only', instructions: 'SYNTHETIC_PRIVATE' } } },
    chatOwners: new Map([['session-a', 'bot-a']]), groupOwners: new Map(), pastOwners: new Map(), quenderinReadStatus: () => ({ ready: true, readOnly: false }),
    ctx: { connection: {}, workspaceRegistry: { get: id => id === 'workspace-a' ? { id, sessionIds: ['session-a'] } : undefined },
      effect: effect => { disposers.push(effect()); } } };
  for (const method of ['refresh', 'load', 'save', 'bootstrap', 'loadSecrets', 'resolveAgent', 'catalog']) rt[method] = () => { effects.push(method); throw new Error('Forbidden read effect'); };
  const read = mountBotRead(rt);
  return { rt, read, effects, dispose: () => disposers.forEach(dispose => dispose()) };
}

test('mounted adapter projects current materialized membership without execution or private fields', () => {
  const { rt, read, effects, dispose } = mounted();
  assert.equal(mountedBotRead(rt.ctx.connection)?.capability, 'quenderin.bot.read.v1');
  const result = read(params);
  assert.equal(result.status, 200);
  assert.deepEqual(result.json.value.bots, [{ id: 'bot-a', name: 'Researcher', sessionId: 'session-a', model: 'fixture/scripted', permission: 'read-only' }]);
  assert.equal(JSON.stringify(result).includes('PRIVATE'), false);
  assert.deepEqual(effects, []);
  dispose();
  assert.equal(mountedBotRead(rt.ctx.connection), undefined);
  assert.equal(read(params).status, 503);
});

test('another loaded official workspace receives its own empty roster after team ownership is validated', () => {
  const { rt, read, dispose, effects } = mounted();
  rt.ctx.workspaceRegistry.get = id => id === 'workspace-a' ? { id, sessionIds: ['session-a'] }
    : id === 'workspace-b' ? { id, sessionIds: ['ordinary-session'] } : undefined;
  const otherRequest = { ...params, body: { ...params.body, payload: { schemaVersion: 1, workspaceId: 'workspace-b' } } };
  const response = read(otherRequest);
  assert.deepEqual(response, { status: 200, json: { ok: true, value: { schemaVersion: 1, workspaceId: 'workspace-b', revision: 7, readOnly: false, bots: [] } } });
  for (const privateIdentity of ['workspace-a', 'bot-a', 'session-a', 'Researcher']) assert.equal(JSON.stringify(response).includes(privateIdentity), false);
  rt.chatOwners.set('session-a', 'wrong-owner');
  assert.equal(read(otherRequest).status, 503);
  rt.chatOwners.set('session-a', 'bot-a'); rt.state.revision = 6;
  assert.equal(read(otherRequest).status, 503);
  assert.deepEqual(effects, []);
  dispose();
});

test('Bot current, original, group and past parts cannot bypass the Bot lifecycle through Harness writes', () => {
  assert.equal(botSessionWritable({}, 'ordinary'), true);
  const { rt, read, dispose, effects } = mounted();
  rt.groupOwners.set('group-session', { botId: 'bot-a' });
  rt.pastOwners.set('past-session', { botId: 'bot-a' });
  rt.state.rooms['room-coordinator'] = { id: 'room-coordinator' };
  assert.equal(read(params).status, 200);
  for (const id of ['bot-a', 'session-a', 'room-coordinator', 'group-session', 'past-session']) assert.equal(botSessionWritable(rt.ctx.connection, id), false);
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), true);
  rt.state.revision--;
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), false);
  rt.state.revision++;
  rt.quenderinReadStatus = () => ({ ready: false, readOnly: false });
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), false);
  assert.deepEqual(effects, []);
  dispose();
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), true);
});

test('missing or malformed room coordinator authority fails closed without invoking input code', () => {
  let effects = 0;
  const accessor = Object.defineProperty({}, 'id', { get() { effects++; return 'room'; } });
  const proxy = new Proxy({}, { getOwnPropertyDescriptor() { effects++; throw new Error('Unexpected room trap'); } });
  for (const rooms of [undefined, null, [], Object.create({ room: { id: 'room' } }),
    { room: {} }, { room: { id: '' } }, { room: { id: 'different' } }, { room: { id: '\ud800' } },
    { room: accessor }, { room: proxy }, { room: { id: 'room\0' } }]) {
    const { rt, dispose } = mounted(); rt.state.rooms = rooms;
    assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), false);
    dispose();
  }
  assert.equal(effects, 0);
});

test('unready, stale revision, wrong ownership/workspace and unsupported reads fail closed', () => {
  for (const change of [
    rt => { rt.quenderinReadStatus = () => ({ ready: false, readOnly: true }); },
    rt => { rt.state.revision = 6; },
    rt => { rt.state.revision = NaN; },
    rt => { rt.chatOwners.set('session-a', 'bot-other'); },
    rt => { rt.state.bots['bot-a'].sessionId = 'unregistered'; rt.chatOwners.set('unregistered', 'bot-a'); },
    rt => { rt.ctx.workspaceRegistry.get = () => ({ id: 'workspace-other', sessionIds: ['session-a'] }); },
  ]) {
    const { rt, read, effects, dispose } = mounted();
    assert.equal(read(params).status, 200);
    change(rt);
    assert.equal(read(params).status, 503);
    assert.deepEqual(effects, []);
    dispose();
  }
  const { read, dispose } = mounted();
  for (const endpoint of ['state', 'send', 'approval-answer', 'quenderin-roster-extra']) {
    assert.equal(read({ ...params, body: { ...params.body, endpoint } }).status, 400);
  }
  assert.equal(read({ ...params, body: { ...params.body, payload: { schemaVersion: 1, workspaceId: 'workspace-other' } } }).status, 400);
  dispose();
});

const wire = raw => `{"v":1,"id":"request","type":"rpc.request","timestamp":1,"payload":{"method":"plugin.route.call","params":${raw}}}`;
test('raw params bound preserves enclosing RPC bytes, escaped strings and exact 4096/4097 whitespace', () => {
  const raw = JSON.stringify(params);
  const exact = raw.slice(0, -1) + ' '.repeat(4096 - Buffer.byteLength(raw)) + '}';
  assert.equal(Buffer.byteLength(exact), 4096);
  assert.ok(Buffer.byteLength(wire(exact)) > 4096);
  assert.doesNotThrow(() => assertBotReadWireBytes(wire(exact)));
  assert.throws(() => assertBotReadWireBytes(wire(exact.slice(0, -1) + ' }')), /bound/);
  assert.doesNotThrow(() => assertBotReadWireBytes(wire(raw.replace('api/bot', 'api\\/bot').replace('workspace-a', 'workspace-\\u0061'))));
  const nested = { ...params, body: { ...params.body, payload: { ...params.body.payload, extra: [{ text: '\"{[\\]}\"' }] } } };
  assert.doesNotThrow(() => assertBotReadWireBytes(wire(JSON.stringify(nested))));
});

test('duplicate schema and carrier fields fail before parsing and old methods retain their parser', () => {
  const raw = JSON.stringify(params);
  for (const changed of [
    raw.replace('"route":', '"route":"api/bot","route":'),
    raw.replace('"endpoint":', '"endpoint":"state","endpoint":'),
    raw.replace('"workspaceId":', '"workspaceId":"other","workspaceId":'),
    raw.replace('"schemaVersion":', '"schemaVersion":1,"schemaVersion":'),
  ]) assert.throws(() => assertBotReadWireBytes(wire(changed)), /Duplicate/);
  assert.throws(() => assertBotReadWireBytes(wire(raw).replace('"method":', '"method":"plugin.route.call","method":')), /Duplicate/);
  const old = wire(raw.slice(0, -1) + ' '.repeat(5000) + '}').replace('plugin.route.call', 'harness.remote.call');
  assert.doesNotThrow(() => assertBotReadWireBytes(old));
  assert.doesNotThrow(() => assertBotReadWireBytes('{"payload":{"method":"harness.remote.call","params":{"text":"[\\\"}]"}}}'));
});
