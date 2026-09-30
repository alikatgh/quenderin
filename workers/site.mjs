import { discoverReleases } from './model-releases.mjs';
let refreshing;

function json(data, maxAge = 300) {
  return new Response(JSON.stringify(data), { headers: {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'public, max-age=' + maxAge,
    'X-Content-Type-Options': 'nosniff',
  } });
}

export async function releaseResponse(request, env, ctx, cache = caches.default, fetcher = fetch) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  // Ignore query strings: one public cache entry, with no client-selected upstream URL.
  const key = new Request(new URL('/api/model-releases', request.url).toString());
  const cached = await cache.match(key);
  let data;
  if (cached) {
    data = await cached.json();
    if (Date.now() - Date.parse(data.checkedAt) < 3600000) {
      const response = json({ ...data, freshness: 'live' });
      return request.method === 'HEAD' ? new Response(null, response) : response;
    }
  }
  try {
    // Coalesce concurrent cold-cache requests within an isolate.
    if (!refreshing) refreshing = discoverReleases(fetcher).finally(() => { refreshing = undefined; });
    data = await refreshing;
    // Retain the last successful snapshot for a week so an upstream outage doesn't
    // erase the list. checkedAt, not cache expiry, determines whether it's current.
    ctx.waitUntil(cache.put(key, json(data, 604800)));
    data = { ...data, freshness: 'live' };
  } catch {
    if (!data) {
      const fallback = await env.ASSETS.fetch(new Request(new URL('/data/model-releases.json', request.url)));
      if (!fallback.ok) return new Response('Catalog temporarily unavailable', { status: 503 });
      data = await fallback.json();
    }
    data = { ...data, freshness: 'saved' };
  }
  const response = json(data);
  return request.method === 'HEAD' ? new Response(null, response) : response;
}

export default {
  async fetch(request, env, ctx) {
    if (new URL(request.url).pathname === '/api/model-releases') return releaseResponse(request, env, ctx);
    return env.ASSETS.fetch(request);
  },
};
