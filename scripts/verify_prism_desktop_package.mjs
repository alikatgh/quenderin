#!/usr/bin/env node
// Probe the addon through Electron's ASAR-aware loader in the packaged app.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

assert.ok(process.argv[2], 'Pass the packaged resources directory');
const resources = path.resolve(process.argv[2]);
const unpacked = path.join(resources, 'app.asar.unpacked/node_modules/node-llama-cpp');
assert.ok(existsSync(path.join(resources, 'app.asar')), 'Packaged ASAR is missing');
assert.ok(existsSync(path.join(unpacked, 'llama/localBuilds')), 'Custom addon is not unpacked');
assert.equal(existsSync(path.join(unpacked, 'llama/llama.cpp')), false,
    'Build-only source checkout must be absent from the installer');
for (const name of ['lastBuild.json', 'llama.cpp.info.json', 'quenderin-prism-node-runtime.json']) {
    assert.ok(existsSync(path.join(unpacked, 'llama', name)), `Missing packaged ${name}`);
}
const check = fileURLToPath(new URL('./verify_prism_node_runtime.mjs', import.meta.url));
const names = process.platform === 'win32' ? ['Quenderin.exe'] : ['quenderin', 'quenderin-poc'];
const executables = names.map(name => path.join(resources, '..', name)).filter(existsSync);
assert.equal(executables.length, 1, 'Expected one packaged Quenderin executable');
const result = spawnSync(executables[0], [check, path.join(resources, 'app.asar/node_modules/node-llama-cpp')], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
    stdio: 'inherit',
    timeout: 60_000,
});
if (result.error) throw result.error;
assert.equal(result.status, 0, `Packaged native addon failed (${result.signal ?? result.status})`);
