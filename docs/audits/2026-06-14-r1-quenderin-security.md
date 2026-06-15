---
title: "Security Audit (Verified) — Quenderin Round 1"
repo: quenderin
lens: security
date: 2026-06-14
round: 1
---

Confirmed: `.gitignore` exists but does NOT contain `quenderin.json` (contradicting SECURITY.md), and there is NO rate limiting anywhere (contradicting SECURITY.md's claim of "100 requests per 15 minutes"). 

I now have everything needed to write the final verified report. Let me compile my verification summary:

**Verified TRUE:** C1 (deps, with corrections), H2 (CORS null/missing + no Host validation), H3 (no checksum on downloads), M4 (agent loop), M6 (execSync screenshot), M7 (read_file home-wide), M8 (execSync diag), L9 (CSP), L10 (dead ui/app.js), L11 (uncaughtException exit), L12 (electron no nav guard — confirmed no setWindowOpenHandler/sandbox).

**Corrections / false claims in draft:**
- C1: `@xenova/transformers` is NOT unused — it's imported in `memory.service.ts:4` and actively used for embeddings. The "remove it" recommendation is wrong as stated; `tar` is dev-only (electron-builder).
- M5: `adb shell input text text` passes `text` as a single argv element to host `adb`. The device-side shell injection concern is overstated for the standard ADB protocol but the draft's framing as command-injection is partially valid for argument-level breakage — I'll mark it MEDIUM but clarify.

**New findings the draft MISSED (high value):**
- **The server does NOT bind to localhost.** `server.listen(selectedPort, ...)` has no host arg → binds `0.0.0.0`/`::` (all interfaces). This invalidates the "local-only by design" premise and makes H2 reachable from the LAN, not just via DNS rebinding. This is the single biggest miss.
- **SECURITY.md contains false/stale claims** that materially mislead: claims rate limiting (none exists), wrong port (3777 vs 3000), and that `quenderin.json` is gitignored (it is not).
- `env.allowLocalModels = false` in memory.service means the embedding model is fetched remotely (extends H3's supply-chain surface).

Let me produce the final report.

Based on my line-by-line verification, here is the final report.

# Security Audit (Verified) — Quenderin (`/Users/svetlana/Documents/projects/quenderin`)

## Summary
I verified every finding in the draft against source. The codebase is genuinely security-conscious (hand-written calculator, `spawn(adb, args[])` with no host shell, path-traversal guards, `contextIsolation`/`nodeIntegration` set correctly, no stack-trace leakage). However the draft's central premise — "binds to localhost by design" — is **false**, and that error cascades into under-rating the network exposure. I corrected two findings, downgraded one to a quality note, and added three high-value findings the draft missed (one CRITICAL).

**Verdict on the draft:** mostly accurate on the per-file mechanics, but it (1) wrongly claimed `@xenova/transformers` is unused, (2) missed that the HTTP server binds to all interfaces, and (3) missed that `SECURITY.md` makes three materially false safety claims.

---

## Findings (severity-sorted)

### CRITICAL

**C1. HTTP/WS server binds to ALL network interfaces, not localhost — every other "local-only" mitigation is built on a false premise** *(NEW — draft missed this entirely)*
`src/server.ts:192` — `server.listen(selectedPort, async () => {…})` passes **no host argument**, so Node binds `0.0.0.0` / `::` (all interfaces). The port-probe at `src/server.ts:71` (`.listen(port, '::')`) and `src/electron/main.ts:17` confirm the intent is dual-stack-any, not loopback. Consequence: the unauthenticated API (C2/H-tier below) is reachable from **any host on the same LAN/Wi-Fi**, not merely via DNS rebinding. The draft, `src/app.ts:54` ("this is a local-only server"), and `SECURITY.md` all assume loopback binding that does not exist in code.
**Fix:** `server.listen(selectedPort, '127.0.0.1', …)` (and `'127.0.0.1'` on the probe). This is the highest-leverage single fix in the repo.

**C2. Vulnerable dependencies — 2 critical, 14 high, 5 moderate (confirmed via `npm audit`)** *(verified, with corrections)*
Confirmed counts: **21 total (2 critical / 14 high / 5 moderate).**
- `protobufjs@6.11.4` — **critical, arbitrary code execution.** Reached via `@xenova/transformers@2.17.2 → onnxruntime-web → onnx-proto`. **Correction to draft:** `@xenova/transformers` is **NOT unused** — it is imported and actively used for embeddings at `src/services/memory.service.ts:4,92` (`pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2')`). The draft's "remove it" recommendation would break the memory/embeddings feature. Upgrade the transformers stack instead.
- `simple-git@3.32.2` — **critical RCE** (`protocol.allow` bypass). Confirmed runtime path: `node-llama-cpp@3.16.2 → simple-git`. Used only by node-llama-cpp's internal build tooling; low practical reachability but real.
- `fast-xml-parser@5.3.8` — **high**, entity-expansion DoS. Directly relevant: `UiParserService` (`src/services/uiParser.service.ts:5`) parses device-controlled XML, though entity expansion is not explicitly enabled (default config at lines 5-8). Upgrade anyway.
- `electron@40.x` — **high** (AppleScript injection, executeJavaScript IPC spoof) — *not in the draft, surfaced by audit.* Relevant given C5.
- **Correction:** `tar@7.5.9` and `esbuild`/`tsx` are **devDependencies only** (`electron-builder → app-builder-lib → @electron/rebuild`). Not a runtime path-traversal vector as the draft implied; keep them in scope as build-supply-chain risk, not server runtime.
**Fix:** `npm audit fix`; bump `fast-xml-parser`→≥5.5.6, `ws`→≥8.20.1, transformers/onnxruntime to a release without `protobufjs<7.5.5`, electron to a patched 40.x. Add `npm audit --audit-level=high` to the `check` script.

---

### HIGH

**H3. Unauthenticated, state-changing HTTP/WS API; CORS trusts missing/`null` Origin; no Host validation** *(verified — severity reinforced by C1)*
`src/app.ts:37-62`, `src/websocket/index.ts:85-102`. No auth token on any route (verified — `createApp` registers routes with zero auth middleware). Two confirmed gaps:
1. **`origin === 'null'` and missing Origin are treated as trusted** (`src/app.ts:38,58`; mirrored at `src/websocket/index.ts:86`). Simple `fetch`/form POSTs from any page send no Origin or `Origin: null` and pass. Dangerous simple/no-preflight mutating routes confirmed present and unguarded: `POST /api/models/download` (`:120`), `DELETE /api/models/:modelId` (`:130`), `DELETE /api/sessions/:id` (`:180`), `DELETE /api/notes/:filename` (`:289`), `DELETE /api/memory/trajectories` (`:320`), `POST /api/agent/intervene|resume` (`:93,:98`), `POST /api/voice/download` (`:196`).
2. **No `Host`-header validation** → DNS rebinding. Combined with **C1**, this is reachable from the LAN even without rebinding.
**Fix:** Reject missing/`null` Origin for mutating routes; add Host allow-listing (`localhost`/`127.0.0.1` + bound port); mint a per-session bearer token at startup injected into the served HTML and validated on every `/api/*` and WS message.

**H4. Model and voice downloads written to disk and executed with no integrity verification (SSRF/supply-chain)** *(verified)*
- `src/services/llm.service.ts:649-802` (`downloadModel`): streams `entry.url` (HuggingFace) straight to `~/.quenderin/models/<filename>` (`:758-791`) with **no SHA-256/signature check**; the GGUF is then parsed/executed by native `node-llama-cpp`. Triggerable unauthenticated via `POST /api/models/download` (H3).
- `src/app.ts:196-245` (`/api/voice/download`): fetches a remote `.zip` from `alphacephei.com` (`:209`) and pipes it through `unzipper.Extract({ path: voiceDir })` (`:229`) with **no checksum and no zip-slip guard**. `unzipper@0.12.3` confirmed installed; `Extract` does not robustly contain `../` entries on all paths.
- **Additional surface (NEW):** `src/services/memory.service.ts:8` sets `env.allowLocalModels = false`, forcing the embedding model to be fetched **remotely** from the HF hub at runtime with no pinning — same unverified-fetch class.
**Fix:** Pin a `sha256` per `MODEL_CATALOG` entry and verify before first load; verify a known digest for the voice zip and sanitize every entry path (reject absolute / normalized-escaping paths) before extraction; gate both endpoints behind H3 auth.

**H5. `SECURITY.md` makes three materially false security claims** *(NEW — draft missed)*
`SECURITY.md:33`, `:58-59`. The published security policy asserts safeguards that **do not exist in code**, which actively misleads operators into a false sense of safety:
- Claims `quenderin.json` "is in `.gitignore` by default" — **false**: `.gitignore` exists but contains no `quenderin.json` entry (verified). With `apiKey` stored in `process.cwd()/quenderin.json` (`src/config.ts:8,28,48`), a secret could be committed.
- Claims "Rate limiting (100 requests per 15 minutes)" — **false**: no rate-limiting code or dependency exists anywhere (`grep` for `rate-limit`/`express-rate-limit` returns nothing).
- Claims the server runs on "port 3777" — **false**: default is 3000 (`src/server.ts:84`).
**Fix:** Either implement the claimed controls (add `quenderin.json` to `.gitignore`, add `express-rate-limit`, correct the port) or correct `SECURITY.md` to reflect reality. A security policy that overstates protections is worse than none.

---

### MEDIUM

**M6. Agent loop lets unvalidated LLM output drive device input — prompt-injection → real-world actions** *(verified)*
`src/services/agent.service.ts:222-318`, `src/services/providers/android.provider.ts:145-187`. Confirmed: LLM JSON/XML output is parsed (`:244-269`) and dispatched to `actionExecutor.execute` (`:303`) with only structural validation — no allow-listing of typed content or target. Device-scraped UI text and user attachments are concatenated into the prompt (`promptBuilder.buildEnvironment`, `:223`). A hostile app screen/attachment can steer the agent into typing attacker-chosen text via `type()` → `adb shell input text` (`android.provider.ts:150-157`). The human-in-the-loop pause exists (`/api/agent/intervene`) but is **not required** before sensitive actions.
**Fix:** Treat all on-screen text/attachments as untrusted; require a confirmation gate before `type`/destructive keyevents; document the trust model honestly.

**M7. `read_file` tool exposes the entire home directory (incl. secrets) to the LLM** *(verified)*
`src/services/tools/handlers.ts:74-111`, guard `:25-29`. Home-confinement is correctly implemented (no traversal — verified: `path.resolve` + `startsWith(home + sep)`). But the policy is over-broad: a prompt-injected LLM (M6) can read `~/.ssh/id_rsa`, `~/.aws/credentials`, `~/.config/**`, `.env`, and stream up to 8 KB (`:13,:94-99`) into a context that may be logged/exported. Combined with M6's ability to act, this is a credible local-exfiltration chain.
**Fix:** Restrict to an explicit allow-list (e.g. `~/Documents`, `~/Downloads`, the Quenderin data dir) or confirm per path; at minimum denylist `.ssh`/`.aws`/`.gnupg`/`.config`/`.env*`.

**M8. Desktop screenshot fallback builds shell command STRINGS via `execSync`** *(verified — defense-in-depth)*
`src/services/providers/desktop.provider.ts:75,79,82,84,98`. The PNG path is server-generated (`crypto.randomUUID()` under `os.tmpdir()`, `:156`), so **not currently attacker-influenced** — correctly an injection-hardening issue, not a live vuln. The Windows branch only escapes single quotes (`:95`) and interpolates into the outer `execSync("…")`. Fragile if the filename ever flows from input.
**Fix:** Use `execFileSync(cmd, [args])` so the filename is a literal argv element.

**M9. Diagnostic execs via `execSync` with interpolation + host-info disclosure on unauthenticated endpoints** *(verified — defense-in-depth)*
`src/routes/health.ts:20` (`git rev-parse` at module load), `src/services/llm.service.ts:610,620,632` (`Get-PSDrive`/`wmic`/`df -k "${dirPath}"`). All inputs are non-attacker-controlled today: `dirPath` is `path.dirname(modelPath(...))` → `os.homedir()`-derived (verified at `constants.ts:189-193`), and the Windows drive letter is sanitized to `[A-Za-z]` (`llm.service.ts:604`). So **no active injection**. Separately, `/diagnostics` and `/health` disclose PID, Node version, platform/arch, hostname (via `system_info` tool), RAM, and commit SHA to any unauthenticated caller — now LAN-reachable per C1/H3.
**Fix:** Convert to `execFileSync(argv)`; gate `/diagnostics` behind H3 auth or trim host-identifying fields.

**M10. `adb shell input text <text>` forwards LLM-controlled text across the device-side shell** *(verified, but reframed — draft overstated host-side risk)*
`src/services/providers/android.provider.ts:157`. Host side is safe — `spawn('adb', [...])` with no host shell (verified `:30`). The text **is** passed as a single argv element to host `adb`, but `adb shell` reconstructs a command line for the **device's** `/system/bin/sh`, so metacharacters (spaces, `;`, `$()`) in LLM-supplied `text` (origin: M6) can mangle the `input text` invocation or, in principle, alter device-side behavior. This is an argument-/command-injection vector on the device, not the host. Lower practical impact than a host RCE, so MEDIUM is appropriate.
**Fix:** Escape for the device shell (URL-encode spaces as `%s`, escape metacharacters) before `spawnAdb(['shell','input','text', text])`, or use an IME/per-character approach.

---

### LOW

**L11. CSP allows `data:` font/img and inline styles; no `frame-ancestors`/`object-src`/`base-uri`** *(verified)*
`src/app.ts:48-51`. `style-src 'unsafe-inline'`, `img-src data: blob:`, `font-src data:`; no `frame-ancestors`/`object-src`/`base-uri`. `script-src 'self'` (good). Local-only limits impact.
**Fix:** Add `frame-ancestors 'none'; object-src 'none'; base-uri 'self'`; drop `'unsafe-inline'` from `style-src` if the build allows.

**L12. Dead legacy frontend posts `apiKey` to non-existent endpoints** *(verified)*
`ui/app.js:81,127,131,143,166,229` references `/api/upload-config` and `/api/config` — confirmed **neither exists** in `src/app.ts`, and `ui/app.js` is **not served** (server serves `public/`, which contains only `index.html` + `assets/`; verified). Latent risk: if rewired, it would persist `apiKey` to `cwd/quenderin.json` (`src/config.ts:8,48`) — which is not gitignored (see H5).
**Fix:** Delete `ui/app.js` and any legacy config HTML; if a key flow is intended, use the OS keychain and gitignore `quenderin.json`.

**L13. `uncaughtException` hard-exits the process** *(verified)*
`src/server.ts:30-33`. `process.exit(1)` on any uncaught exception → a single throw outside a handler crashes the server (availability/DoS). WS `JSON.parse` is wrapped in try/catch (`websocket/index.ts:157,321` — verified OK), so the most obvious vector is mitigated, but the global exit-on-throw is brittle.
**Fix:** Keep logging; don't `process.exit` for recoverable errors.

**L14. Electron: no `setWindowOpenHandler` / `will-navigate` guard; second main file omits `sandbox`** *(verified)*
`src/electron/main.ts:37-54`, `electron/main.ts:9-24`. `contextIsolation: true` / `nodeIntegration: false` are set in both (good — verified). Neither restricts navigation or `window.open` (confirmed: no `setWindowOpenHandler`/`will-navigate`/`sandbox` anywhere). Note there are **two** Electron entrypoints; `package.json` `main` points at `dist/electron/main.js` (the `src/electron/main.ts` one), so `electron/main.ts` appears to be a dead/alternate bootstrap — worth deleting to avoid drift.
**Fix:** Add `webContents.setWindowOpenHandler(() => ({ action: 'deny' }))`, a `will-navigate` guard restricting to `http://localhost:<port>`, and `sandbox: true`. Remove the unused entrypoint.

---

## Corrections to the draft (explicit)
- **`@xenova/transformers` is USED, not dead** (`src/services/memory.service.ts:4,92`). The draft's "remove it" advice is wrong; upgrade the stack to clear the protobufjs critical instead.
- **`tar`/`esbuild`/`tsx` are devDependencies** (under `electron-builder`/`tsx`), not runtime server vectors. Re-scope them as build supply-chain, not request-path, risk.
- **M5 (device shell) reframed**: host side is provably safe (`spawn` array). The injection surface is the *device's* shell, lower impact than the draft's framing — kept at MEDIUM (now M10).

## Confirmed correct (no action)
No `eval`/`Function` (calculator is a safe parser, `tools/calculator.ts`); `adb` via `spawn(args[])` no host shell (`android.provider.ts:30`); path-traversal guards verified on notes (`app.ts:277,290`), sessions (`session.service.ts:48-52`), docs (`docs.ts:30`), and `read_file` home-confinement (`handlers.ts:25-29`); WS input length-capped and `contextSize` allow-listed (`websocket/index.ts:168,303`); `errorHandler` does not leak stacks (`errorHandler.ts:14`); no hardcoded secrets in `src/`; `android/local.properties` holds only an SDK path.

## Recommended next steps (priority order)
1. **C1** — bind the server to `127.0.0.1` (`src/server.ts:192` + probe `:71`). One line; closes LAN exposure that everything else assumes is already closed.
2. **C2** — `npm audit fix`; upgrade transformers/onnxruntime (clears protobufjs critical) **without** removing `@xenova/transformers`; bump `fast-xml-parser`, `ws`, `electron`; add `npm audit --audit-level=high` to `check`.
3. **H3** — reject missing/`null` Origin on mutating routes + Host-header allow-list + per-session bearer token.
4. **H4** — checksum-verify model & voice downloads; zip-slip-guard the voice extraction; pin the remote embedding model.
5. **H5** — make `SECURITY.md` true: gitignore `quenderin.json`, add rate limiting (or remove the claim), fix the port. False safety claims are a finding, not a typo.
6. **M6/M7/M10** — confirmation gate before device `type`/destructive keyevents; narrow `read_file` away from `~/.ssh`/`~/.aws`/`.env`; device-shell-escape `adb input text`.
7. **M8/M9** — convert `execSync(string)` sites to `execFileSync(argv)`; gate/trim `/diagnostics`.
8. **L11-L14** — tighten CSP; delete `ui/app.js` and the unused `electron/main.ts`; add Electron navigation guards + `sandbox: true`; soften `uncaughtException` handling.

Key files: `/Users/svetlana/Documents/projects/quenderin/src/server.ts`, `/Users/svetlana/Documents/projects/quenderin/src/app.ts`, `/Users/svetlana/Documents/projects/quenderin/src/websocket/index.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/llm.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/memory.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/providers/android.provider.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/providers/desktop.provider.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/tools/handlers.ts`, `/Users/svetlana/Documents/projects/quenderin/SECURITY.md`, `/Users/svetlana/Documents/projects/quenderin/.gitignore`, `/Users/svetlana/Documents/projects/quenderin/package.json`.
