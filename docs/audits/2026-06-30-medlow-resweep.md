# Medium/Low Tier Re-sweep — 2026-06-30

> **Note:** This is the MEDIUM/LOW tier re-verification run against current `main` after all 10 HIGH findings were resolved or mitigated. Re-verification performed by sonnet; confirm each open/partial finding independently before acting.

## Summary

After resolving all 10 HIGH-severity findings recorded in the 2026-06-30 audit cycle, a full re-sweep of the 52 medium and low findings across 9 subsystems was completed against the current state of `main`. Of 52 findings, 16 are fully fixed, 6 are partially addressed (mitigated but not closed), and 30 remain open and unchanged from the original audit. The fixed findings span Android core (cancellable downloads, truncation test coverage), iOS foreground downloader cleanup, Electron HTTP auth and WebSocket isolation, LLM service (agent safety bypass, note sanitization, wall-clock timeout), React UI (CSV injection, WS guard), and two CI/supply-chain items (GITHUB_TOKEN permissions, Kotlin compiler checksum). No regressions were found; all open items are carryovers from the original audit with no code change observed.

## Status Count

| Status  | Count |
|---------|-------|
| fixed   | 16    |
| open    | 30    |
| partial | 6     |
| **total** | **52** |

---

## Still Open or Partial

### Android app layer

- **Android app layer** — Downloader busy-poll loop hangs the caller indefinitely and ignores cancellation/interruption — `android/app/src/main/kotlin/ai/quenderin/app/WorkManagerModelDownloader.kt:50-68` — Add `if (Thread.interrupted()) throw DownloadException(...)` at the loop top; wrap `.get()` in try/catch for `InterruptedException`/`ExecutionException`; full fix: migrate to `WorkManager.getWorkInfosForUniqueWorkFlow()` in a coroutine with `collect`.
- **Android app layer** — Terminal SUCCEEDED never reports progress=1.0; final progress fraction is dropped — `android/app/src/main/kotlin/ai/quenderin/app/WorkManagerModelDownloader.kt:54-59` — Reorder SUCCEEDED branch to call `onProgress(1.0)` before returning; move the unconditional `onProgress` call into the non-terminal `else` branch.
- **Android app layer** — No explicit network security config; HTTPS-only for model downloads relies solely on the API-28 platform default — `android/app/src/main/AndroidManifest.xml:14-20` — Create `res/xml/network_security_config.xml` with `cleartextTrafficPermitted="false"` and add `android:networkSecurityConfig` to the `<application>` element.

### Android core

- **Android core** (partial) — Redirects followed to any https host without re-pinning host; only SHA-256 (which is optional) catches a swap — `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt` — Set `instanceFollowRedirects = false` and re-validate host on each redirect, or assert `conn.url.host` matches original after response; enforce sha256 != null for production catalog entries.
- **Android core** — JvmFileSink.append reopens RandomAccessFile + seeks to EOF on every 64 KiB chunk — `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt` — Introduce `begin()`/`close()` lifecycle on `FileSink`; hold one `FileOutputStream` open across all chunks.

### Apple iOS/macOS

- **Apple iOS/macOS** (partial) — BackgroundModelDownloader can silently drop a completed download after app relaunch — `apple/QuenderinKit/Sources/QuenderinKit/BackgroundModelDownloader.swift` — Implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` in app delegate; on relaunch reconstruct destinations from `store.resumable()` keyed by `originalRequest URL`. Do not wire into production until complete.
- **Apple iOS/macOS** — Integrity gate downgrades to magic-only when no SHA-256 is found — `apple/QuenderinKit/Sources/QuenderinKit/ModelIntegrity.swift` — Treat nil sha256 on catalog-originated downloads as a config error and throw; keep magic-only for user-sideloaded files.
- **Apple iOS/macOS** — OfflineReadiness reports 'ready' for a truncated file at >=85% of an estimated size — `apple/QuenderinKit/Sources/QuenderinKit/OfflineReadiness.swift` — Persist real Content-Length in `PersistedDownload.totalBytes` and use exact equality (or tie `.ready` to a passed integrity verify) instead of 0.85 heuristic.
- **Apple iOS/macOS** — DownloadStore swallows decode/persist errors, can lose the resumable-download table — `apple/QuenderinKit/Sources/QuenderinKit/DownloadStore.swift` — Distinguish file-absent from decode-failed; quarantine/rename corrupt file and log via `os_log`; surface `persist()` write failures.
- **Apple iOS/macOS** — SafetyBlocklist is substring/word-boundary keyword matching — trivially bypassed and English-only — `apple/QuenderinKit/Sources/QuenderinKit/SafetyBlocklist.swift` — Add doc comment marking this as defense-in-depth only; require explicit per-action user confirmation at the tool layer independent of blocklist screening.

### Build / CI / supply-chain / config

- **Build/CI** (partial) — Third-party GitHub Actions pinned to mutable tags, not commit SHAs — `.github/workflows/ci.yml, .github/workflows/deploy-website.yml` — Pin the remaining first-party actions (`actions/checkout`, `actions/setup-node`, `actions/setup-java`, `actions/setup-python`, and all four deploy-website actions) to commit SHAs with inline version comments.
- **Build/CI** — Docker runtime image runs as root with no non-root USER — `Dockerfile:35` — Add `useradd` + `USER app` directives in the runtime stage; change `VOLUME /root/.quenderin` to `/home/app/.quenderin`.
- **Build/CI** — Dockerfile uses npm install (not npm ci) and silently swallows install failures — `Dockerfile:24` — Replace with `npm ci`; remove `|| true` from the `npx tsc` step.
- **Build/CI** — Base images and Docker layers pinned only to floating major tag — `Dockerfile:10` — Pin both stages to digest (`node:20-slim@sha256:<digest>`); add Dependabot/Renovate rule.
- **Build/CI** — Abandoned native optional dependency robotjs@^0.6.0 — `package.json:63` — Replace with `@nut-tree-fork/nut-js` or `@hurdlegroup/robotjs`; confirm Node 20 build before removing robotjs.
- **Build/CI** — Root postinstall runs a second npm install in ui/ — `package.json:13` — Replace with `npm ci --prefix ui` or adopt npm workspaces.

### Electron main / preload / local HTTP server / IPC / WebSocket

- **Electron** (partial) — CORS allows all requests with no Origin header — `src/app.ts` — Residual: no-Origin GETs (`/health`, `/diagnostics`) remain exposed. Low priority given token layer covers mutating routes. Could restrict no-origin pass-through to non-/api/ paths for defence-in-depth.
- **Electron** (partial) — resolveCommitSha runs execSync('git ...') at module import time — `src/routes/health.ts` — Wrap execSync in lazy initialization (populate on first `/diagnostics` hit), or remove the execSync fallback entirely for packaged builds.
- **Electron** — /api/health/diagnostics discloses process internals without authentication — `src/routes/health.ts` — Add token guard to `GET /diagnostics` specifically, or strip `pid`/`commitSha`/exact versions from the unauthenticated response.

### LLM service + agent loop + tool/action execution

- **LLM service** — Chat tool follow-up streams model output without stripping tool-call XML — `src/services/llm.service.ts:1092-1102` — Buffer follow-up tokens and emit only from stripped `finalResponse`, or apply `stripToolCalls` incrementally in the `onTextChunk` callback.

### Model download + integrity + providers + catalog

- **Model/catalog** — Pinned SHA-256 hashes trust the HuggingFace LFS pointer, not the actual downloaded bytes — `scripts/refresh_model_hashes.py:10-14` — Download each blob once on a trusted machine, compute sha256 locally, record both HF commit SHA and local hash; pin HF revision in URL.
- **Model/catalog** — Catalog download URLs pin the mutable 'main' branch, not an immutable revision — `shared/model-catalog.json:12` — Replace `resolve/main` with `resolve/<commit-sha>` for all 11 catalog entries; generate in lockstep with `refresh_model_hashes.py`.
- **Model/catalog** — No HTTPS/host-allowlist validation of catalog URLs at the integrity layer — `src/services/llm.service.ts:831` — Assert `u.protocol === 'https:'` and check hostname against an allowlist (`huggingface.co`, `cdn-lfs.huggingface.co`, `cdn-lfs-us-1.huggingface.co`) before `fetch(url, ...)`.
- **Model/catalog** — parse_named treats every uppercase/mixed-case sha256 as missing — `scripts/check_catalog_parity.py:66` — Change `[0-9a-f]{64}` to `[0-9a-fA-F]{64}` in `check_catalog_parity.py:66`, `check_catalog_parity.py:75`, and `refresh_model_hashes.py:54`; normalize to `.lower()` before comparing.
- **Model/catalog** — refresh_model_hashes.py _finish writes the file without confirming sha256 was injected — `scripts/refresh_model_hashes.py:63-68` — After each `re.sub(...)` pass, re-scan the output to assert every matched id has a `sha256: '<64-hex>'` field adjacent; `sys.exit()` if any is missing.

### Marketing website

- **Website** — Service worker caches every resolved response including HTTP errors and redirects — `website/sw.js` — Add `if (res && res.ok && res.type === 'basic')` guard before caching.
- **Website** — Service worker has no Cache-Control header; stale SW can be pinned indefinitely — `website/_headers` — Add `Cache-Control: no-cache, max-age=0, must-revalidate` for `/sw.js` in `_headers`, `netlify.toml`, and `vercel.json`.
- **Website** — No Content-Security-Policy header on any page — `website/_headers` — Add CSP (`default-src 'self'`, etc.) to wildcard header block in all three deployment config files.

### React desktop UI

- **React UI** (partial) — Multiple log entries reuse static string ids ('err','start','close') causing duplicate React keys — `ui/src/hooks/useAgentSocket.ts` — Replace static `id: 'err'` (line 262), `id: 'start'` (line 276), `id: 'close'` (line 238) with `Math.random().toString(36).slice(2, 11)`.
- **React UI** — Dropped-file read can reject unhandled and abort the attachment loop — `ui/src/components/GeneralChatArea.tsx` — Wrap `await file.text()` in a per-file try/catch; alert on failure and continue the loop.

### Remaining src services + utils

- **Services/utils** — Temp WAV file leaked on transcription failure (no cleanup in catch) — `src/services/voice.service.ts` — Hoist `fs.promises.unlink(wavPath).catch(() => {})` into the `finally` block; remove bare unlink on line 187.
- **Services/utils** — Transcribed voice + goals + note previews written verbatim to logs (PII) — `src/services/voice.service.ts` — Replace verbatim content with length indicators at info level; gate full text behind `logger.debug(...)`.
- **Services/utils** — stripControlTokens misses Gemma, Mistral [INST], Phi-3, raw end_header patterns — `src/utils/stripControlTokens.ts` — Add missing patterns: `/<start_of_turn>\w*\n?/gi`, `/<end_of_turn>/gi`, `/\[\/? INST\]/gi`, `/<<\/?SYS>>/gi`, `/<\|(user|assistant|system)\|>/gi`, standalone `/<\|end_header_id\|>/gi`.
- **Services/utils** — Daemon habit log unbounded-growth + non-atomic compaction race — `src/services/metrics.service.ts` — Move compaction into `appendHabitLog`; serialize via promise-chain mutex or write-to-temp-then-rename.
- **Services/utils** — Concurrent metrics writers can drop records (read-modify-write with no lock) — `src/services/metrics.service.ts` — Add promise-chain write mutex (pattern already in MemoryService) or migrate to NDJSON append.
- **Services/utils** — Background daemon poll loop has no shutdown/lifecycle teardown; restart spawns a second loop — `src/services/backgroundDaemon.service.ts` — Add `_stopPromise` + resolver resolved when loop exits; return it from `stop()` so callers can `await daemon.stop()`.

---

## Per-Subsystem Detail

### Android app layer (Kotlin UI, WorkManager downloader, manifest, backup/network XML, build.gradle.kts)

Of 4 findings, 1 is fixed, 3 remain open.

| Status | Title | File |
|--------|-------|------|
| open | Downloader busy-poll loop hangs the caller indefinitely and ignores cancellation/interruption | `android/app/src/main/kotlin/ai/quenderin/app/WorkManagerModelDownloader.kt:50-68` |
| fixed | Model-generated text flows unvalidated into Uri.parse() for a SENDTO intent | `android/app/src/main/kotlin/ai/quenderin/app/ui/ChatScreen.kt:124` |
| open | Terminal SUCCEEDED never reports progress=1.0; final progress fraction is dropped | `android/app/src/main/kotlin/ai/quenderin/app/WorkManagerModelDownloader.kt:54-59` |
| open | No explicit network security config; HTTPS-only relies solely on the API-28 platform default | `android/app/src/main/AndroidManifest.xml:14-20` |

**Evidence notes:**
- Busy-poll (open): `while (true)` loop unchanged — no `Thread.interrupted()`, no `isActive`, no timeout; `.get()` blocks indefinitely on stall.
- URI injection (fixed): `SupportContact.reportMailtoUri` now percent-encodes all interpolated text via `URLEncoder.encode(s, "UTF-8")`.
- Progress=1.0 (open): `onProgress(getDouble(..., 0.0))` fires unconditionally before the `when` block; SUCCEEDED branch clears WorkData so `getDouble` returns 0.0.
- Network config (open): `<application>` has no `android:networkSecurityConfig`; `res/xml/` contains only backup/extraction rules.

---

### Android core (download / inference / integrity)

Of 5 findings, 3 are fixed, 1 is partial, 1 is open.

| Status | Title | File |
|--------|-------|------|
| partial | Redirects followed to any https host without re-pinning host | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt` |
| fixed | Truncated download with no Content-Length bypasses completeness check | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelDownloadEngine.kt` |
| fixed | Download chunk loop is not cancellable | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelDownloadEngine.kt` |
| open | JvmFileSink.append reopens RandomAccessFile + seeks to EOF on every 64 KiB chunk | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt` |
| fixed | No automated tests for security boundaries (scheme, redirect, missing-length, magic-only) | `android/quenderin-core/src/test/kotlin/ai/quenderin/core/CoreTest.kt` |

**Evidence notes:**
- Redirects (partial): Scheme check now rejects non-HTTPS at line 28-31; `instanceFollowRedirects = true` unchanged; cross-host redirect still silently followed; sha256=null still accepted.
- Truncation (fixed): Comment at ModelDownloadEngine.kt:129-131 documents sha256 as the completeness guarantee; CoreVerify.kt:723-736 adds test confirming behavior.
- Cancellable (fixed): `isCancelled: () -> Boolean` constructor param; loop checks on every chunk; `DownloadCancelledException` preserves `.part` and marks PAUSED.
- fd per chunk (open): `RandomAccessFile(file, "rw").use { ... }` still opens/closes on every call; no `begin()`/`close()` lifecycle.
- Test coverage (fixed): CoreVerify.kt now has tests for scheme rejection, missing Content-Length, magic-only gate, checksum mismatch, and cancellation.

---

### Apple iOS/macOS (QuenderinKit + QuenderinApp)

Of 6 findings, 1 is fixed, 1 is partial, 4 remain open.

| Status | Title | File |
|--------|-------|------|
| partial | BackgroundModelDownloader can silently drop completed download after app relaunch | `apple/QuenderinKit/Sources/QuenderinKit/BackgroundModelDownloader.swift` |
| open | Integrity gate downgrades to magic-only when no SHA-256 is found | `apple/QuenderinKit/Sources/QuenderinKit/ModelIntegrity.swift` |
| open | OfflineReadiness reports 'ready' for truncated file at >=85% of estimated size | `apple/QuenderinKit/Sources/QuenderinKit/OfflineReadiness.swift` |
| open | DownloadStore swallows decode/persist errors, can lose resumable-download table | `apple/QuenderinKit/Sources/QuenderinKit/DownloadStore.swift` |
| open | SafetyBlocklist is substring/word-boundary keyword matching — trivially bypassed | `apple/QuenderinKit/Sources/QuenderinKit/SafetyBlocklist.swift` |
| fixed | Stale partial file left behind on failed/cancelled foreground download | `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift` |

**Evidence notes:**
- Background downloader (partial): Class now explicitly doc-commented as non-shipping; in-memory maps still have no relaunch rehydration; `handleEventsForBackgroundURLSession` still not implemented. Live risk is zero until intentionally wired.
- Integrity soft-downgrade (open): `if let expected = expectedSHA256, !expected.isEmpty` still falls through to magic-only on nil SHA; both downloaders pass nil SHA for catalog entries without sha256 field.
- OfflineReadiness (open): 0.85 threshold against `DiskSpace.estimatedDownloadBytes` unchanged at lines 41-44.
- DownloadStore (open): `try?` on decode at lines 48-53 silently zeros records; `try?` on persist write at lines 89-92 has no error surfacing.
- SafetyBlocklist (open): `\bkeyword\b` on lowercased text unchanged; no defense-in-depth doc comment visible.
- Partial cleanup (fixed): `ChunkedDownloadDelegate.urlSession(_:task:didCompleteWithError:)` at lines 121-126 now removes partial on all error/cancel paths.

---

### Build / CI / supply-chain / config

Of 8 findings, 2 are fully fixed, 1 is partially fixed, 5 remain open.

| Status | Title | File |
|--------|-------|------|
| partial | Third-party GitHub Actions pinned to mutable tags, not commit SHAs | `.github/workflows/ci.yml, .github/workflows/deploy-website.yml` |
| fixed | CI workflows do not set least-privilege GITHUB_TOKEN permissions | `.github/workflows/ci.yml:17` |
| fixed | Kotlin compiler downloaded in CI without checksum verification | `.github/workflows/ci.yml:110` |
| open | Docker runtime image runs as root with no non-root USER | `Dockerfile:35` |
| open | Dockerfile uses npm install (not npm ci) and silently swallows install failures | `Dockerfile:24` |
| open | Base images and Docker layers pinned only to floating major tag | `Dockerfile:10` |
| open | Abandoned native optional dependency robotjs@^0.6.0 | `package.json:63` |
| open | Root postinstall runs a second npm install in ui/ | `package.json:13` |

**Evidence notes:**
- Actions pinning (partial): `codecov/codecov-action` and `android-actions/setup-android` are now SHA-pinned; 6 `actions/*` in ci.yml and 4 in deploy-website.yml still use mutable version tags.
- GITHUB_TOKEN (fixed): `permissions: contents: read` set at workflow level (ci.yml:14-18); coverage job adds `id-token: write`.
- Kotlin checksum (fixed): `sha256sum -c -` runs before unzip at ci.yml:111-113.
- Docker root (open): No `USER` directive in runtime stage (Dockerfile:35-69); `VOLUME /root/.quenderin` unchanged.
- npm install (open): `RUN npm install ... || true` and `RUN npx tsc || true` unchanged at lines 24-31.
- Floating image tag (open): Both `FROM node:20-slim AS builder` and `FROM node:20-slim AS runtime` unpinned.
- robotjs (open): `"robotjs": "^0.6.0"` in optionalDependencies; no release since 2020, does not support Node 20+ natively.
- postinstall (open): `"postinstall": "cd ui && npm install"` ignores lockfile on every root install.

---

### Electron main / preload / local HTTP server / IPC / WebSocket

Of 5 findings, 2 are fully fixed, 2 are partial, 1 is open.

| Status | Title | File |
|--------|-------|------|
| fixed | State-changing HTTP routes unauthenticated and not CSRF-protected | `src/app.ts` |
| partial | CORS allows all requests with no Origin header | `src/app.ts` |
| open | /api/health/diagnostics discloses process internals without authentication | `src/routes/health.ts` |
| partial | resolveCommitSha runs execSync('git ...') at module import time | `src/routes/health.ts` |
| fixed | WebSocket second connection silently hijacks shared service listeners | `src/websocket/index.ts` |

**Evidence notes:**
- HTTP auth (fixed): Middleware at app.ts:83-95 validates `X-Auth-Token` or `?token=` on all POST/PUT/PATCH/DELETE `/api/*` routes.
- CORS (partial): `if (!origin) return callback(null, true)` unchanged; auth token now covers mutating routes; no-origin GET paths (`/health`, `/diagnostics`) remain exposed.
- /diagnostics (open): `router.get('/diagnostics', ...)` mounted before auth middleware; returns `pid`, `nodeVersion`, `commitSha`, `hardware` with no token.
- execSync (partial): Env-var short-circuit at lines 17-18 skips `execSync` in CI/packaged builds; still fires in dev without `QUENDERIN_GIT_SHA`/`GITHUB_SHA`.
- WebSocket (fixed): Lines 135-143 explicitly remove previous connection's listeners before registering new ones; non-local-Origin and non-token connections rejected at lines 117-129.

---

### LLM service + agent loop + tool/action execution

Of 5 findings, 4 are fixed, 1 is open.

| Status | Title | File |
|--------|-------|------|
| fixed | note_save passes model-controlled title to filesystem without sanitization | `src/services/tools/handlers.ts:187-194` |
| fixed | Agent action safety blocklist bypassed by coordinate clicks and icon buttons | `src/services/agent/actionExecutor.ts:40-47, 118-123` |
| open | Chat tool follow-up streams model output without stripping tool-call XML | `src/services/llm.service.ts:1092-1102` |
| fixed | generateAction creates chat session but never disposes it on the prompt path | `src/services/llm.service.ts:958-987` |
| fixed | Agent loop has no overall wall-clock timeout; only a step count cap | `src/services/agent.service.ts:138, 173, 215-219` |

**Evidence notes:**
- note_save (fixed): `MemoryService.saveNote` calls `sanitizeNoteTitle()` from `src/utils/notes.ts:7-14`; strips to `[a-zA-Z0-9\s\-_]`, 80-char cap; path via `path.join`.
- Safety blocklist (fixed): `elementsContaining(x, y, elements)` added at lines 40-47; `el?.resourceId` now included in text candidates for icon buttons.
- XML streaming (open): `onTextChunk` at llm.service.ts:1092-1097 calls only `stripControlTokensWithOptions`, not `stripToolCalls`; raw tool-call XML can leak to `onToken` before the final strip at line 1102.
- Session disposal (fixed): `LlamaChatSession` holds only a reference to the sequence; `sequence.dispose()` reclaims underlying resource; no separate `session.dispose()` method exists in node-llama-cpp.
- Wall-clock timeout (fixed): `maxWallClockMs` parameter at line 138; `Date.now() - startTimeMs >= maxWallClockMs` checked at loop top (line 219); distinct timeout error emitted at lines 390-391.

---

### Model download + integrity + providers + catalog

Of 6 findings, 1 is fixed (was a false positive), 5 remain open.

| Status | Title | File |
|--------|-------|------|
| open | Pinned SHA-256 hashes trust the HuggingFace LFS pointer, not the actual downloaded bytes | `scripts/refresh_model_hashes.py:10-14` |
| open | Catalog download URLs pin the mutable 'main' branch, not an immutable revision | `shared/model-catalog.json:12` |
| open | No HTTPS/host-allowlist validation of catalog URLs at the integrity layer | `src/services/llm.service.ts:831` |
| fixed | sha256File stream fd leak (false positive) | `src/services/modelIntegrity.ts:43-51` |
| open | parse_named treats every uppercase/mixed-case sha256 as missing | `scripts/check_catalog_parity.py:66` |
| open | _finish writes the file without confirming sha256 was injected | `scripts/refresh_model_hashes.py:63-68` |

**Evidence notes:**
- LFS hashes (open): `refresh_model_hashes.py:10-14` docstring explicitly states hashes come from HF LFS pointer OIDs, not blobs.
- Mutable URLs (open): All 11 catalog entries at `shared/model-catalog.json` use `resolve/main`; no `resolve/<commit-sha>` pinning.
- No allowlist (open): `fetch(url, ...)` at llm.service.ts:831 uses raw `entry.url` with no scheme or hostname check before connecting.
- fd leak (fixed — false positive): Node `createReadStream` defaults `autoClose: true`; `hash.digest('hex')` is synchronous; no actual leak path.
- Lowercase regex (open): `[0-9a-f]{64}` in `check_catalog_parity.py:66` and `refresh_model_hashes.py:54 (HEX64)` — uppercase sha256 silently treated as missing.
- _finish verification gap (open): `_finish` checks `missing = set(HASHES) - seen` but does not re-scan output to assert sha256 was actually written adjacent to each matched id.

---

### Marketing website (static)

All 3 findings remain open. No changes to this subsystem since the original audit.

| Status | Title | File |
|--------|-------|------|
| open | Service worker caches every resolved response including HTTP errors and redirects | `website/sw.js` |
| open | Service worker has no Cache-Control header; stale SW can be pinned indefinitely | `website/_headers` |
| open | No Content-Security-Policy header on any page | `website/_headers` |

**Evidence notes:**
- Cache all responses (open): `sw.js:26-29` — `caches.open(CACHE).then(c => c.put(...))` with no `res.ok` or `res.type === 'basic'` guard.
- SW Cache-Control (open): `_headers`, `netlify.toml`, and `vercel.json` all lack a `/sw.js` Cache-Control entry.
- CSP (open): No `Content-Security-Policy` header in any of the three deployment config files; only `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options`, `Permissions-Policy` are present.

---

### React desktop UI (ui/)

Of 4 findings, 2 are fixed, 1 is partial, 1 is open.

| Status | Title | File |
|--------|-------|------|
| partial | Multiple log entries reuse static string ids causing duplicate React keys | `ui/src/hooks/useAgentSocket.ts` |
| fixed | WebSocket message handler dereferences fields without guards | `ui/src/hooks/useAgentSocket.ts` |
| fixed | CSV export is vulnerable to spreadsheet formula injection via goal text | `ui/src/components/Metrics.tsx` |
| open | Dropped-file read can reject unhandled and abort the attachment loop | `ui/src/components/GeneralChatArea.tsx` |

**Evidence notes:**
- Static ids (partial): Line 115 and reconnect entries now use random ids; three static ids survive: `id: 'err'` (line 262), `id: 'start'` (line 276), `id: 'close'` (line 238).
- WS guards (fixed): Discriminated-union `AgentMessage` type at lines 40-52; optional-chain guards; try/catch wraps entire `onmessage` body.
- CSV injection (fixed): `csvCell()` helper at lines 99-105 prefixes `=`, `+`, `-`, `@`, `\t`, `\r` with a single quote.
- File drop (open): `await file.text()` at line 151 has no try/catch; I/O error aborts the loop and leaves remaining files unprocessed with no user feedback.

---

### Remaining src services + utils

All 6 findings remain open. None were fixed since the original audit.

| Status | Title | File |
|--------|-------|------|
| open | Temp WAV file leaked on transcription failure (no cleanup in catch) | `src/services/voice.service.ts` |
| open | Transcribed voice + goals + note previews written verbatim to logs (PII) | `src/services/voice.service.ts` |
| open | stripControlTokens misses Gemma, Mistral [INST], Phi-3, raw end_header patterns | `src/utils/stripControlTokens.ts` |
| open | Daemon habit log unbounded-growth + non-atomic compaction race | `src/services/metrics.service.ts` |
| open | Concurrent metrics writers can drop records (read-modify-write with no lock) | `src/services/metrics.service.ts` |
| open | Background daemon poll loop has no shutdown/lifecycle teardown | `src/services/backgroundDaemon.service.ts` |

**Evidence notes:**
- WAV leak (open): `voice.service.ts:187` — `fs.promises.unlink(wavPath)` on success path only; catch block (line 203-204) only logs; finally block (line 205-209) only resets STATE.
- PII logging (open): `voice.service.ts:197` — full spoken command at info level; `memory.service.ts:188` — raw goal text at info level.
- stripControlTokens (open): 8 patterns cover ChatML, Llama, legacy EOS, tool_call XML, Llama 3 headers; missing Gemma `<start_of_turn>`/`<end_of_turn>`, Mistral `[INST]`/`[/INST]`, `<<SYS>>`/`<</SYS>>`, Phi-3 `<|user|>`/`<|assistant|>`/`<|system|>`, standalone `<|end_header_id|>`.
- Compaction race (open): `metrics.service.ts:94-98` — compaction fires inside `getHabits()` (a reader); `fs.writeFile(...).catch(() => {})` with no mutex; concurrent `appendHabitLog` can clobber.
- Read-modify-write (open): `metrics.service.ts:48-60` — `appendMetrics` does `readFile → parse → push → writeFile` with no mutex; concurrent callers lose records.
- Daemon shutdown (open): `backgroundDaemon.service.ts:41-51` — `stop()` sets flag and returns void immediately; loop may continue for up to `pollIntervalMs`; no `AbortController` for in-flight provider calls; no await-able teardown.
