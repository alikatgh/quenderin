import { test } from 'node:test';
import assert from 'node:assert/strict';
import { boundedProcess, runtimeEnvironment } from './bounded-process.mjs';
import { assertUnprivilegedStatus } from './run.mjs';

test('runtime environment has only the explicit fixture allowlist', () => {
  const result = runtimeEnvironment('/tmp/fixture', '/tmp/source', '/tmp/fixture/facts.json');
  assert.deepEqual(Object.keys(result).sort(), ['CI', 'DSH_HOME', 'GITHUB_ACTIONS', 'LANG', 'LC_ALL', 'PATH', 'QUENDERIN_FIXTURE_FACTS', 'QUENDERIN_FIXTURE_ROOT', 'QUENDERIN_HOST_SOURCE', 'TMPDIR', 'TZ'].sort());
  assert.equal(result.DSH_HOME, '/tmp/fixture');
  assert.equal(result.TMPDIR, '/tmp/fixture');
  for (const key of ['HOME', 'XDG_CONFIG_HOME', 'NODE_OPTIONS', 'CODEX_HOME', 'DEEPSEEK_API_KEY', 'OPENAI_API_KEY']) assert.equal(Object.hasOwn(result, key), false);
});

test('privilege guard rejects root, retained capabilities and escalation', () => {
  const valid = 'Uid:\t1001\t1001\t1001\t1001\nCapEff:\t0000000000000000\nCapPrm:\t0000000000000000\nCapBnd:\t0000000000000000\nCapInh:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\n';
  assert.doesNotThrow(() => assertUnprivilegedStatus(valid));
  const rejected = [valid.replace('1001\t1001\t1001\t1001', '1001\t1001\t0\t1001'), valid.replace('1001\t1001\t1001\t1001', '0\t0\t0\t0'), valid.replace('NoNewPrivs:\t1', 'NoNewPrivs:\t0'), valid.replace('NoNewPrivs:\t1\n', ''),
    ...['CapEff', 'CapPrm', 'CapBnd', 'CapInh', 'CapAmb'].flatMap(name => [valid.replace(`${name}:\t0000000000000000`, `${name}:\t0000000000200000`), valid.replace(`${name}:\t0000000000000000\n`, '')])];
  for (const status of rejected) assert.throws(() => assertUnprivilegedStatus(status), { message: 'STOP: unprivileged capability-free no-new-privs runner required' });
});

test('hard deadline kills a TERM-ignoring child and its TERM-ignoring grandchild', { timeout: 5000 }, async () => {
  // Built-in Node modules only. The grandchild retains the same process group.
  const grandchild = "process.on('SIGTERM',()=>{});process.stdout.write('grandchild:'+process.pid+'\\n');setInterval(()=>{},1000)";
  const child = `const {spawn}=require('node:child_process');process.on('SIGTERM',()=>{});process.stdout.write('child:'+process.pid+'\\n');spawn(process.execPath,['-e',${JSON.stringify(grandchild)}],{stdio:['ignore','inherit','inherit'],env:{}});setInterval(()=>{},1000)`;
  const result = await boundedProcess(process.execPath, ['-e', child], { env: {}, timeoutMs: 700, graceMs: 100, maxOutputBytes: 4096 });
  assert.equal(result.timedOut, true);
  assert.equal(result.signal, 'SIGKILL');
  assert.ok(result.elapsedMs < 2500);
  const text = result.stdout.toString();
  assert.match(text, /child:\d+/);
  assert.match(text, /grandchild:\d+/);
  // A signal-zero success can include a reparented zombie; probing the group
  // after KILL establishes no remaining running group member on this host.
  const pid = Number(text.match(/^child:(\d+)/m)[1]);
  await new Promise(done => setTimeout(done, 50));
  assert.throws(() => process.kill(-pid, 0), error => error.code === 'ESRCH');
});

test('output flood stops at the aggregate output ceiling', { timeout: 5000 }, async () => {
  const result = await boundedProcess(process.execPath, ['-e', "process.on('SIGTERM',()=>{});setInterval(()=>process.stdout.write('x'.repeat(8192)),1)"], { env: {}, timeoutMs: 2000, graceMs: 100, maxOutputBytes: 1024 });
  assert.equal(result.outputExceeded, true);
  assert.equal(result.stdout.length + result.stderr.length, 1024);
  assert.ok(result.elapsedMs < 1500);
});
