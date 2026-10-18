const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { beforePack, afterPack, target } = require('../electron_diffusion_pack.cjs');

function context(os = 'linux', arch = 1) {
  return { electronPlatformName: os, arch, appOutDir: '/fixture/release',
    packager: { projectDir: '/fixture', appInfo: { productFilename: 'Quenderin' } } };
}

test('packaging requires both real Prism checks before the sealed image check', async () => {
  const calls = [];
  await beforePack(context(), (program, args, cwd) => calls.push({ program, args, cwd }));
  assert.equal(calls.length, 3);
  assert(calls[0].args.includes('scripts/prepare_prism_node_runtime.py'));
  assert(calls[0].args.includes('verify'));
  assert(calls[1].args.includes('scripts/verify_prism_node_runtime.mjs'));
  assert.deepEqual(calls[2].args.slice(-4), ['--platform', 'linux', '--arch', 'x64']);
  assert(calls[2].args.includes(path.join('/fixture', 'build', 'diffusion', 'linux-x64')));
  assert(calls.every(call => call.cwd === '/fixture'));
  assert(!calls.some(call => call.args.includes('fetch') || call.args.includes('build')));
});

for (const failedGate of [0, 1, 2]) {
  test(`native gate ${failedGate} fails closed before packaging`, async () => {
    let calls = 0;
    await assert.rejects(beforePack(context(), () => { if (calls++ === failedGate) throw new Error('fixture gate rejected'); }), /fixture gate rejected/);
    assert.equal(calls, failedGate + 1);
  });
}

test('resource copy is checked before signing on Windows, Linux and macOS', async () => {
  for (const [os, expected] of [['win32', path.join('/fixture/release', 'resources', 'diffusion')], ['linux', path.join('/fixture/release', 'resources', 'diffusion')], ['darwin', path.join('/fixture/release', 'Quenderin.app', 'Contents', 'Resources', 'diffusion')]]) {
    let args;
    await afterPack(context(os), (_program, values) => { args = values; });
    assert.equal(args[args.indexOf('--directory') + 1], expected);
    assert(!args.includes('--packaged'), 'pre-sign copy must retain exact hashes');
  }
});

test('unsupported and universal target stages are rejected before commands run', async () => {
  for (const value of [context('freebsd'), context('linux', 0), context('darwin', 4), context('linux', 99)]) {
    let ran = false;
    await assert.rejects(beforePack(value, () => { ran = true; }), /Unsupported/);
    assert.equal(ran, false);
  }
  assert.deepEqual(target(context('win32', 3)), { os: 'win', arch: 'arm64' });
});

test('builder stages native runtime outside ASAR with architecture-specific gates', () => {
  const config = readFileSync(path.join(__dirname, '../../electron-builder.yaml'), 'utf8');
  assert.match(config, /^beforePack: scripts\/electron_diffusion_pack.cjs$/m);
  assert.match(config, /^afterPack: scripts\/electron_diffusion_after_pack.cjs$/m);
  assert.match(config, /from: build\/diffusion\/\$\{os\}-\$\{arch\}\s+to: diffusion/);
  for (const workflow of ['ci.yml', 'desktop-release.yml']) {
    const yaml = readFileSync(path.join(__dirname, '../../.github/workflows', workflow), 'utf8');
    assert.match(yaml, /build_desktop_diffusion.py build --work/);
    assert.match(yaml, /build_desktop_diffusion.py joint-load/);
    assert.match(yaml, /resources\/diffusion --packaged/);
    assert.match(yaml, /verify_prism_desktop_package.mjs/);
  }
});
