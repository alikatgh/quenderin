# r40 — Quenderin config-security audit (2026-07-11)

**Lens:** Debug defaults, host binding, headers, proxy config (50-round plan r40; pulled forward
into Wave C with the other config lenses)

## Findings

### C1 — Missing `X-Content-Type-Options: nosniff` — **FIXED** (Low)
- **File:** `src/app.ts` (header middleware)
- **Fix:** Added alongside CSP/Referrer-Policy — the docs route serves markdown as `text/plain`;
  never let an engine sniff-upgrade a payload.

## Verified good
- **Bind default is loopback** (`QUENDERIN_HOST || '127.0.0.1'`) with LAN exposure an explicit,
  commented opt-in. (The Docker image sets it deliberately — see r19.)
- **CSP** is tight for a local app: `default-src 'self'`, loopback-only connect-src (both
  localhost aliases, Q-346), `frame-ancestors 'none'`, `object-src 'none'`, `base-uri 'self'`,
  self-hosted fonts (zero third-party requests, Q-568).
- **Referrer-Policy: no-referrer** so the `?token=` URL can't leak via Referer.
- **CORS** allowlists same-machine origins only; no wildcard.
- **Debug gates:** log level is env-gated with prod default `warn` (r18); no `DEBUG=true`-style
  flags shipped on.
- **No trust-proxy configured — correctly:** the server is direct-listen local; honoring
  `X-Forwarded-*` would only add a spoofing surface. Revisit only if a reverse-proxy deployment
  mode ever ships.

## Open
- None for this lens.
