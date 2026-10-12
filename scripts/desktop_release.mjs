import {spawnSync} from 'node:child_process';
import {closeSync, openSync, readSync, statSync} from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

export const INSTALLERS = {
  windows: ['Quenderin-Setup-x64.exe', 'Quenderin-Portable-x64.exe'],
  linux: ['Quenderin-x64.AppImage', 'Quenderin-x64.deb'],
};
const MAX_ASSET_BYTES = 2 ** 31;

export function fileDigest(file) {
  const hash = createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const descriptor = openSync(file, 'r');
  try {
    for (let length; (length = readSync(descriptor, buffer, 0, buffer.length, null)) > 0;)
      hash.update(buffer.subarray(0, length));
  } finally {
    closeSync(descriptor);
  }
  return 'sha256:' + hash.digest('hex');
}

export function execute(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8', timeout: options.timeout ?? 120_000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure)
    throw new Error(command + ' failed: ' + (result.stderr || result.stdout));
  return result;
}

export function resolveTagCommit(output, tag) {
  const refs = new Map(output.trim().split('\n').filter(Boolean).map(line => {
    const [commit, ref] = line.trim().split(/\s+/);
    return [ref, commit];
  }));
  return refs.get('refs/tags/' + tag + '^{}') ?? refs.get('refs/tags/' + tag);
}

export function desktopRelease({repository, sha, tag, run = execute, stat = statSync, digest = fileDigest}) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '') || !/^[a-f0-9]{40}$/.test(sha ?? '') || !tag?.startsWith('v'))
    throw new Error('Release repository, full commit SHA, and version tag are required');
  run('git', ['check-ref-format', 'refs/tags/' + tag]);
  const [owner, name] = repository.split('/');

  function verifyTag(allowMissing = false) {
    const result = run('git', ['ls-remote', 'https://github.com/' + repository + '.git',
      'refs/tags/' + tag, 'refs/tags/' + tag + '^{}']);
    const commit = resolveTagCommit(result.stdout, tag);
    if (commit == null && allowMissing && result.stdout.trim() === '') return false;
    if (commit !== sha) throw new Error('Release tag ' + tag + ' resolves to ' + commit + ', expected ' + sha);
    return true;
  }

  function release() {
    // REST tag lookup excludes drafts. Resolve the exact tag through GraphQL, as gh does.
    const result = run('gh', ['api', 'graphql', '-f',
      'query=query($owner:String!,$name:String!,$tag:String!){repository(owner:$owner,name:$name){release(tagName:$tag){databaseId}}}',
      '-f', 'owner=' + owner, '-f', 'name=' + name, '-f', 'tag=' + tag]);
    const lookup = JSON.parse(result.stdout);
    if (lookup.errors?.length || !lookup.data?.repository || !Object.hasOwn(lookup.data.repository, 'release'))
      throw new Error('Could not verify the GitHub release');
    const found = lookup.data.repository.release;
    if (found === null) return null;
    if (!Number.isSafeInteger(found.databaseId) || found.databaseId <= 0) throw new Error('Invalid release ID');
    const value = JSON.parse(run('gh', ['api', 'repos/' + repository + '/releases/' + found.databaseId]).stdout);
    if (value.id !== found.databaseId || value.tag_name !== tag || typeof value.draft !== 'boolean' || !Array.isArray(value.assets))
      throw new Error('Invalid release metadata');
    return value;
  }

  function draft() {
    verifyTag();
    const value = release();
    if (!value?.draft) throw new Error('The exact-source release must exist as a draft');
    return value;
  }

  function prepare() {
    const exists = verifyTag(true);
    const value = release();
    if (value) {
      if (!exists || !value.draft) throw new Error('Existing releases require the exact source tag and draft state');
      draft();
      return;
    }
    if (!exists) {
      // Draft creation may defer its tag, so create the exact ref before any asset upload.
      run('gh', ['api', '--method', 'POST', 'repos/' + repository + '/git/refs',
        '-f', 'ref=refs/tags/' + tag, '-f', 'sha=' + sha]);
    }
    verifyTag();
    run('gh', ['release', 'create', tag, '--draft', '--verify-tag', '--target', sha,
      '--title', 'Quenderin ' + tag, '--generate-notes', '--repo', repository]);
    draft();
  }

  function upload(platform) {
    const names = INSTALLERS[platform];
    if (!names) throw new Error('Unknown installer platform');
    const value = draft();
    const local = names.map(name => {
      const filePath = path.join('release', name);
      const file = stat(filePath);
      if (!file.isFile() || file.size <= 0 || file.size >= MAX_ASSET_BYTES)
        throw new Error('Installer must be a nonempty file below 2 GiB: ' + filePath);
      return {name, filePath, size: file.size, digest: digest(filePath)};
    });
    function missingAssets(assets, requireAll = false) {
      return local.filter(file => {
        const matches = assets.filter(asset => asset.name === file.name);
        if (matches.length === 0 && !requireAll) return true;
        const asset = matches[0];
        if (matches.length !== 1 || asset.state !== 'uploaded' || asset.size !== file.size || asset.digest !== file.digest)
          throw new Error('Existing release asset must match the complete local installer: ' + file.name);
        return false;
      });
    }
    const missing = missingAssets(value.assets);
    // Never clobber assets, including a duplicate created concurrently after the preflight.
    if (missing.length)
      run('gh', ['release', 'upload', tag, '--repo', repository, ...missing.map(file => file.filePath)], {timeout: 20 * 60_000});
    missingAssets(draft().assets, true);
  }

  function publish() {
    const value = draft();
    const expected = Object.values(INSTALLERS).flat();
    if (value.assets.length !== expected.length || expected.some(name =>
      value.assets.filter(asset => asset.name === name && asset.state === 'uploaded' &&
        Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size < MAX_ASSET_BYTES &&
        /^sha256:[a-f0-9]{64}$/.test(asset.digest ?? '')).length !== 1))
      throw new Error('All four completed desktop installers are required before publication');
    verifyTag();
    run('gh', ['release', 'edit', tag, '--draft=false', '--repo', repository]);
  }
  return {prepare, upload, publish};
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const command = process.argv[2];
    if (!['prepare', 'upload', 'publish'].includes(command)) throw new Error('Use prepare, upload <platform>, or publish');
    const client = desktopRelease({
      repository: process.env.GITHUB_REPOSITORY, sha: process.env.GITHUB_SHA, tag: process.env.RELEASE_TAG,
    });
    client[command](process.argv[3]);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
