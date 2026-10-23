import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { boundedProcess, processEnvironment, runtimeEnvironment } from './bounded-process.mjs';
import { assertUnprivilegedStatus, assertSeparateNetworkNamespace } from './run.mjs';
import { createNpmConfigs } from './bootstrap.mjs';

const configScratchParent = process.env.QUENDERIN_GUARD_SCRATCH || process.env.RUNNER_TEMP;
test('npm loads distinct empty scratch configs and rejects the former duplicate path', { timeout: 15_000, skip: !configScratchParent && 'Registered guard scratch or hosted RUNNER_TEMP required' }, async () => {
  const scratch = mkdtempSync(join(configScratchParent, 'npm-config-guard-'));
  try {
    const configs = createNpmConfigs(scratch);
    assert.notEqual(configs.npm_config_userconfig, configs.npm_config_globalconfig);
    for (const file of Object.values(configs)) {
      assert.equal(readFileSync(file, 'utf8'), '');
      assert.equal(statSync(file).mode & 0o777, 0o600);
    }
    const env = { ...processEnvironment(), TMPDIR: scratch,
      npm_config_cache: join(scratch, 'cache'), npm_config_prefix: join(scratch, 'prefix'),
      npm_config_offline: 'true', npm_config_ignore_scripts: 'true', npm_config_audit: 'false', npm_config_fund: 'false' };
    const former = await boundedProcess('npm', ['config', 'get', 'userconfig'], { cwd: scratch, timeoutMs: 5000, env: { ...env, npm_config_userconfig: '/dev/null', npm_config_globalconfig: '/dev/null' } });
    assert.notEqual(former.code, 0);
    assert.match(former.stderr.toString(), /double-loading config/);
    const corrected = await boundedProcess('npm', ['config', 'get', 'userconfig'], { cwd: scratch, timeoutMs: 5000, env: { ...env, ...configs } });
    assert.equal(corrected.error, undefined);
    assert.equal(corrected.timedOut, false);
    assert.equal(corrected.outputExceeded, false);
    assert.equal(corrected.code, 0);
    assert.equal(corrected.stdout.toString().trim(), configs.npm_config_userconfig);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test('runtime environment has only the explicit fixture allowlist', () => {
  const result = runtimeEnvironment('/tmp/fixture', '/tmp/source', '/tmp/fixture/facts.json');
  assert.deepEqual(Object.keys(result).sort(), ['CI', 'DSH_HOME', 'GITHUB_ACTIONS', 'LANG', 'LC_ALL', 'PATH', 'QUENDERIN_FIXTURE_FACTS', 'QUENDERIN_FIXTURE_ROOT', 'QUENDERIN_HOST_SOURCE', 'TMPDIR', 'TZ'].sort());
  assert.equal(result.DSH_HOME, '/tmp/fixture');
  assert.equal(result.TMPDIR, '/tmp/fixture');
  for (const key of ['HOME', 'XDG_CONFIG_HOME', 'NODE_OPTIONS', 'CODEX_HOME', 'DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'QUENDERIN_PARENT_NETNS']) assert.equal(Object.hasOwn(result, key), false);
});

test('network namespace guard requires a valid parent baseline and a different valid current identity', () => {
  const error = { message: 'STOP: distinct valid parent and fixture network namespaces required' };
  for (const missing of [undefined, null, '']) assert.throws(() => assertSeparateNetworkNamespace(missing, 'net:[2]'), error);
  for (const malformed of ['net:[]', 'net:[-1]', 'net:1', 'mnt:[1]', ' net:[1]', 'net:[1]\n', 1]) assert.throws(() => assertSeparateNetworkNamespace(malformed, 'net:[2]'), error);
  assert.throws(() => assertSeparateNetworkNamespace('net:[1]', 'net:[1]'), error);
  assert.throws(() => assertSeparateNetworkNamespace('net:[1]', undefined), error);
  assert.throws(() => assertSeparateNetworkNamespace('net:[1]', 'net:[invalid]'), error);
  assert.doesNotThrow(() => assertSeparateNetworkNamespace('net:[1]', 'net:[2]'));
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
