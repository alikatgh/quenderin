# r19 — Quenderin deployment audit (2026-07-11)

**Lens:** Env vars, prod defaults, Docker, packaging (50-round plan r19)

## Findings

### P1 — The documented Docker deployment could not work at all — **FIXED** (High)
- **File:** `Dockerfile`
- **Symptom:** The server binds `127.0.0.1` by default and nothing in the image overrode it, so
  `docker run -p 3000:3000` mapped the host port to the container's eth0 while the server listened
  only on container-loopback — connection refused, always.
- **Fix:** `ENV QUENDERIN_HOST=0.0.0.0` (container-scoped; isolation still comes from Docker
  networking, auth from the per-launch token). Run instructions now say where to find the
  `?token=` URL (`docker logs`).

### P2 — `|| true` on `npm install` and `npx tsc` shipped false-green images — **FIXED** (Medium)
- **File:** `Dockerfile`
- **Symptom:** A real dependency failure or a TS compile error still produced an image — which
  then died (or ran stale code) at runtime. npm already downgrades optionalDependencies failures
  to warnings, so the `|| true` only masked genuine breaks.
- **Fix:** `npm ci` (lockfile-exact) for both packages; strict `npx tsc`.

## Verified good
- Container runs as uid 10001 (non-root, audit-driven), `NODE_ENV=production`, memory cap via
  `NODE_OPTIONS`, healthcheck against `/health`, models on a named volume owned by the app user.
- Electron packaging: mac is explicitly lab-only (public macOS channel is the native Swift app);
  win/linux target matrices are sane; icons from `brand/` (not gitignored build output).
- No hardcoded secrets in build files; the per-launch token is generated at runtime.
