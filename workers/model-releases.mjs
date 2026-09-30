// Public model metadata only. No request headers, visitor data, prompts or credentials
// are forwarded to Hugging Face. Discovery is separate from the trusted app catalog.
export const PUBLISHERS = ['unsloth', 'Qwen', 'bartowski', 'ggml-org'];
const ALLOWED_TASKS = new Set(['text-generation', 'image-text-to-text']);
const MODEL_AUTHORS = new Set(['Qwen', 'google', 'meta-llama', 'microsoft', 'mistralai',
  'deepseek-ai', 'LiquidAI', 'openbmb', 'nvidia', 'NVIDIA', 'openai']);
const EXCLUDED = /(?:diffusion|embedding|rerank|base(?:[-_.]|$)|image-edit|image-generation|livet[r]?anslate|tts|speech|audio|mtp(?:[-_.]|$))/i;

export function chooseQuant(siblings = []) {
  const files = siblings.filter(f => typeof f.rfilename === 'string'
    && /\.gguf$/i.test(f.rfilename)
    && !/(?:mmproj|imatrix|mtp|000\d+-of-)/i.test(f.rfilename));
  for (const quant of ['Q4_K_M', 'UD-Q4_K_XL', 'UD-Q4_K_M', 'Q4_0']) {
    const file = files.find(f => f.rfilename.toUpperCase().endsWith('-' + quant + '.GGUF')
      || f.rfilename.toUpperCase().endsWith('.' + quant + '.GGUF'));
    if (file) return { ...file, quantization: quant };
  }
  return null;
}

export function candidate(model, publisher) {
  const id = model.id;
  if (typeof id !== 'string' || !id.startsWith(publisher + '/')
      || !/^[\w.-]+\/[\w.-]+$/.test(id) || EXCLUDED.test(id)) return null;
  const tags = Array.isArray(model.tags) ? model.tags.filter(t => typeof t === 'string') : [];
  if (!tags.includes('gguf') || (model.pipeline_tag && !ALLOWED_TASKS.has(model.pipeline_tag))) return null;
  if (!model.pipeline_tag && !tags.includes('conversational')) return null;
  const created = Date.parse(model.createdAt);
  if (!Number.isFinite(created) || created > Date.now() + 86400000) return null;
  const file = chooseQuant(model.siblings);
  if (!file) return null;
  const base = tags.find(t => typeof t === 'string' && t.startsWith('base_model:quantized:'))?.slice(21)
    || tags.find(t => typeof t === 'string' && /^base_model:[^:]+\//.test(t))?.slice(11) || id;
  if (!/^[\w.-]+\/[\w.-]+$/.test(base) || !MODEL_AUTHORS.has(base.split('/')[0]) || EXCLUDED.test(base)) return null;
  return { id, base, createdAt: model.createdAt, file, tags };
}

export async function discoverReleases(fetcher = fetch, now = new Date()) {
  const sources = [...PUBLISHERS.map(author => ({ author })),
    { author: 'unsloth', search: '2B' }, { author: 'unsloth', search: '4B' }];
  const lists = await Promise.allSettled(sources.map(async ({ author: publisher, search }) => {
    const url = new URL('https://huggingface.co/api/models');
    url.search = new URLSearchParams({ author: publisher, filter: 'gguf', sort: 'createdAt',
      direction: '-1', limit: search ? '12' : '80', full: 'true', ...(search ? { search } : {}) }).toString();
    const res = await fetcher(url.toString(), { signal: AbortSignal.timeout(6000),
      cf: { cacheTtl: 3600, cacheEverything: true } });
    if (!res.ok) throw new Error('Publisher metadata unavailable');
    const models = await res.json();
    if (!Array.isArray(models)) throw new Error('Invalid publisher metadata');
    return models.map(m => candidate(m, publisher)).filter(Boolean);
  }));
  const available = lists.filter(r => r.status === 'fulfilled');
  if (!available.length) throw new Error('Release discovery unavailable');
  const seen = new Set();
  const ordered = available.flatMap(r => r.value)
    .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
    .filter(m => { if (seen.has(m.base)) return false; seen.add(m.base); return true; });
  // Preserve compact choices when large desktop releases dominate the latest list.
  const compact = ordered.filter(m => {
    const size = m.base.match(/(?:^|[-_])E?(\d+(?:\.\d+)?)B(?:[-_.]|$)/i);
    return size && Number(size[1]) <= 4;
  }).slice(0, 10);
  const candidates = [...compact, ...ordered.filter(m => !compact.includes(m))].slice(0, 20);
  // Metadata, never model blobs. Keep the number of subrequests and memory bounded.
  const details = await Promise.allSettled(candidates.map(async m => {
    const [res, original] = await Promise.all([m.id + '?blobs=true', m.base].map(id =>
      fetcher('https://huggingface.co/api/models/' + id, {
        signal: AbortSignal.timeout(6000), cf: { cacheTtl: 3600, cacheEverything: true },
      })));
    if (!res.ok || !original.ok) throw new Error('File metadata unavailable');
    const detail = await res.json();
    const base = await original.json();
    const f = detail.siblings?.find(s => s.rfilename === m.file.rfilename);
    const bytes = f?.size || f?.lfs?.size;
    const sha = f?.lfs?.sha256;
    const revision = detail.sha;
    if (!Number.isFinite(bytes) || bytes < 200000000 || bytes > 24000000000
        || !/^[a-f0-9]{64}$/i.test(sha || '') || !/^[a-f0-9]{40}$/i.test(revision || '')
        || !Number.isFinite(Date.parse(base.createdAt)) || Date.parse(base.createdAt) > now.getTime() + 86400000) return null;
    return { id: m.id, name: m.base.split('/')[1], baseModel: m.base,
      sourceUrl: 'https://huggingface.co/' + m.id, createdAt: base.createdAt, ggufPublishedAt: m.createdAt,
      quantization: m.file.quantization, downloadBytes: bytes, sha256: sha.toLowerCase(), revision,
      filename: m.file.rfilename, license: m.tags.find(t => t.startsWith('license:'))?.slice(8) || 'see model card',
      status: 'discovered' };
  }));
  const models = details.filter(r => r.status === 'fulfilled' && r.value).map(r => r.value)
    .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
  if (!models.length) throw new Error('No verified file metadata');
  return { version: 1, checkedAt: now.toISOString(), refreshHours: 1,
    partial: available.length !== sources.length || details.some(r => r.status === 'rejected'),
    publishers: [...new Set(sources.filter((_, i) => lists[i].status === 'fulfilled').map(s => s.author))], models };
}
