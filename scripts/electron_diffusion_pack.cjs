/* Fail closed: electron-builder never downloads or substitutes native runtimes. */
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const targets = { win32: 'win', linux: 'linux', darwin: 'mac' };
// electron-builder's builder-util Arch enum (universal needs two independently
// built payloads and is deliberately not accepted as a single host build).
const arches = { 0: 'ia32', 1: 'x64', 2: 'armv7l', 3: 'arm64', 4: 'universal' };

function command(program, args, cwd) {
  const result = spawnSync(program, args, {
    cwd, encoding: 'utf8', timeout: 120_000, maxBuffer: 1024 * 1024,
    windowsHide: true, shell: false,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`Native packaging gate failed (${path.basename(args[0] ?? program)}): ${result.error?.message ?? result.stderr ?? 'nonzero exit'}`);
  }
}

function target(context) {
  const os = targets[context.electronPlatformName];
  const arch = arches[context.arch];
  if (!os || !['x64', 'arm64', 'armv7l'].includes(arch)) throw new Error('Unsupported image runtime packaging target');
  return { os, arch };
}

async function beforePack(context, run = command) {
  const root = context.packager.projectDir;
  const { os, arch } = target(context);
  const python = process.platform === 'win32' ? 'python' : 'python3';
  // Prism remains mandatory even when a prebuilt node addon happens to exist.
  run(python, ['scripts/prepare_prism_node_runtime.py', 'verify', '--package-dir', 'node_modules/node-llama-cpp'], root);
  run(process.execPath, ['scripts/verify_prism_node_runtime.mjs'], root);
  run(python, ['scripts/build_desktop_diffusion.py', 'verify', '--directory', path.join(root, 'build', 'diffusion', `${os}-${arch}`), '--platform', os, '--arch', arch], root);
  run(python, ['scripts/build_vision_runtime.py', 'verify', '--directory', path.join(root, 'build', 'vision', `${os}-${arch}`)], root);
}

async function afterPack(context, run = command) {
  const root = context.packager.projectDir;
  const { os, arch } = target(context);
  const resources = os === 'mac'
    ? path.join(context.appOutDir, context.packager.appInfo.productFilename + '.app', 'Contents', 'Resources')
    : path.join(context.appOutDir, 'resources');
  run(process.platform === 'win32' ? 'python' : 'python3', [
    path.join(root, 'scripts', 'build_desktop_diffusion.py'), 'verify', '--directory', path.join(resources, 'diffusion'), '--platform', os, '--arch', arch,
  ], root);
  run(process.platform === 'win32' ? 'python' : 'python3', [
    path.join(root, 'scripts', 'build_vision_runtime.py'), 'verify', '--directory', path.join(resources, 'vision'),
  ], root);
}

module.exports = beforePack;
module.exports.beforePack = beforePack;
module.exports.afterPack = afterPack;
module.exports.target = target;
