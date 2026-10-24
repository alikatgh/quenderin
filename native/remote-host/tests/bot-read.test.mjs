import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  BOT_READ_CAPABILITY, BOT_READ_CARRIER_CAPABILITY, BOT_READ_ROUTE, BOT_READ_ENDPOINT, BOT_READ_LIMITS,
  validateBotReadRequest, projectBotReadSnapshot, handleBotReadRequest, validateBotReadResponse,
} from '../quenderin-bot-read-policy.mjs';

const fixture = JSON.parse(readFileSync(new URL('../../../shared/remote-harness-bot-read-fixtures.json', import.meta.url), 'utf8'));
const contract = JSON.parse(readFileSync(new URL('../../../shared/remote-harness-bot-read-contract.json', import.meta.url), 'utf8'));
const clone = value => structuredClone(value);
const source = () => clone(fixture.valid.source);
const request = (workspaceId = fixture.workspaceId) => ({ route: BOT_READ_ROUTE,
  body: { endpoint: BOT_READ_ENDPOINT, payload: { schemaVersion: 1, workspaceId } } });
const bytes = value => Buffer.byteLength(JSON.stringify(value), 'utf8');
const emptySource = (workspaceId = fixture.workspaceId) => ({ ready: true, workspaceId, revision: 0, readOnly: true, bots: [] });
const bot = index => ({ id: `bot-${index}`, name: 'Assistant', sessionId: `session-${index}`, model: null, permission: null });
const project = value => projectBotReadSnapshot(value, fixture.workspaceId);

function assertFailure(result, code, status) {
  const failure = status === undefined ? result : result.json;
  if (status !== undefined) assert.equal(result.status, status);
  assert.deepEqual(failure, { ok: false, error: { code, message: 'Bot roster read unavailable' } });
}

test('published constants and every limit match the frozen shared contract', () => {
  assert.equal(BOT_READ_CAPABILITY, contract.capability);
  assert.equal(BOT_READ_CARRIER_CAPABILITY, contract.requiredCarrierCapability);
  assert.equal(BOT_READ_ROUTE, contract.route);
  assert.equal(BOT_READ_ENDPOINT, contract.endpoint);
  assert.deepEqual(BOT_READ_LIMITS, contract.limits);
  assert.ok(Object.isFrozen(BOT_READ_LIMITS));
});

test('shared valid request and source project exactly the portable success fixture', () => {
  assert.deepEqual(validateBotReadRequest(fixture.valid.request, fixture.workspaceId), { ok: true, value: fixture.valid.request });
  assert.deepEqual(project(source()), fixture.valid.response);
  assert.deepEqual(handleBotReadRequest(fixture.valid.request, source(), fixture.workspaceId), fixture.valid.response);
  assert.deepEqual(validateBotReadResponse(fixture.valid.response, fixture.workspaceId), { ok: true, value: fixture.valid.response });
});

for (const entry of fixture.invalidRequests) {
  test(`shared invalid request: ${entry.id}`, () => {
    assertFailure(validateBotReadRequest(entry.params, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST');
    let inspected = 0;
    const unavailable = Object.defineProperty({}, 'ready', { get() { inspected++; throw new Error('SYNTHETIC_PRIVATE'); } });
    assertFailure(handleBotReadRequest(entry.params, unavailable, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST', 400);
    assert.equal(inspected, 0);
  });
}

for (const entry of fixture.invalidResponses) {
  test(`shared invalid response: ${entry.id}`, () => {
    assertFailure(validateBotReadResponse(entry.result, fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
  });
}

test('projection ignores private fields, callbacks, getters and toJSON without mutation or effects', () => {
  const input = source(), before = clone(input);
  let effects = 0;
  const effect = () => { effects++; throw new Error('SYNTHETIC_PRIVATE_EFFECT'); };
  for (const target of [input, ...input.bots]) {
    for (const key of ['providerKey', 'instructions', 'agent', 'privateMetadata', 'toJSON', 'load', 'refresh', 'bootstrap', 'migrate']) {
      Object.defineProperty(target, key, { get: effect, enumerable: true, configurable: true });
    }
    Object.defineProperty(target, Symbol.toPrimitive, { value: effect });
    Object.freeze(target);
  }
  Object.defineProperty(input.bots, Symbol.iterator, { get: effect });
  Object.defineProperty(input.bots, 'privateMetadata', { get: effect });
  Object.freeze(input.bots);
  const result = project(input);
  assert.deepEqual(result, fixture.valid.response);
  assert.equal(effects, 0);
  assert.equal(input.workspaceId, before.workspaceId);
  assert.equal(input.bots[0].id, before.bots[0].id);
  assert.notEqual(result.json.value.bots, input.bots);
  assert.notEqual(result.json.value.bots[0], input.bots[0]);
  const encoded = JSON.stringify(result);
  assert.ok(!encoded.includes('PRIVATE'));
  assert.deepEqual(Object.keys(result.json.value), contract.success.valueRequiredExactly);
  assert.deepEqual(Object.keys(result.json.value.bots[0]), contract.success.botRequiredExactly);
});

for (const key of ['ready', 'workspaceId', 'revision', 'readOnly', 'bots']) {
  test(`missing or accessor source field ${key} fails without invoking it`, () => {
    const missing = source(); delete missing[key];
    assertFailure(project(missing), 'BOT_READ_UNAVAILABLE', 503);
    let effects = 0;
    Object.defineProperty(missing, key, { get() { effects++; throw new Error('SYNTHETIC_PRIVATE'); } });
    assertFailure(project(missing), 'BOT_READ_UNAVAILABLE', 503);
    assert.equal(effects, 0);
  });
}

for (const key of contract.success.botRequiredExactly) {
  test(`missing or accessor bot field ${key} fails without invoking it`, () => {
    const input = source(); delete input.bots[0][key];
    assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
    let effects = 0;
    Object.defineProperty(input.bots[0], key, { get() { effects++; throw new Error('SYNTHETIC_PRIVATE'); } });
    assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
    assert.equal(effects, 0);
  });
}

test('inherited fields, holes, accessor array slots and non-array bots are rejected', () => {
  const inherited = Object.create(source());
  assertFailure(project(inherited), 'BOT_READ_UNAVAILABLE', 503);
  for (const bots of [null, {}, new Array(1), 'bots']) {
    assertFailure(project({ ...emptySource(), bots }), 'BOT_READ_UNAVAILABLE', 503);
  }
  const input = source(); let effects = 0;
  Object.defineProperty(input.bots, '0', { get() { effects++; return bot(1); } });
  assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
  assert.equal(effects, 0);
});

test('proxies at every inspected level are rejected before any trap can execute', () => {
  let traps = 0;
  const proxy = value => new Proxy(value, {
    get() { traps++; throw new Error('SYNTHETIC_PRIVATE_PROXY'); },
    ownKeys() { traps++; throw new Error('SYNTHETIC_PRIVATE_PROXY'); },
    getPrototypeOf() { traps++; throw new Error('SYNTHETIC_PRIVATE_PROXY'); },
    getOwnPropertyDescriptor() { traps++; throw new Error('SYNTHETIC_PRIVATE_PROXY'); },
  });
  for (const input of [proxy(source()), { ...source(), bots: proxy([bot(1)]) }, { ...source(), bots: [proxy(bot(1))] }]) {
    assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
  }
  for (const params of [proxy(request()), { ...request(), body: proxy(request().body) },
    { ...request(), body: { ...request().body, payload: proxy(request().body.payload) } }]) {
    assertFailure(validateBotReadRequest(params, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST');
  }
  assertFailure(validateBotReadResponse(proxy(fixture.valid.response), fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
  const revoked = Proxy.revocable(source(), {}); revoked.revoke();
  assertFailure(project(revoked.proxy), 'BOT_READ_UNAVAILABLE', 503);
  assert.equal(traps, 0);
});

test('request accessors at every level are rejected without execution', () => {
  for (const [path, key] of [[[], 'route'], [[], 'body'], [['body'], 'endpoint'], [['body'], 'payload'],
    [['body', 'payload'], 'schemaVersion'], [['body', 'payload'], 'workspaceId']]) {
    const params = request(); let target = params, effects = 0;
    for (const part of path) target = target[part];
    Object.defineProperty(target, key, { get() { effects++; return 'SYNTHETIC_PRIVATE'; } });
    assertFailure(validateBotReadRequest(params, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST');
    assert.equal(effects, 0);
  }
});

test('response accessors at every level and array slot are rejected without execution', () => {
  for (const [path, key] of [[[], 'status'], [[], 'json'], [['json'], 'ok'], [['json'], 'value'],
    [['json', 'value'], 'schemaVersion'], [['json', 'value'], 'workspaceId'], [['json', 'value'], 'revision'],
    [['json', 'value'], 'readOnly'], [['json', 'value'], 'bots'], [['json', 'value', 'bots'], '0'],
    ...contract.success.botRequiredExactly.map(key => [['json', 'value', 'bots', '0'], key])]) {
    const response = clone(fixture.valid.response); let target = response, effects = 0;
    for (const part of path) target = target[part];
    Object.defineProperty(target, key, { get() { effects++; throw new Error('SYNTHETIC_PRIVATE'); } });
    assertFailure(validateBotReadResponse(response, fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
    assert.equal(effects, 0);
  }
});

test('request and response reject extra keys, symbols, hidden required fields and malformed envelope types', () => {
  for (const input of [null, [], 1, 'SYNTHETIC_PRIVATE', false]) {
    assertFailure(validateBotReadRequest(input, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST');
    assertFailure(validateBotReadResponse(input, fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
    assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
  }
  for (const mutate of [
    value => { value[Symbol('private')] = 'SYNTHETIC_PRIVATE'; },
    value => { value.body.extra = 'SYNTHETIC_PRIVATE'; },
    value => { Object.defineProperty(value, 'route', { enumerable: false }); },
  ]) {
    const params = request(); mutate(params);
    assertFailure(validateBotReadRequest(params, fixture.workspaceId), 'BOT_READ_INVALID_REQUEST');
  }
  for (const mutate of [
    value => { value.extra = 'SYNTHETIC_PRIVATE'; },
    value => { value.json.extra = 'SYNTHETIC_PRIVATE'; },
    value => { value.json.value.bots[0].extra = 'SYNTHETIC_PRIVATE'; },
    value => { value.json.value.bots.extra = 'SYNTHETIC_PRIVATE'; },
    value => { value.json.value.bots[Symbol('private')] = true; },
    value => { Object.defineProperty(value, 'status', { enumerable: false }); },
  ]) {
    const response = clone(fixture.valid.response); mutate(response);
    assertFailure(validateBotReadResponse(response, fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
  }
});

test('unready source and non-boolean readOnly metadata never yield a roster', () => {
  for (const ready of [false, null, 1, 'true', undefined]) {
    assertFailure(project({ ...source(), ready }), 'BOT_READ_UNAVAILABLE', 503);
  }
  for (const readOnly of [null, 1, 'true', undefined]) {
    assertFailure(project({ ...source(), readOnly }), 'BOT_READ_UNAVAILABLE', 503);
  }
});

test('readOnly is strict boolean Host metadata and preserves both false and true', () => {
  for (const readOnly of [false, true]) {
    const result = project({ ...source(), readOnly });
    assert.equal(result.status, 200);
    assert.equal(result.json.value.readOnly, readOnly);
    assert.deepEqual(validateBotReadResponse(result, fixture.workspaceId), { ok: true, value: result });
  }
});

test('revisions accept only nonnegative safe integers including the exact maximum', () => {
  for (const revision of [0, 1, Number.MAX_SAFE_INTEGER]) {
    assert.equal(project({ ...emptySource(), revision }).json.value.revision, revision);
  }
  for (const revision of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '7', 7n, null]) {
    assertFailure(project({ ...source(), revision }), 'BOT_READ_UNAVAILABLE', 503);
  }
});

test('authenticated workspace is required and matched exactly without Unicode normalization', () => {
  for (const expected of [null, undefined, '', 1, '\0', '\ud800']) {
    assertFailure(validateBotReadRequest(request(), expected), 'BOT_READ_INVALID_REQUEST');
    assertFailure(projectBotReadSnapshot(source(), expected), 'BOT_READ_UNAVAILABLE', 503);
    assertFailure(validateBotReadResponse(fixture.valid.response, expected), 'BOT_READ_INVALID_RESPONSE');
  }
  const composed = '\u00e9', decomposed = 'e\u0301';
  assert.equal(validateBotReadRequest(request(composed), composed).ok, true);
  assert.equal(validateBotReadRequest(request(decomposed), decomposed).ok, true);
  assertFailure(validateBotReadRequest(request(composed), decomposed), 'BOT_READ_INVALID_REQUEST');
  assertFailure(projectBotReadSnapshot(emptySource(composed), decomposed), 'BOT_READ_UNAVAILABLE', 503);
  const input = emptySource(); input.bots = [bot(1), bot(2)];
  input.bots[0].id = composed; input.bots[1].id = decomposed;
  input.bots[0].sessionId = composed; input.bots[1].sessionId = decomposed;
  assert.equal(project(input).status, 200);
  assert.equal(project(input).json.value.bots[0].id, composed);
  assert.equal(project(input).json.value.bots[1].id, decomposed);
});

test('duplicate bot and current session identities reject the entire snapshot', () => {
  for (const key of ['id', 'sessionId']) {
    const input = source(); input.bots[1][key] = input.bots[0][key];
    assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
  }
});

for (const [key, limit] of [['id', 1024], ['sessionId', 1024], ['name', 256], ['model', 256], ['permission', 64]]) {
  test(`${key} requires a nonempty NUL-free Unicode scalar string within its UTF-8 limit`, () => {
    const invalid = ['', '\0', 'a\0b', '\ud800', '\udc00', '\ud800x', 1, {}, undefined];
    if (key !== 'model' && key !== 'permission') invalid.push(null);
    for (const value of invalid) {
      const input = source(); input.bots[0][key] = value;
      assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
    }
    for (const character of ['a', 'é', '😀']) {
      const width = Buffer.byteLength(character), exact = character.repeat(limit / width);
      const input = source(); input.bots[0][key] = exact;
      assert.equal(project(input).status, 200);
      input.bots[0][key] += character;
      assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
    }
  });
}

test('nullable metadata must still be present, and valid replacement characters are preserved', () => {
  const input = source(); input.bots[0].name = '\ufffd'; input.bots[0].model = null; input.bots[0].permission = null;
  assert.equal(project(input).json.value.bots[0].name, '\ufffd');
  for (const key of ['model', 'permission']) {
    const malformed = source(); delete malformed.bots[0][key];
    assertFailure(project(malformed), 'BOT_READ_UNAVAILABLE', 503);
  }
});

test('workspace identities obey the same exact UTF-8 scalar bound', () => {
  for (const character of ['a', 'é', '😀']) {
    const exact = character.repeat(1024 / Buffer.byteLength(character));
    assert.equal(validateBotReadRequest(request(exact), exact).ok, true);
    assert.equal(projectBotReadSnapshot(emptySource(exact), exact).status, 200);
    assertFailure(validateBotReadRequest(request(exact + character), exact + character), 'BOT_READ_INVALID_REQUEST');
    assertFailure(projectBotReadSnapshot(emptySource(exact + character), exact + character), 'BOT_READ_UNAVAILABLE', 503);
  }
});

test('zero and exactly 100 bots are accepted; 101 bots are rejected', () => {
  assert.equal(project(emptySource()).status, 200);
  const input = emptySource(); input.bots = Array.from({ length: 100 }, (_, index) => bot(index));
  assert.equal(project(input).json.value.bots.length, 100);
  input.bots.push(bot(100));
  assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
});

test('canonical request bytes are bounded at the exact limit, including JSON escaping', () => {
  const overhead = bytes(request(''));
  const workspaceForSize = target => {
    const remaining = target - overhead;
    return '\u0001'.repeat(Math.floor(remaining / 6)) + 'x'.repeat(remaining % 6);
  };
  const exact = workspaceForSize(4096), oversized = workspaceForSize(4097);
  assert.equal(bytes(request(exact)), 4096);
  assert.equal(bytes(request(oversized)), 4097);
  assert.equal(validateBotReadRequest(request(exact), exact).ok, true);
  assertFailure(validateBotReadRequest(request(oversized), oversized), 'BOT_READ_INVALID_REQUEST');
});

test('full serialized success result is bounded at exactly 262144 UTF-8 bytes', () => {
  const input = emptySource();
  input.bots = Array.from({ length: 100 }, (_, index) => ({ id: `${index}:`.padEnd(1024, 'i'),
    sessionId: `${index}:`.padEnd(1024, 's'), name: 'n'.repeat(256), model: 'm'.repeat(256), permission: 'p'.repeat(64) }));
  // Start below the result budget, then distribute only the exact remaining ASCII bytes.
  for (const entry of input.bots) { entry.name = 'n'; entry.model = null; entry.permission = null; }
  const envelope = { status: 200, json: { ok: true, value: { schemaVersion: 1, workspaceId: input.workspaceId,
    revision: input.revision, readOnly: true, bots: input.bots } } };
  let remaining = 262144 - bytes(envelope);
  assert.ok(remaining > 0);
  for (const entry of input.bots) {
    for (const [key, capacity] of [['name', 255], ['model', 256], ['permission', 64]]) {
      if (remaining <= 0) break;
      const overhead = entry[key] === null ? -2 : 0; // null (4 bytes) becomes a quoted string (2 bytes).
      const amount = Math.min(capacity, remaining - overhead);
      if (amount < 1) continue;
      entry[key] = (entry[key] ?? '') + 'x'.repeat(amount);
      remaining -= amount + overhead;
    }
  }
  const exact = project(input);
  assert.equal(remaining, 0);
  assert.equal(exact.status, 200);
  assert.equal(bytes(exact), 262144);
  assert.equal(validateBotReadResponse(exact, fixture.workspaceId).ok, true);
  const available = input.bots.find(entry => entry.name.length < 256);
  assert.ok(available); available.name += 'x';
  assertFailure(project(input), 'BOT_READ_UNAVAILABLE', 503);
  const oversized = clone(exact); oversized.json.value.bots.find(entry => entry.name.length < 256).name += 'x';
  assert.equal(bytes(oversized), 262145);
  assertFailure(validateBotReadResponse(oversized, fixture.workspaceId), 'BOT_READ_INVALID_RESPONSE');
});

test('large, cyclic and malformed private inputs fail with the same bounded redacted envelope', () => {
  const cycle = source(); cycle.bots = [cycle];
  const oversized = source(); oversized.bots[0].id = 'SYNTHETIC_PRIVATE'.repeat(100000);
  for (const input of [cycle, oversized, { ...source(), revision: Symbol('SYNTHETIC_PRIVATE') }]) {
    const result = project(input);
    assertFailure(result, 'BOT_READ_UNAVAILABLE', 503);
    assert.ok(bytes(result) < 128);
    assert.ok(!JSON.stringify(result).includes('SYNTHETIC_PRIVATE'));
  }
});
