import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./Code.gs', import.meta.url), 'utf8');
const manifest = JSON.parse(readFileSync(new URL('./appsscript.json', import.meta.url), 'utf8'));
const reportId = '12345678-1234-4234-8234-123456789abc';
const receiptId = '87654321-4321-4321-8321-cba987654321';
const receivedAt = '2026-10-28T00:00:00.000Z';
const base = {
  schema: 1, reportId, platform: 'android', appVersion: '0.4.1',
  source: 'local-chat', reason: 'other', content: 'Synthetic fixture excerpt.'
};

function fixture(initial = {'qr.enabled': 'true'}, options = {}) {
  const values = {...initial};
  const calls = [];
  const logs = [];
  const logger = new Proxy({}, {get: (_, name) => (...args) => {
    logs.push([name, ...args]);
    throw new Error('Logging is forbidden in this fixture');
  }});
  let held = false;
  const lock = {
    tryLock(ms) {
      calls.push(['tryLock', ms]);
      if (options.lockThrows) throw new Error('Synthetic lock error');
      if (options.busy || held) return false;
      held = true;
      return true;
    },
    releaseLock() {
      calls.push(['releaseLock']);
      held = false;
      if (options.releaseThrows) throw new Error('Synthetic release error');
    }
  };
  const properties = {
    getProperties() {
      assert.equal(held, true);
      calls.push(['getProperties']);
      if (options.readThrows) throw new Error('Synthetic quota error');
      return {...values};
    },
    setProperty(key, value) {
      assert.equal(held, true);
      calls.push(['setProperty', key]);
      assert.equal(Object.hasOwn(values, key), false, 'must never overwrite a report');
      if (options.writeThrows) throw new Error('Synthetic quota error');
      if (!options.dropWrite) values[key] = value;
      if (options.afterWrite) options.afterWrite();
      if (options.writeThenThrows) throw new Error('Synthetic ambiguous write');
    },
    getProperty(key) {
      assert.equal(held, true);
      calls.push(['getProperty', key]);
      if (options.readbackThrows) throw new Error('Synthetic readback error');
      return values[key] ?? null;
    }
  };
  const context = vm.createContext({
    console: logger, Logger: logger,
    LockService: {getScriptLock: () => lock},
    PropertiesService: {getScriptProperties: () => properties},
    Utilities: {getUuid: () => receiptId},
    ContentService: {
      MimeType: {JSON: 'application/json'},
      createTextOutput(text) { return {text, setMimeType(mime) { this.mime = mime; return this; }}; }
    }
  });
  vm.runInContext(source, context);
  const dependencies = {
    lock: () => lock,
    properties: () => properties,
    uuid: () => receiptId,
    now: () => receivedAt
  };
  const event = (payload = base) => {
    const contents = typeof payload === 'string' ? payload : JSON.stringify(payload);
    return {postData: {contents, type: 'application/json; charset=utf-8'}, contentLength: Buffer.byteLength(contents)};
  };
  const receiveEvent = input => JSON.parse(JSON.stringify(context.qrReceive_(input, dependencies)));
  const receive = payload => receiveEvent(event(payload));
  return {values, calls, logs, context, dependencies, event, receive, receiveEvent, held: () => held};
}

function success(result, id = reportId) {
  assert.deepEqual(result, {ok: true, code: 'received', reportId: id, receiptId, receivedAt});
}
function failure(result, code) { assert.deepEqual(result, {ok: false, code}); }
function noWrites(f) { assert.equal(f.calls.some(([name]) => name === 'setProperty'), false); }

test('persists a canonical single-property envelope before issuing its receipt', () => {
  const f = fixture();
  success(f.receive(base));
  const record = JSON.parse(f.values[`report:${reportId}`]);
  assert.deepEqual(record, {schema: 1, receiptId, receivedAt, report: {...base, note: ''}});
  assert.deepEqual(f.calls.map(([name]) => name), ['tryLock', 'getProperties', 'setProperty', 'getProperty', 'releaseLock']);
  assert.equal(f.calls[0][1], 200);
  assert.equal(f.held(), false);
});

test('identical retries and reordered JSON reconcile without another write', () => {
  const f = fixture();
  success(f.receive(base));
  success(f.receive({...base, note: ''}));
  success(f.receive(Object.fromEntries(Object.entries(base).reverse())));
  assert.equal(f.calls.filter(([name]) => name === 'setProperty').length, 1);
});

test('changed payload with an existing ID conflicts and preserves the first report', () => {
  const f = fixture();
  success(f.receive(base));
  const before = {...f.values};
  for (const change of [{content: 'Edited fixture'}, {note: 'Changed'}, {reason: 'violence'}, {appVersion: '0.5'}]) {
    failure(f.receive({...base, ...change}), 'conflict');
    assert.deepEqual(f.values, before);
  }
});

test('32 reports fill the inbox; identical retry still gets its receipt', () => {
  const f = fixture();
  for (let index = 0; index < 32; index += 1) {
    const id = `12345678-1234-4234-8234-${index.toString(16).padStart(12, '0')}`;
    success(f.receive({...base, reportId: id}), id);
  }
  const before = {...f.values};
  failure(f.receive(base), 'unavailable');
  const id = '12345678-1234-4234-8234-000000000000';
  success(f.receive({...base, reportId: id}), id);
  assert.deepEqual(f.values, before);
  assert.equal(Object.keys(f.values).length, 33, 'below the manual UI limit of 50');
  assert.ok(Object.entries(f.values).filter(([key]) => key.startsWith('report:'))
    .reduce((sum, [, value]) => sum + Buffer.byteLength(value), 0) <= 262144);
});

test('absent/false enable flag disables intake, including retries', () => {
  for (const initial of [{}, {'qr.enabled': 'false'}]) {
    const f = fixture(initial);
    failure(f.receive(base), 'unavailable');
    noWrites(f);
  }
  const f = fixture();
  success(f.receive(base));
  f.values['qr.enabled'] = 'false';
  failure(f.receive(base), 'unavailable');
});

test('unknown, corrupt, oversized, or excess stored state fails closed unchanged', () => {
  const valid = fixture();
  success(valid.receive(base));
  const recordKey = `report:${reportId}`;
  const originalRecord = JSON.parse(valid.values[recordKey]);
  const states = [
    {'qr.enabled': 'TRUE'},
    {'qr.enabled': 'true', unexpected: 'value'},
    {'qr.enabled': 'true', 'report:not-a-uuid': '{}'},
    {'qr.enabled': 'true', [recordKey]: 'broken'},
    {'qr.enabled': 'true', [recordKey]: '{}'},
    {'qr.enabled': 'true', [recordKey]: 'x'.repeat(8193)},
    {'qr.enabled': 'true', [recordKey]: 'é'.repeat(4097)},
    {'qr.enabled': 'true', [recordKey]: JSON.stringify({...originalRecord, unexpected: 'field'})},
    {'qr.enabled': 'true', [recordKey]: JSON.stringify({...originalRecord, receivedAt: '2026-02-31T00:00:00.000Z'})},
    {'qr.enabled': 'true', [recordKey]: JSON.stringify({...originalRecord, report: {...base, note: '', reportId: receiptId}})},
    {'qr.enabled': 'true', [recordKey]: valid.values[recordKey] + ' '},
    Object.fromEntries(Array.from({length: 34}, (_, index) => [`unknown:${index}`, 'x']))
  ];
  for (const state of states) {
    const f = fixture(state);
    failure(f.receive(base), 'unavailable');
    assert.deepEqual(f.values, state);
    noWrites(f);
    assert.equal(f.held(), false);
  }
});

test('unknown fields, missing fields, wrong types and unsupported values never touch storage', () => {
  const invalid = [null, [], 1, 'text', {...base, unknown: true}, {...base, token: 'synthetic-not-a-token'},
    {...base, schema: '1'}, {...base, schema: 2}, {...base, reportId: reportId.toUpperCase()},
    {...base, reportId: receiptId.replace('-4321-4321-', '-4321-1321-')}, {...base, platform: 'ios'},
    {...base, source: ['local-chat']}, {...base, source: 'unknown'}, {...base, reason: {}},
    {...base, appVersion: ''}, {...base, appVersion: 'x'.repeat(65)}, {...base, appVersion: '1\n'},
    {...base, content: 1}, {...base, content: ' \n\t'}, {...base, content: 'x'.repeat(6001)},
    {...base, note: null}, {...base, note: 'x'.repeat(1001)}, {...base, content: '\ud800'}, {...base, note: '\udfff'}];
  for (const key of Object.keys(base)) {
    const missing = {...base};
    delete missing[key];
    invalid.push(missing);
  }
  for (const payload of invalid) {
    const f = fixture();
    failure(f.receive(payload), 'invalid_request');
    assert.equal(f.calls.length, 0);
  }
});

test('malformed JSON and non-JSON media types never touch storage', () => {
  for (const input of [undefined, {}, {postData: {}}, {postData: {contents: 5}},
    {postData: {contents: '{}', type: 'text/plain'}}, {postData: {contents: '{}', type: 'application/jsonp'}}]) {
    const f = fixture();
    failure(f.receiveEvent(input), 'invalid_request');
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  failure(f.receive('{'), 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('raw UTF8 bytes are enforced at the exact boundary before storage or parsing', () => {
  const raw = JSON.stringify(base);
  const exact = raw + ' '.repeat(8192 - Buffer.byteLength(raw));
  success(fixture().receive(exact));
  for (const text of [exact + ' ', JSON.stringify({...base, content: 'é'.repeat(3000)}) + ' '.repeat(2200)]) {
    assert.ok(Buffer.byteLength(text) > 8192);
    const f = fixture();
    failure(f.receive(text), 'too_large');
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  failure(f.receiveEvent({...f.event(base), contentLength: 8193}), 'too_large');
  assert.equal(f.calls.length, 0);
});

test('content/note limits count UTF8 bytes, preserve text, and reject malformed Unicode', () => {
  const accepted = {...base, content: '🙂'.repeat(1500), note: 'é'.repeat(500)};
  const f = fixture();
  success(f.receive(accepted));
  assert.deepEqual(JSON.parse(f.values[`report:${reportId}`]).report, accepted);
  for (const change of [{content: '🙂'.repeat(1500) + 'x'}, {note: 'é'.repeat(500) + 'x'}]) {
    const rejected = fixture();
    failure(rejected.receive({...base, ...change}), 'invalid_request');
    assert.equal(rejected.calls.length, 0);
  }
  for (const value of ['ASCII', 'é', '漢', '🙂', 'x🙂漢é']) {
    const actual = f.context.qrUtf8Bytes_(value);
    assert.equal(actual, Buffer.byteLength(value));
  }
  assert.equal(f.context.qrUtf8Bytes_('\ud800'), -1);
  assert.equal(f.context.qrUtf8Bytes_('\udfff'), -1);
});

test('stored canonical JSON limit includes escaping and receipt overhead', () => {
  const f = fixture();
  const sample = {...base, content: 'x', note: ''};
  const envelope = {schema: 1, receiptId, receivedAt, report: sample};
  const overhead = Buffer.byteLength(JSON.stringify(envelope)) - 1;
  // Backslashes produce two JSON bytes each. Keep the request <=8192 while
  // independently exercising the larger stored envelope at 8192 and 8193.
  const content = '\\'.repeat(Math.floor((8192 - overhead) / 2)) + 'x'.repeat((8192 - overhead) % 2);
  assert.ok(Buffer.byteLength(content) <= 6000);
  success(f.receive({...base, content}));
  assert.equal(Buffer.byteLength(f.values[`report:${reportId}`]), 8192);
  const rejected = fixture();
  const payload = {...base, content: content + 'x'};
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= 8192);
  failure(rejected.receive(payload), 'too_large');
  noWrites(rejected);
});

test('quota, lock, property-read and write failures never claim receipt', () => {
  for (const options of [{busy: true}, {lockThrows: true}, {readThrows: true}, {writeThrows: true}, {dropWrite: true}]) {
    const f = fixture(undefined, options);
    failure(f.receive(base), 'unavailable');
    assert.equal(Object.keys(f.values).length, 1);
    assert.equal(f.held(), false);
  }
});

test('write/readback ambiguity preserves data and identical manual retry reconciles', () => {
  for (const option of ['readbackThrows', 'writeThenThrows']) {
    const options = {[option]: true};
    const f = fixture(undefined, options);
    failure(f.receive(base), 'unavailable');
    assert.ok(f.values[`report:${reportId}`]);
    assert.equal(f.held(), false);
    options[option] = false;
    success(f.receive(base));
    assert.equal(f.calls.filter(([name]) => name === 'setProperty').length, 1);
  }
});

test('an overlapping admission cannot race capacity or overwrite a pending report', () => {
  const options = {};
  const f = fixture(undefined, options);
  let overlapping;
  options.afterWrite = () => { overlapping = f.receive({...base, reportId: receiptId}); };
  success(f.receive(base));
  failure(overlapping, 'unavailable');
  assert.equal(Object.keys(f.values).length, 2);
});

test('invalid server receipt/time and property service failures fail closed', () => {
  for (const changes of [{uuid: () => 'invalid'}, {now: () => 'invalid'},
    {properties: () => { throw new Error('Synthetic missing service'); }}]) {
    const f = fixture();
    Object.assign(f.dependencies, changes);
    failure(f.receive(base), 'unavailable');
    noWrites(f);
    assert.equal(f.held(), false);
  }
});

test('GET exposes only a method error; POST uses JSON ContentService response', () => {
  const f = fixture();
  const get = f.context.doGet({parameter: {admin: 'true', token: 'synthetic-not-a-token'}});
  assert.equal(get.mime, 'application/json');
  failure(JSON.parse(get.text), 'method_not_allowed');
  assert.equal(f.calls.length, 0);
  const post = f.context.doPost(f.event(base));
  assert.equal(post.mime, 'application/json');
  const result = JSON.parse(post.text);
  assert.equal(result.ok, true);
  assert.equal(result.reportId, reportId);
  assert.equal(Object.hasOwn(result, 'content'), false);
});

test('no token, content, exceptions, network calls, or background jobs are logged/sent', () => {
  const f = fixture(undefined, {readThrows: true});
  failure(f.receive({...base, content: 'SYNTHETIC_PRIVATE_EXCERPT', note: 'SYNTHETIC_PRIVATE_NOTE'}), 'unavailable');
  failure(f.receive({...base, token: 'synthetic-not-a-token'}), 'invalid_request');
  assert.deepEqual(f.logs, []);
  assert.doesNotMatch(source, /\b(?:console|Logger)\s*\./);
  assert.doesNotMatch(source, /\b(?:UrlFetchApp|MailApp|GmailApp|DriveApp|SpreadsheetApp|ScriptApp|fetch|setTimeout|setInterval)\s*[.(]/);
  assert.doesNotMatch(source, /\b(?:deleteProperty|deleteAllProperties|setProperties)\s*\(/);
  assert.deepEqual(manifest.oauthScopes, []);
  assert.deepEqual(manifest.dependencies, {});
  assert.equal(manifest.exceptionLogging, 'NONE');
  assert.equal(manifest.runtimeVersion, 'V8');
  assert.deepEqual(manifest.webapp, {executeAs: 'USER_DEPLOYING', access: 'ANYONE_ANONYMOUS'});
});
