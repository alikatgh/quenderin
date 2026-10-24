// The production module imports happen only in the network-isolated child.
import { readFileSync, readlinkSync, mkdtempSync, rmSync, openSync, fstatSync, readSync, closeSync, constants } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { checkLock, root } from './check-lock.mjs';
import { boundedProcess, processEnvironment, runtimeEnvironment } from './bounded-process.mjs';

export function assertUnprivilegedStatus(status) {
  const field = name => status.match(new RegExp(`^${name}:[ \\t]*([^\\n]+)$`, 'm'))?.[1].trim();
  const uids = field('Uid');
  const capabilities = ['CapEff', 'CapPrm', 'CapBnd', 'CapInh', 'CapAmb'];
  if (!uids || !/^\d+[ \t]+\d+[ \t]+\d+[ \t]+\d+$/.test(uids)
      || uids.split(/[ \t]+/).some(uid => Number(uid) === 0)
      || capabilities.some(name => !/^0+$/.test(field(name) ?? '')) || field('NoNewPrivs') !== '1') {
    throw new Error('STOP: unprivileged capability-free no-new-privs runner required');
  }
}

export function assertSeparateNetworkNamespace(parent, current) {
  const valid = value => typeof value === 'string' && /^net:\[[0-9]+\]$/.test(value);
  if (!valid(parent) || !valid(current) || parent === current) {
    throw new Error('STOP: distinct valid parent and fixture network namespaces required');
  }
}

async function run() {
  const deadline = performance.now() + 29_000;
  const reviewed = process.argv[2];
  if (!reviewed) throw new Error('Reviewed full-lock SHA256 required');
  checkLock(reviewed);
  if (process.env.GITHUB_ACTIONS !== 'true' || process.platform !== 'linux' || !/^22\./.test(process.versions.node)) throw new Error('Hosted Linux Node 22 required');
  if (process.getuid() === 0) throw new Error('STOP: unprivileged capability-free no-new-privs runner required');
  assertUnprivilegedStatus(readFileSync('/proc/self/status', 'utf8'));
  // A separate network namespace with only loopback has no external transport.
  assertSeparateNetworkNamespace(process.env.QUENDERIN_PARENT_NETNS, readlinkSync('/proc/self/ns/net'));
  const interfaces = readFileSync('/proc/net/dev', 'utf8').trim().split('\n').slice(2).map(line => line.split(':')[0].trim());
  const ipv4 = readFileSync('/proc/net/route', 'utf8').trim().split('\n').slice(1);
  const ipv6 = readFileSync('/proc/net/ipv6_route', 'utf8').trim().split('\n').filter(Boolean);
  if (interfaces.some(name => name !== 'lo')
      || ipv4.some(line => line.trim().split(/\s+/)[0] !== 'lo') || ipv6.some(line => line.trim().split(/\s+/).at(-1) !== 'lo')) {
    throw new Error('STOP: run inside a separate loopback-only Linux network namespace');
  }
  const source = process.env.QUENDERIN_HOST_SOURCE;
  const bot = process.env.QUENDERIN_BOT_SOURCE;
  if (!source || !source.startsWith('/')) throw new Error('Absolute pinned patched Host checkout required');
  if (!bot || !bot.startsWith('/')) throw new Error('Absolute pinned patched Bot checkout required');
  const verified = await boundedProcess('python3', ['-B', resolve(root, 'tools/check_host.py'), source], { cwd: root, env: { ...processEnvironment(), QUENDERIN_BOT_SOURCE: bot }, timeoutMs: 5000 });
  process.stdout.write(verified.stdout.subarray(0, 32_768));
  process.stderr.write(verified.stderr.subarray(0, 32_768));
  if (verified.error || verified.code !== 0 || verified.timedOut || verified.outputExceeded) throw new Error('Host source verification failed');
  const fixtureRoot = mkdtempSync('/tmp/quenderin-official-runtime-');
  const factsPath = join(fixtureRoot, 'actual-runtime-facts.json');
  try {
    const remaining = Math.floor(deadline - performance.now());
    if (remaining < 1) throw new Error('Official runtime fixture exceeded its finite budget');
    const result = await boundedProcess(process.execPath, [resolve(root, 'node_modules/vitest/vitest.mjs'), 'run', '--config', resolve(root, 'vitest.config.mjs')], {
      cwd: root, timeoutMs: remaining,
      env: runtimeEnvironment(fixtureRoot, source, factsPath, bot),
    });
    // Keep diagnostic output bounded as well as the canonical facts.
    process.stdout.write(result.stdout.subarray(0, 32_768));
    process.stderr.write(result.stderr.subarray(0, 32_768));
    if (result.error || result.code !== 0 || result.timedOut || result.outputExceeded) throw new Error('Official runtime fixture failed or exceeded its finite budget');
    const descriptor = openSync(factsPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    let facts;
    try {
      const stat = fstatSync(descriptor);
      if (!stat.isFile() || stat.size > 262_144) throw new Error('Passing runtime facts exceed 256 KiB');
      facts = Buffer.alloc(stat.size);
      let offset = 0;
      while (offset < facts.length) {
        const received = readSync(descriptor, facts, offset, facts.length - offset, null);
        if (received === 0) throw new Error('Passing runtime facts size differs');
        offset += received;
      }
      if (readSync(descriptor, Buffer.alloc(1), 0, 1, null) !== 0) throw new Error('Passing runtime facts size differs');
    } finally {
      closeSync(descriptor);
    }
    const value = JSON.parse(facts.toString('utf8'));
    if (value.schema !== 1 || value.runtime !== 'official-0.2.1-rc.1' || value.scriptedModelCalls !== 2 || value.inertToolExecutions !== 1) throw new Error('Passing runtime facts identity differs');
    process.stdout.write('QUENDERIN_OFFICIAL_RUNTIME_FACTS_BEGIN\n');
    process.stdout.write(facts);
    process.stdout.write('QUENDERIN_OFFICIAL_RUNTIME_FACTS_END\n');
    const botFactsPath = join(fixtureRoot, 'bot-runtime-facts.json');
    const botFactsDescriptor = openSync(botFactsPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    let botFacts;
    try {
      const stat = fstatSync(botFactsDescriptor);
      if (!stat.isFile() || stat.size > 262_144) throw new Error('Bot runtime facts exceed 256 KiB');
      botFacts = Buffer.alloc(stat.size);
      let offset = 0;
      while (offset < botFacts.length) {
        const received = readSync(botFactsDescriptor, botFacts, offset, botFacts.length - offset, null);
        if (!received) throw new Error('Bot runtime facts size differs');
        offset += received;
      }
      if (readSync(botFactsDescriptor, Buffer.alloc(1), 0, 1, null)) throw new Error('Bot runtime facts size differs');
    } finally { closeSync(botFactsDescriptor); }
    const botValue = JSON.parse(botFacts.toString('utf8'));
    if (botValue.schema !== 1 || botValue.botRevision !== '1bebe826f74e9a72cabafd3b80602b05af867b38' || botValue.readEffects.modelCalls !== 0) throw new Error('Bot runtime facts identity differs');
    process.stdout.write('QUENDERIN_OFFICIAL_BOT_RUNTIME_FACTS_BEGIN\n');
    process.stdout.write(botFacts);
    process.stdout.write('QUENDERIN_OFFICIAL_BOT_RUNTIME_FACTS_END\n');
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
