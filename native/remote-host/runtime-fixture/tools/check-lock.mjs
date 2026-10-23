import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export const root = fileURLToPath(new URL('../', import.meta.url));
export function checkLock(reviewedSHA256) {
  const raw = readFileSync(resolve(root, 'package-lock.json'));
  const sha256 = createHash('sha256').update(raw).digest('hex');
  const lock = JSON.parse(raw);
  const manifest = JSON.parse(readFileSync(resolve(root, 'package.json')));
  const provenance = JSON.parse(readFileSync(resolve(root, 'dependency-provenance.json')));
  const registry = JSON.parse(readFileSync(resolve(root, 'registry-metadata.json')));
  if (lock.lockfileVersion !== 3 || sha256 !== provenance.lockSHA256) throw new Error('Unrecorded lockfile');
  if (registry.lockSHA256 !== sha256) throw new Error('Stale registry identity verification');
  const sorted = value => JSON.stringify(Object.entries(value).sort(([left], [right]) => left.localeCompare(right)));
  if (sorted(lock.packages[''].dependencies) !== sorted(manifest.dependencies)) throw new Error('Manifest/lock differ');
  const entries = Object.entries(lock.packages).filter(([path]) => path);
  if (entries.length !== provenance.packages.length || entries.length > 350) throw new Error('Unexpected dependency closure');
  for (const [path, value] of entries) {
    const name = path.split('node_modules/').at(-1);
    const recorded = provenance.packages.find(item => item.path === path);
    const published = registry.packages.find(item => item.name === name && item.version === value.version);
    if (!recorded || recorded.version !== value.version || recorded.integrity !== value.integrity || recorded.resolved !== value.resolved
        || recorded.license !== value.license || recorded.installScript !== Boolean(value.hasInstallScript)) throw new Error(`Unrecorded dependency: ${name}`);
    if (!published || published.tarball !== value.resolved || published.integrity !== value.integrity) throw new Error(`Registry identity not verified: ${name}`);
    if (!/^https:\/\/registry\.npmjs\.org\//.test(value.resolved ?? '') || !/^sha512-[A-Za-z0-9+/]+=*$/.test(value.integrity ?? '')) throw new Error(`Unverified package origin: ${name}`);
    if (name.startsWith('@deepseek-ai/dsh-') && value.version !== '0.2.1-rc.1') throw new Error(`Mixed Harness generation: ${name}`);
    if (name.startsWith('@deepseek-ai/dsh-') && published.repository?.url !== 'git+https://github.com/deepseek-ai/deepseek-harness.git') throw new Error(`Unexpected Harness source repository: ${name}`);
    if (name === '@deepseek-ai/cordis' && value.version !== '4.0.5') throw new Error('Mixed Cordis generation');
  }
  if (reviewedSHA256 !== undefined && (!/^[a-f0-9]{64}$/.test(reviewedSHA256) || reviewedSHA256 !== sha256)) throw new Error('Reviewed full-lock SHA256 required');
  return { sha256, packages: entries.length, installed: existsSync(resolve(root, 'node_modules')) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(checkLock(process.argv[2]), null, 2));
}
