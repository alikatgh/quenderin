// No package code is imported before the reviewed full lock is verified.
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkLock, root } from './check-lock.mjs';
import { boundedProcess, processEnvironment } from './bounded-process.mjs';

export function createNpmConfigs(scratch) {
  const paths = {
    npm_config_userconfig: join(scratch, 'npm-user-empty.conf'),
    npm_config_globalconfig: join(scratch, 'npm-global-empty.conf'),
  };
  for (const file of Object.values(paths)) writeFileSync(file, '', { flag: 'wx', mode: 0o600 });
  return paths;
}

async function bootstrap() {
  const reviewed = process.argv[2];
  if (!reviewed) throw new Error('STOP: supply the independently reviewed full-lock SHA256 before installation');
  const facts = checkLock(reviewed);
  if (process.env.GITHUB_ACTIONS !== 'true' || process.platform !== 'linux' || !/^22\./.test(process.versions.node)) throw new Error('Hosted Linux Node 22 runner required; local installation is disabled');
  const scratch = mkdtempSync('/tmp/quenderin-runtime-install-');
  try {
    const configs = createNpmConfigs(scratch);
    const result = await boundedProcess('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], {
      cwd: root, timeoutMs: 179_000,
      env: { ...processEnvironment(), TMPDIR: scratch, ...configs,
        npm_config_ignore_scripts: 'true', npm_config_audit: 'false', npm_config_fund: 'false',
        npm_config_cache: join(scratch, 'cache'), npm_config_prefix: join(scratch, 'prefix'),
        npm_config_registry: 'https://registry.npmjs.org',
      },
    });
    process.stdout.write(result.stdout.subarray(0, 32_768));
    process.stderr.write(result.stderr.subarray(0, 32_768));
    if (result.error || result.code !== 0 || result.timedOut || result.outputExceeded) throw new Error('Bounded lockfile installation failed');
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ fixtureBootstrap: 'installed-without-lifecycle-scripts', ...facts }));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await bootstrap();
}
