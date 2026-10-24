import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import { types } from 'node:util';
import { mountBotRead, mountedBotRead, botSessionWritable } from '../quenderin-bot-runtime.mjs';
import { assertBotReadWireBytes } from '../quenderin-bot-read-wire.mjs';

const params = { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: 'workspace-a' } } };
const diagnosticCodes = Object.freeze(['binding', 'state', 'request', 'readiness', 'revision', 'workspace',
  'membership', 'owners', 'bot-fields', 'projection', 'state-changed', 'ready']);
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

test('Host-only read diagnostics report only fixed check phases without changing route envelopes', () => {
  const cases = [
    ['binding', ({ dispose }) => { dispose(); }],
    ['state', ({ rt }) => { delete rt.state; }],
    ['request', () => {}, { ...params, body: { ...params.body, endpoint: 'readDiagnostic' } }],
    ['readiness', ({ rt }) => { rt.quenderinReadStatus = () => ({ ready: false, readOnly: true }); }],
    ['revision', ({ rt }) => { rt.state.revision = -1; }],
    ['workspace', ({ rt }) => { rt.ctx.workspaceRegistry.get = () => undefined; }],
    ['membership', ({ rt }) => { rt.ctx.workspaceRegistry.get = id => ({ id, sessionIds: [] }); }],
    ['owners', ({ rt }) => { rt.chatOwners.set('session-a', 'wrong-owner'); }],
    ['bot-fields', ({ rt }) => { delete rt.state.bots['bot-a'].name; }],
    ['projection', ({ rt }) => { rt.state.bots['bot-a'].name = ''; }],
    ['state-changed', ({ rt }) => { rt.ctx.workspaceRegistry.get = id => { rt.state.revision++; return { id, sessionIds: ['session-a'] }; }; }],
    ['ready', () => {}],
  ];
  assert.deepEqual(cases.map(([phase]) => phase), diagnosticCodes);
  for (const [phase, change, request = params] of cases) {
    const fixture = mounted(), adapter = mountedBotRead(fixture.rt.ctx.connection);
    assert.equal(adapter.readDiagnostic(), 'binding');
    change(fixture);
    const response = fixture.read(request), diagnostic = adapter.readDiagnostic();
    assert.equal(diagnostic, phase);
    assert.equal(diagnosticCodes.includes(diagnostic), true);
    assert.equal(response.status, phase === 'ready' ? 200 : phase === 'request' ? 400 : 503);
    assert.deepEqual(Object.keys(response), ['status', 'json']);
    assert.equal(JSON.stringify(response).includes('readDiagnostic'), false);
    assert.equal(JSON.stringify(response).includes('SYNTHETIC_PRIVATE'), false);
    assert.deepEqual(fixture.effects, []);
    fixture.dispose();
  }
});

test('read diagnostic access never inspects private values, getters, proxies or exception text', () => {
  let invoked = 0;
  const unexpected = () => { invoked++; throw new Error('SYNTHETIC_PRIVATE_DIAGNOSTIC'); };
  for (const value of [new Proxy({}, { get: unexpected, getPrototypeOf: unexpected, getOwnPropertyDescriptor: unexpected, ownKeys: unexpected }),
    Object.defineProperty({}, 'workspaceId', { get: unexpected })]) {
    const fixture = mounted(), adapter = mountedBotRead(fixture.rt.ctx.connection);
    fixture.rt.state = value;
    assert.equal(adapter.readDiagnostic(), 'binding');
    assert.equal(fixture.read(params).status, 503);
    for (let count = 0; count < 3; count++) assert.equal(adapter.readDiagnostic(), 'state');
    fixture.dispose();
  }
  const thrownProxy = new Proxy({}, { get: unexpected, getPrototypeOf: unexpected, getOwnPropertyDescriptor: unexpected });
  for (const error of [new Error('SYNTHETIC_PRIVATE_DIAGNOSTIC'), thrownProxy]) {
    const fixture = mounted(), adapter = mountedBotRead(fixture.rt.ctx.connection);
    fixture.rt.ctx.workspaceRegistry.get = () => { throw error; };
    const response = fixture.read(params);
    assert.equal(response.status, 503);
    assert.equal(adapter.readDiagnostic(), 'workspace');
    assert.equal(JSON.stringify(response).includes('SYNTHETIC_PRIVATE'), false);
    fixture.dispose();
  }
  assert.equal(invoked, 0);
});

test('genuine Maps from another realm support reads and preserve all ownership write guards', () => {
  const { rt, read, dispose, effects } = mounted();
  const maps = runInNewContext(`({
    chatOwners: new Map([['session-a', 'bot-a']]),
    groupOwners: new Map([['group-session', { botId: 'bot-a' }]]),
    pastOwners: new Map([['past-session', { botId: 'bot-a' }]]),
  })`);
  let overriddenCalls = 0;
  for (const [key, map] of Object.entries(maps)) {
    assert.equal(map instanceof Map, false);
    assert.equal(types.isMap(map), true);
    // Production must use the Map intrinsics rather than overridable methods.
    for (const method of ['get', 'has']) Object.defineProperty(map, method, { value() { overriddenCalls++; throw new Error('Unexpected Map override'); } });
    rt[key] = map;
  }
  assert.equal(read(params).status, 200);
  for (const sessionId of ['bot-a', 'session-a', 'group-session', 'past-session']) assert.equal(botSessionWritable(rt.ctx.connection, sessionId), false);
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), true);
  assert.equal(overriddenCalls, 0);
  assert.deepEqual(effects, []);
  dispose();
});

test('full foreign materialized state and ownership Maps support scoped reads and ordinary writes', () => {
  const { rt, read, dispose, effects } = mounted();
  Object.assign(rt, runInNewContext(`({
    state: { workspaceId: 'workspace-a', revision: 7,
      bots: { 'bot-a': { id: 'bot-a', name: 'Researcher', sessionId: 'session-a', model: null, permission: null } },
      rooms: { 'room-coordinator': { id: 'room-coordinator' } } },
    chatOwners: new Map([['session-a', 'bot-a']]),
    groupOwners: new Map([['group-session', { botId: 'bot-a' }]]),
    pastOwners: new Map([['past-session', { botId: 'bot-a' }]]),
  })`));
  assert.notEqual(Object.getPrototypeOf(rt.state.rooms), Object.prototype);
  assert.notEqual(Object.getPrototypeOf(rt.state.rooms['room-coordinator']), Object.prototype);
  rt.ctx.workspaceRegistry.get = id => id === 'workspace-a' ? { id, sessionIds: ['session-a'] }
    : id === 'workspace-b' ? { id, sessionIds: ['ordinary-session'] } : undefined;
  assert.equal(read(params).status, 200);
  const other = read({ ...params, body: { ...params.body, payload: { schemaVersion: 1, workspaceId: 'workspace-b' } } });
  assert.equal(other.status, 200);
  assert.equal(other.json.value.workspaceId, 'workspace-b');
  assert.deepEqual(other.json.value.bots, []);
  for (const sessionId of ['bot-a', 'session-a', 'room-coordinator', 'group-session', 'past-session']) assert.equal(botSessionWritable(rt.ctx.connection, sessionId), false);
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), true);
  assert.deepEqual(effects, []);
  dispose();
});

test('null-prototype ownership tables and room records remain supported', () => {
  const { rt, dispose } = mounted();
  const room = Object.assign(Object.create(null), { id: 'room-coordinator' });
  rt.state.rooms = Object.assign(Object.create(null), { 'room-coordinator': room });
  assert.equal(botSessionWritable(rt.ctx.connection, 'room-coordinator'), false);
  assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), true);
  dispose();
});

test('runtime record checks reject spoofed prototypes, constructors, accessors and proxies without executing them', () => {
  let invoked = 0;
  const unexpected = () => { invoked++; throw new Error('Unexpected runtime record input code'); };
  const ownId = prototype => Object.assign(Object.create(prototype), { id: 'room' });
  const counterfeitObjectPrototype = Object.create(null);
  Object.defineProperty(counterfeitObjectPrototype, 'constructor', { value: Object });
  const getterConstructorPrototype = Object.create(null);
  Object.defineProperty(getterConstructorPrototype, 'constructor', { get: unexpected });
  const customConstructorPrototype = Object.create(null);
  const customConstructor = function Object() { unexpected(); };
  Object.defineProperty(customConstructor, 'prototype', { value: customConstructorPrototype });
  Object.defineProperty(customConstructor, 'toString', { value: unexpected });
  Object.defineProperty(customConstructorPrototype, 'constructor', { value: customConstructor });
  const getterBacklinkPrototype = Object.create(null), getterBacklinkConstructor = () => unexpected();
  Object.defineProperty(getterBacklinkConstructor, 'prototype', { get: unexpected });
  Object.defineProperty(getterBacklinkPrototype, 'constructor', { value: getterBacklinkConstructor });
  const proxyConstructorPrototype = Object.create(null);
  Object.defineProperty(proxyConstructorPrototype, 'constructor', { value: new Proxy(Object, { get: unexpected, getOwnPropertyDescriptor: unexpected, apply: unexpected }) });
  class CustomRoom { constructor() { unexpected(); } }
  const proxyPrototype = new Proxy({}, { get: unexpected, getPrototypeOf: unexpected, getOwnPropertyDescriptor: unexpected });
  const proxyRecord = new Proxy({ id: 'room' }, { get: unexpected, getPrototypeOf: unexpected, getOwnPropertyDescriptor: unexpected, ownKeys: unexpected });
  const getterId = Object.defineProperty({}, 'id', { get: unexpected });
  const getterTag = Object.defineProperty({ id: 'room' }, Symbol.toStringTag, { get: unexpected });
  const getterPrivate = Object.defineProperty({ id: 'room' }, 'privateMetadata', { get: unexpected });
  const candidates = [ownId(counterfeitObjectPrototype), ownId(getterConstructorPrototype), ownId(customConstructorPrototype),
    ownId(getterBacklinkPrototype), ownId(proxyConstructorPrototype), ownId(CustomRoom.prototype), ownId({}), ownId(proxyPrototype),
    proxyRecord, getterId, getterTag, getterPrivate];
  for (const record of candidates) {
    for (const rooms of [record, { room: record }]) {
      const { rt, dispose, effects } = mounted();
      rt.state.rooms = rooms;
      assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), false);
      assert.deepEqual(effects, []);
      dispose();
    }
  }
  assert.equal(invoked, 0);
});

test('proxy and spoofed ownership Maps fail closed without invoking traps or lookalike methods', () => {
  let invoked = 0;
  const unexpected = () => { invoked++; throw new Error('Unexpected ownership input code'); };
  const foreignMap = runInNewContext("new Map([['session-a', 'bot-a']])");
  const proxy = new Proxy(foreignMap, { get: unexpected, getPrototypeOf: unexpected, getOwnPropertyDescriptor: unexpected });
  const revoked = Proxy.revocable(new Map(), {}); revoked.revoke();
  const tagged = { get: unexpected, has: unexpected };
  Object.defineProperty(tagged, Symbol.toStringTag, { get: unexpected });
  for (const key of ['chatOwners', 'groupOwners', 'pastOwners']) {
    for (const value of [proxy, revoked.proxy, tagged, Object.create(Map.prototype)]) {
      const { rt, read, dispose, effects } = mounted();
      rt[key] = value;
      assert.equal(read(params).status, key === 'chatOwners' ? 503 : 200);
      assert.equal(botSessionWritable(rt.ctx.connection, 'ordinary-session'), false);
      assert.deepEqual(effects, []);
      dispose();
    }
  }
  assert.equal(invoked, 0);
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
