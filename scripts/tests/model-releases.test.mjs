import test from 'node:test';
import assert from 'node:assert/strict';
import { candidate, chooseQuant, discoverReleases } from '../../workers/model-releases.mjs';
import { releaseResponse } from '../../workers/site.mjs';
import { startingModel, visibleReleases } from '../../website/model-catalog.js';
import { readFile } from 'node:fs/promises';

const model = { id: 'unsloth/Qwen-new-GGUF', createdAt: '2026-09-01T00:00:00Z',
  tags: ['gguf', 'conversational', 'base_model:quantized:Qwen/Qwen-new', 'license:apache-2.0'],
  siblings: [{ rfilename: 'Qwen-new-Q4_K_M.gguf' }] };
const hash = 'a'.repeat(64), revision = 'b'.repeat(40);
const snapshot = { version: 1, checkedAt: '2026-01-01T00:00:00Z', models: [{
  name: 'Qwen-new', sourceUrl: 'https://huggingface.co/unsloth/Qwen-new-GGUF', status: 'discovered',
  createdAt: '2026-09-01T00:00:00Z', downloadBytes: 2400000000 }] };

test('discovery rejects untrusted authors, non-chat tasks and derived models', () => {
  assert.ok(candidate(model, 'unsloth'));
  assert.equal(candidate({ ...model, id: 'evil/Qwen-new-GGUF' }, 'unsloth'), null);
  assert.equal(candidate({ ...model, pipeline_tag: 'text-to-image' }, 'unsloth'), null);
  assert.equal(candidate({ ...model, tags: ['gguf', 'conversational', 'base_model:quantized:random/merge'] }, 'unsloth'), null);
  assert.equal(candidate({ ...model, tags: ['gguf', 'conversational', 'base_model:quantized:Qwen/../../evil'] }, 'unsloth'), null);
});

test('only standalone text weights are selected; no projector or split-file fragments', () => {
  assert.equal(chooseQuant([{ rfilename: 'mmproj-Q4_K_M.gguf' }]), null);
  assert.equal(chooseQuant([{ rfilename: 'Qwen-Q4_K_M-00001-of-00002.gguf' }]), null);
  assert.equal(chooseQuant([{ rfilename: 'imatrix-Q4_K_M.gguf' }]), null);
  assert.equal(chooseQuant(model.siblings).quantization, 'Q4_K_M');
});

test('Prism ternary releases are discoverable without enabling arbitrary downloads', () => {
  const prism = { ...model, id: 'prism-ml/Ternary-Bonsai-2-2B-gguf',
    tags: ['gguf', 'conversational', 'license:apache-2.0', 'base_model:quantized:Qwen/Qwen3.5-2B'],
    siblings: [{ rfilename: 'mmproj-Q8_0.gguf' },
      { rfilename: 'Ternary-Bonsai-2-2B-PTQ1_0.gguf' }] };
  assert.equal(candidate(prism, 'prism-ml').file.quantization, 'PTQ1_0');
  assert.equal(candidate(prism, 'prism-ml').base, prism.id);
  assert.equal(chooseQuant([{ rfilename: 'Muse-Spark-Open-Q2_K-00001-of-00022.gguf' }]), null);
});

test('Prism feed requests metadata only and retains pinned artifact identity', async () => {
  const prism = { ...model, id: 'prism-ml/Ternary-Bonsai-2-2B-gguf',
    tags: ['gguf', 'conversational', 'license:apache-2.0'],
    siblings: [{ rfilename: 'Ternary-Bonsai-2-2B-PTQ1_0.gguf' }] };
  const seen = [];
  const data = await discoverReleases(async url => {
    seen.push(url);
    if (url.includes('author=prism-ml')) return Response.json([prism]);
    if (url.includes('author=')) return Response.json([]);
    if (url.includes('?blobs=')) return Response.json({ sha: revision, siblings: [{
      rfilename: prism.siblings[0].rfilename, lfs: { sha256: hash, size: 429183456 } }] });
    return Response.json({ createdAt: '2026-10-15T00:00:00Z' });
  }, new Date('2026-10-16T00:00:00Z'));
  assert.equal(data.models[0].sha256, hash);
  assert.equal(data.models[0].revision, revision);
  assert.equal(data.models[0].downloadBytes, 429183456);
  assert.equal(data.models[0].name, 'Ternary-Bonsai-2-2B');
  assert.equal(data.models[0].createdAt, '2026-10-15T00:00:00Z');
  assert.ok(seen.every(url => url.startsWith('https://huggingface.co/api/models')));
  assert.ok(seen.length <= 47);
});

test('discovery uses original release date, deduplicates mirrors and requires file hash/size', async () => {
  const seen = [];
  const data = await discoverReleases(async (url, options) => {
    seen.push({ url, options });
    if (url.includes('author=unsloth')) return Response.json([model, model]);
    if (url.includes('author=')) return Response.json([]);
    if (url.includes('?blobs=')) return Response.json({ sha: revision, siblings: [{
      rfilename: model.siblings[0].rfilename, size: 2400000000, lfs: { sha256: hash } }] });
    return Response.json({ createdAt: '2026-07-01T00:00:00Z' });
  });
  assert.equal(data.models.length, 1);
  assert.equal(data.models[0].createdAt, '2026-07-01T00:00:00Z');
  assert.equal(data.models[0].ggufPublishedAt, model.createdAt);
  assert.equal(data.models[0].sha256, hash);
  assert.ok(seen.every(s => !s.options.headers));
  assert.ok(seen.every(s => !s.url.includes('/resolve/')));
});

test('fresh cache bypasses upstream, strips user query and supports HEAD', async () => {
  let key;
  const cache = { match: async r => { key = r.url; return Response.json({ ...snapshot, checkedAt: new Date().toISOString() }); } };
  const response = await releaseResponse(new Request('https://quenderin.org/api/model-releases?url=evil', { method: 'HEAD' }), {}, {}, cache,
    () => { throw new Error('must not fetch'); });
  assert.equal(key, 'https://quenderin.org/api/model-releases');
  assert.equal(await response.text(), '');
  assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
});

test('upstream outage keeps the dated cached snapshot and never calls it live', async () => {
  const response = await releaseResponse(new Request('https://quenderin.org/api/model-releases'), {}, {},
    { match: async () => Response.json(snapshot) }, async () => { throw new Error('offline'); });
  const data = await response.json();
  assert.equal(data.freshness, 'saved');
  assert.equal(data.checkedAt, snapshot.checkedAt);
  assert.equal(data.models.length, 1);
});

test('cold upstream outage serves the committed offline snapshot', async () => {
  const response = await releaseResponse(new Request('https://quenderin.org/api/model-releases'),
    { ASSETS: { fetch: async r => { assert.equal(new URL(r.url).pathname, '/data/model-releases.json'); return Response.json(snapshot); } } }, {},
    { match: async () => undefined }, async () => { throw new Error('offline'); });
  assert.equal((await response.json()).freshness, 'saved');
});

test('API is read-only', async () => {
  const response = await releaseResponse(new Request('https://quenderin.org/api/model-releases', { method: 'POST' }), {}, {}, {});
  assert.equal(response.status, 405);
});

test('missing integrity metadata fails closed instead of publishing a download', async () => {
  await assert.rejects(discoverReleases(async url => {
    if (url.includes('author=unsloth')) return Response.json([model]);
    if (url.includes('author=')) return Response.json([]);
    if (url.includes('?blobs=')) return Response.json({ sha: revision, siblings: [{
      rfilename: model.siblings[0].rfilename, size: 2400000000 }] });
    return Response.json({ createdAt: '2026-07-01T00:00:00Z' });
  }), /No verified file metadata/);
});

test('display rejects bad links and applies a download budget without claiming RAM fit', () => {
  assert.equal(visibleReleases(snapshot, 3000000000).length, 1);
  assert.equal(visibleReleases(snapshot, 1000000000).length, 0);
  assert.equal(visibleReleases({ models: [{ ...snapshot.models[0], sourceUrl: 'javascript:evil' }] }).length, 0);
});

test('calculator applies app memory headroom, including a blocked RAM-band pick', async () => {
  const data = JSON.parse(await readFile(new URL('../../website/data/model-catalog.json', import.meta.url)));
  assert.equal(startingModel(data, 8).model.id, 'qwen3-4b');
  assert.equal(startingModel(data, 16).model.id, 'gemma4-12b');
  assert.equal(startingModel(data, 1).model.id, 'llama32-1b-q2');
  assert.equal(startingModel(data, 0), null);
  for (const ram of [1, 2, 3, 4, 8, 16, 32]) assert.ok(startingModel(data, ram).requiredGb <= ram * data.recommendation.hardBudget);
});

test('RAM-only calculator never recommends an experimental custom runtime', () => {
  const catalog = {
    models: [
      { id: 'bonsai2-27b', quantization: 'PTQ1_0', ramGb: 7, paramsBillions: 27.36 },
      { id: 'small', quantization: 'Q4_K_M', ramGb: 2, paramsBillions: 3 },
    ],
    recommendation: { ramBands: [], defaultId: 'bonsai2-27b', hardBudget: .85,
      smallOverhead: 1.15, largeOverhead: 1.3 },
  };
  assert.equal(startingModel(catalog, 16).model.id, 'small');
  assert.equal(startingModel({ ...catalog, models: catalog.models.slice(0, 1) }, 32), null);
});
