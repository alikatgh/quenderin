import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {desktopRelease, INSTALLERS, resolveTagCommit} from '../desktop_release.mjs';

const sha = 'a'.repeat(40);
const other = 'b'.repeat(40);
const tag = 'v0.2.0';
const assetDigest = 'sha256:' + 'c'.repeat(64);
const completeAssets = () => Object.values(INSTALLERS).flat().map(name => ({name, size: 100, state: 'uploaded', digest: assetDigest}));
const response = value => ({status: 0, stdout: JSON.stringify(value), stderr: ''});

function fixture(options = {}) {
  const state = {commit: null, release: null, ...options};
  const calls = [];
  function run(command, args) {
    calls.push({command, args});
    if (command === 'git') {
      if (args[0] === 'check-ref-format') return {status: 0, stdout: ''};
      assert.equal(args[1], 'https://github.com/fixture/repo.git');
      if (state.gitFailure) throw new Error('Git transport unavailable');
      const ref = 'refs/tags/' + tag;
      return {status: 0, stdout: state.commit == null ? '' : state.annotated ?
        other + '\t' + ref + '\n' + state.commit + '\t' + ref + '^{}\n' : state.commit + '\t' + ref + '\n'};
    }
    if (args[0] === 'api' && !args.includes('--method')) {
      if (state.apiTransportFailure) throw new Error('GitHub transport unavailable');
      if (state.apiStatus && state.apiStatus !== 200) throw new Error('GitHub API failed: ' + state.apiStatus);
      if (args[1] === 'graphql') {
        assert(args.includes('owner=fixture') && args.includes('name=repo') && args.includes('tag=' + tag));
        if (state.graphqlErrors) return response({errors: [{message: 'Denied'}]});
        if (state.missingRepository) return response({data: {repository: null}});
        if (state.missingReleaseField) return response({data: {repository: {}}});
        return response({data: {repository: {release: state.release ? {databaseId: 123} : null}}});
      }
      assert.equal(args[1], 'repos/fixture/repo/releases/123');
      return response({...state.release, id: state.wrongRestId ? 999 : 123});
    }
    if (args[0] !== 'api') assert.equal(args[args.indexOf('--repo') + 1], 'fixture/repo');
    if (args[0] === 'api') {
      assert(args.includes('sha=' + sha));
      assert(args.includes('ref=refs/tags/' + tag));
      state.commit = state.wrongCreatedTag ? other : sha;
    } else if (args[1] === 'create') {
      assert(args.includes('--draft'));
      assert(args.includes('--verify-tag'));
      assert.equal(args[args.indexOf('--target') + 1], sha);
      state.release = {tag_name: tag, draft: true, assets: []};
    } else if (args[1] === 'upload') {
      assert(!args.includes('--clobber'));
      const uploaded = args.filter(file => file.startsWith('release/')).map(file => ({
        name: file.split('/').at(-1), size: 100, state: 'uploaded', digest: assetDigest,
      }));
      if (state.partialUpload) state.release.assets.push(uploaded[0]);
      if (state.uploadFailure) throw new Error('Upload interrupted');
      state.release.assets.push(...uploaded);
      if (state.moveTagAfterUpload) state.commit = other;
    } else if (args[1] === 'edit') {
      assert(args.includes('--draft=false'));
      state.release.draft = false;
    } else throw new Error('Unexpected command');
    return {status: 0, stdout: '', stderr: ''};
  }
  const client = desktopRelease({
    repository: 'fixture/repo', sha, tag, run,
    stat: () => ({isFile: () => true, size: state.fileSize ?? 100}),
    digest: () => assetDigest,
  });
  const mutations = () => calls.filter(x => x.command === 'gh' &&
    (x.args.includes('--method') || ['create', 'upload', 'edit'].includes(x.args[1])));
  return {state, calls, client, mutations};
}

test('new release creates the exact tag and stays draft until all installers pass', () => {
  const f = fixture();
  f.client.prepare();
  assert.equal(f.state.commit, sha);
  assert.equal(f.state.release.draft, true);
  f.client.upload('windows');
  assert.throws(() => f.client.publish(), /four completed/);
  assert.equal(f.state.release.draft, true);
  f.client.upload('linux');
  f.client.publish();
  assert.equal(f.state.release.draft, false);
  assert.equal(f.mutations().filter(x => x.args[1] === 'edit').length, 1);
});

test('lightweight and annotated tags resolve to their commit', () => {
  assert.equal(resolveTagCommit(sha + '\trefs/tags/' + tag, tag), sha);
  assert.equal(resolveTagCommit(other + '\trefs/tags/' + tag + '\n' + sha + '\trefs/tags/' + tag + '^{}', tag), sha);
  for (const annotated of [false, true]) {
    const f = fixture({commit: sha, annotated, release: {tag_name: tag, draft: true, assets: []}});
    f.client.prepare();
    assert.equal(f.mutations().length, 0);
  }
});

for (const annotated of [false, true]) {
  test('mismatched ' + (annotated ? 'annotated' : 'lightweight') + ' tag prevents all release writes', () => {
    const f = fixture({commit: other, annotated});
    assert.throws(() => f.client.prepare(), /expected/);
    assert.equal(f.mutations().length, 0);
    assert(!f.calls.some(x => x.command === 'gh'));
  });
}

for (const options of [{gitFailure: true}, {apiTransportFailure: true}, {apiStatus: 403}, {apiStatus: 500}]) {
  test('failed remote verification prevents writes: ' + JSON.stringify(options), () => {
    const f = fixture(options);
    assert.throws(() => f.client.prepare());
    assert.equal(f.mutations().length, 0);
  });
}

for (const options of [{graphqlErrors: true}, {missingRepository: true}, {missingReleaseField: true}]) {
  test('only an explicit GraphQL release=null permits creation: ' + JSON.stringify(options), () => {
    const f = fixture(options);
    assert.throws(() => f.client.prepare(), /verify/);
    assert.equal(f.mutations().length, 0);
  });
}

test('draft lookup resolves GraphQL databaseId and fetches the REST release by ID', () => {
  const f = fixture({commit: sha, release: {tag_name: tag, draft: true, assets: []}});
  f.client.prepare();
  assert(f.calls.some(x => x.args[0] === 'api' && x.args[1] === 'graphql'));
  assert(f.calls.some(x => x.args[1] === 'repos/fixture/repo/releases/123'));
  assert(!f.calls.some(x => x.args.some(arg => arg.includes('/releases/tags/'))));
});

test('the REST response must match the GraphQL release ID', () => {
  const f = fixture({commit: sha, wrongRestId: true, release: {tag_name: tag, draft: true, assets: []}});
  assert.throws(() => f.client.prepare(), /Invalid release metadata/);
  assert.equal(f.mutations().length, 0);
});

test('a tag created at a different commit prevents release creation and uploads', () => {
  const f = fixture({wrongCreatedTag: true});
  assert.throws(() => f.client.prepare(), /expected/);
  assert(!f.mutations().some(x => ['create', 'upload', 'edit'].includes(x.args[1])));
});

test('an existing public release is preserved', () => {
  const f = fixture({commit: sha, release: {tag_name: tag, draft: false, assets: completeAssets()}});
  assert.throws(() => f.client.prepare(), /draft/);
  assert.throws(() => f.client.upload('linux'), /draft/);
  assert.throws(() => f.client.publish(), /draft/);
  assert.equal(f.mutations().length, 0);
});

test('an existing release without its tag is rejected without recreating the tag', () => {
  const f = fixture({release: {tag_name: tag, draft: true, assets: []}});
  assert.throws(() => f.client.prepare(), /exact source/);
  assert.equal(f.mutations().length, 0);
});

test('upload failure leaves the release draft and never publishes', () => {
  const f = fixture({uploadFailure: true});
  f.client.prepare();
  assert.throws(() => f.client.upload('linux'), /interrupted/);
  assert.equal(f.state.release.draft, true);
  assert.throws(() => f.client.publish(), /four completed/);
  assert(!f.mutations().some(x => x.args[1] === 'edit'));
});

test('a changed existing installer is rejected before any upload and remains untouched', () => {
  const asset = {name: INSTALLERS.linux[1], size: 77, state: 'uploaded'};
  const f = fixture({commit: sha, release: {tag_name: tag, draft: true, assets: [asset]}});
  assert.throws(() => f.client.upload('linux'), /must match/);
  assert.equal(f.mutations().length, 0);
  assert.deepEqual(f.state.release.assets, [asset]);
});

test('partial upload retries retain the identical file and upload only the missing file', () => {
  const f = fixture({uploadFailure: true, partialUpload: true});
  f.client.prepare();
  assert.throws(() => f.client.upload('linux'), /interrupted/);
  assert.equal(f.state.release.assets.length, 1);
  const retained = structuredClone(f.state.release.assets[0]);
  f.state.uploadFailure = false;
  f.state.partialUpload = false;
  f.client.upload('linux');
  const uploads = f.mutations().filter(x => x.args[1] === 'upload');
  assert.equal(uploads.length, 2);
  assert.deepEqual(uploads[1].args.filter(arg => arg.startsWith('release/')), ['release/' + INSTALLERS.linux[1]]);
  assert.deepEqual(f.state.release.assets[0], retained);
  assert.equal(f.state.release.draft, true);
  f.client.upload('windows');
  f.client.publish();
  assert.equal(f.state.release.draft, false);
});

test('identical completed assets need no duplicate upload', () => {
  const f = fixture({commit: sha, release: {tag_name: tag, draft: true, assets: completeAssets()}});
  f.client.upload('linux');
  assert.equal(f.mutations().length, 0);
});

for (const change of [{digest: null}, {digest: undefined}, {digest: 'sha256:' + 'd'.repeat(64)}, {state: 'new'}, {size: 99}]) {
  test('unverified existing asset cannot resume: ' + JSON.stringify(change), () => {
    const asset = {...completeAssets().find(x => x.name === INSTALLERS.linux[0]), ...change};
    const f = fixture({commit: sha, release: {tag_name: tag, draft: true, assets: [asset]}});
    assert.throws(() => f.client.upload('linux'), /must match/);
    assert.equal(f.mutations().length, 0);
    assert.deepEqual(f.state.release.assets, [asset]);
  });
}

for (const fileSize of [0, 2 ** 31]) {
  test('invalid installer size prevents upload: ' + fileSize, () => {
    const f = fixture({commit: sha, fileSize, release: {tag_name: tag, draft: true, assets: []}});
    assert.throws(() => f.client.upload('linux'), /below 2 GiB/);
    assert.equal(f.mutations().length, 0);
  });
}

test('tag changes after packaging block upload or publication', () => {
  const f = fixture({commit: other, release: {tag_name: tag, draft: true, assets: completeAssets()}});
  assert.throws(() => f.client.upload('linux'), /expected/);
  assert.throws(() => f.client.publish(), /expected/);
  assert.equal(f.mutations().length, 0);
});

test('missing, incomplete, duplicate, and extra assets cannot publish', () => {
  const invalid = [
    completeAssets().slice(1),
    completeAssets().map((asset, i) => i ? asset : {...asset, state: 'new'}),
    completeAssets().map((asset, i) => i ? asset : {...asset, size: 0}),
    completeAssets().map((asset, i) => i ? asset : {...asset, digest: null}),
    [...completeAssets(), completeAssets()[0]],
    [...completeAssets(), {name: 'unrelated', size: 1, state: 'uploaded'}],
  ];
  for (const assets of invalid) {
    const f = fixture({commit: sha, release: {tag_name: tag, draft: true, assets}});
    assert.throws(() => f.client.publish(), /four completed/);
    assert.equal(f.mutations().length, 0);
  }
});

test('desktop release uses direct draft uploads without Actions artifact storage', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/desktop-release.yml', import.meta.url), 'utf8');
  assert(!/actions\/(?:upload|download)-artifact/.test(workflow));
  assert.match(workflow, /needs: \[prepare, build\]/);
  assert.match(workflow, /node scripts\/desktop_release\.mjs publish/);
});
