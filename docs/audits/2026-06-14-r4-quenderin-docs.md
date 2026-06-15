---
title: Quenderin Documentation Audit — Round 4
repo: quenderin
lens: docs
date: 2026-06-14
round: 4
---

All verified. Confirming the additional finding: TROUBLESHOOTING:299 says `LOG_LEVEL=debug` but code reads `QUENDERIN_LOG_LEVEL` — a real no-op bug the draft missed (and DEVELOPMENT.md env table omits `QUENDERIN_LOG_LEVEL` entirely). Also note DEVELOPMENT.md references `~/.quenderin/config.json` as "Saved configuration" — but config.ts (which writes that) is dead, so that's also slightly misleading, though minor.

I also note one nuance to fix in M2: `chat_response` in API.md (line 86) is listed in the event-type table with a one-line description but no field detail, and `meta` is genuinely undocumented there — confirmed. The draft's M2 is accurate.

Note for M5/QUICKSTART: the real log line is emitted via `logger.critical('Dashboard running at...')`. The logger prefixes by level, so the actual output is NOT `[Server] Dashboard running...`. The draft says actual is `Dashboard running at http://localhost:${port}` — correct, no `[Server]` prefix on that specific line.

I have verified every finding. Producing the final report.

---

# Quenderin — Documentation Audit (read-only, adversarially verified)

Repo: `/Users/svetlana/Documents/projects/quenderin`
Lens: docs — stale/missing docs, mis-documented public APIs, doc↔code drift, onboarding gaps.
Method: read every root `.md` + `docs/*.md`, cross-checked against `src/` (index, server, app, websocket, config, constants, services/tools, agent.service, presets, routes, utils/logger), `ui/`, `.gitignore`, `.github/`, `website/`, `apple/`. Every finding below was re-verified against the cited source line in this pass; I corrected line/attribution drift, downgraded one finding, and added one finding the draft missed (the `LOG_LEVEL` no-op).

**Verdict:** the draft is substantially accurate. All CRITICAL and HIGH findings hold up against the code. I made these changes: **added a new MEDIUM (M6b: `LOG_LEVEL` env var is a no-op — code reads `QUENDERIN_LOG_LEVEL`)**, which also makes the draft's L4 partially wrong (it listed `LOG_LEVEL` as honored — it is not); **softened L6** (the checklist text is more nuanced than "implies it's missing"); corrected minor line-number attributions in C2; and confirmed the L5 test-count gap (119 `func test` in test files, 120 incl. a doc).

Headline unchanged: `docs/` is accurate and maintained; the **root marketing/setup docs + `ui/README.md` are fossils from an abandoned cloud/Ollama-provider design** and are badly drifted, with `SECURITY.md` actively misleading.

---

## CRITICAL

### C1 — `ui/README.md` documents a completely different application (orphaned doc) — CONFIRMED
Files: `ui/README.md` (entire file); dead `ui/app.js`.
`ui/README.md` describes a "drag-and-drop interface for LLM connection setup": a `quenderin ui` CLI command, port **3777**, Ollama/OpenAI/OpenAI-compatible provider auto-detect, and endpoints `GET/POST /api/config`, `POST /api/upload-config`, `POST /api/test-connection`, `GET /api/detect-ollama`. None exist:
- CLI has only `agent` and `dashboard` (`src/index.ts:22-23,51-53`); no `ui` command.
- Default port is **3000** (`src/index.ts:54`, `src/server.ts:84`), never 3777.
- None of those endpoints exist; `src/app.ts:78-332` exposes health/docs/metrics/agent/models/presets/tools/templates/sessions/voice/notes/memory only.
- `ui/index.html` loads `/src/main.tsx` (React+Vite). The drag-drop screen described corresponds only to `ui/app.js` (vanilla JS: `dropZone`, `providerSelect`, `ollamaDetected`, `detectOllama()` — `ui/app.js:1-18`), which nothing serves.
Fix: replace `ui/README.md` with the real React-dashboard description or link to `docs/FRONTEND.md`. Confirm `ui/app.js` is unused, then delete it.

### C2 — `SECURITY.md` is fabricated for a cloud product and gives a false gitignore assurance — CONFIRMED
File: `SECURITY.md:26-79` (line attributions corrected below).
- `:43` "Works completely offline **with Ollama**" and `:50-53` cloud-provider/API-key language — there is no Ollama and no cloud-provider code (provider config is dead, see C3).
- `:54,60` "**Rate limiting** is enabled" / "Rate limiting (100 requests per 15 minutes)" — there is **no rate limiting** in `src/` (grep for rate-limit/express-rate is empty; `src/app.ts` middleware is CORS + CSP + JSON + static + error handler only).
- `:58` "The web UI server (**port 3777**)" — wrong; default 3000.
- `:31` "Never commit `quenderin.json` … (**it's in `.gitignore` by default**)" — **FALSE**. `quenderin.json` is NOT in `.gitignore` (verified full file). Dangerous because the same doc (`:28`) tells users to put plaintext API keys there.
- `:78` "Automated **Dependabot** updates are enabled" — no `.github/dependabot.yml` (only `.github/workflows/ci.yml` exists).
Real, documentable protections: local-only CORS + CSP + WS-origin allowlist (`src/app.ts:37-62`), 1 MB attachment cap (`MAX_ATTACHMENT_SIZE`, `src/constants.ts:264`), docs-route path sanitization (`src/routes/docs.ts`).
Fix: rewrite to match reality (local-only, no cloud providers, no rate limiting). If `quenderin.json` secrets are kept, actually add it to `.gitignore`. Remove Dependabot/Ollama/OpenAI text or implement them.

---

## HIGH

### C3 (HIGH) — `SETUP.md` documents a `quenderin.json` config system that has zero effect (dead config) — CONFIRMED
File: `SETUP.md:65-92`; root cause `src/config.ts`.
SETUP advertises a functional `quenderin.json` with `maxTokens`, `temperature`, `threads`, `outputDir`, `provider` ("gguf"/"ollama"/"openai"/"auto"), `modelPath`, `modelName`, `apiKey`, `baseURL`. But `loadConfig`/`saveConfig`/`createDefaultConfig` (`src/config.ts:27,47,63`) are never imported or called anywhere in `src/` (verified — the only cross-reference is `createDefaultConfig` calling `saveConfig` internally at `config.ts:71`; nothing calls `createDefaultConfig`). So every setting in that table is inert. Worse, it advertises `provider: openai` + `apiKey`, contradicting the no-API-key thesis and (with `SECURITY.md`) telling users to store secrets in a file the app ignores.
Fix: delete the config-file section from `SETUP.md` (and the `modelPath`/`threads` references in `TROUBLESHOOTING.md:142,159`), or wire `loadConfig()` into startup and drop the provider/apiKey/baseURL fields.

### C4 (HIGH) — `FEATURES.md` model catalog is wrong (count, IDs, vendors) — CONFIRMED
File: `FEATURES.md:9-25`.
FEATURES claims "a built-in catalog of **three Llama** model tiers" with IDs `llama-3-8b`, `llama-3.2-3b`, `llama-3.2-1b`. Reality (`src/constants.ts:67-167`): **11 models** across Qwen3-14B, Qwen2.5-Coder-7B, DeepSeek-R1-7B, Llama-3-8B, Mistral-7B, Gemma-3-4B, Qwen3-4B, Phi-4-mini, Llama-3.2-3B/1B/1B-Q2. The IDs are also the wrong format — actual IDs use no dots/dashes-in-version: `llama3-8b`, `llama32-3b`, `llama32-1b`. Default recommendation for a mainstream machine is `qwen3-4b`, not a Llama (`constants.ts:184`). QUICKSTART (`:69-76`) and TROUBLESHOOTING (`:89,148-156`) repeat the Llama-only-3-models myth.
Fix: regenerate the tables from `MODEL_CATALOG` / `shared/model-catalog.json` (canonical per `STATUS.md`). Consider auto-generating to prevent recurrence.

### C5 (HIGH) — Multiple docs reference WebSocket message types that do not exist — CONFIRMED
Files: `SETUP.md:148-152`, `SETUP.md:169`, `FEATURES.md:25`, `FEATURES.md:180`.
The real inbound WS handlers are exactly `start`, `chat`, `settings_update`, `preset_switch`, `manual_voice_start`, `manual_voice_stop` (`src/websocket/index.ts:166,211,301,307,316,318`). Documented-but-nonexistent:
- `{"type":"download_model", ...}` + `download_progress` events (`SETUP.md:148-152`) — downloads are REST (`POST /api/models/download`, `src/app.ts:120`); the only progress event is `model_download_progress` (`src/websocket/index.ts:144`).
- `switch_model` (`FEATURES.md:25`, `SETUP.md:169`) — does not exist.
- `reset_settings` (`FEATURES.md:180`) — does not exist.
`docs/API.md:71-75` lists the correct inbound set, so the root docs directly contradict the authoritative protocol doc.
Fix: delete the invented types; point SETUP/FEATURES at `docs/API.md` as the single source of truth.

---

## MEDIUM

### M1 — `runAgentLoop` signature documented with wrong third parameter (`history` vs `attachments`) — CONFIRMED
Files: `docs/ARCHITECTURE.md:129`, `docs/BACKEND.md:29` (both `runAgentLoop(goal, emitter, history, maxSteps)`), `docs/API.md:71` (WS `start` lists `history`).
Actual: `runAgentLoop(goal, emitter, attachments, maxSteps)` (`src/services/agent.service.ts:107`); the WS handler passes `sanitizeAttachments(data.attachments)` as the third arg and **omits `maxSteps`** (`src/websocket/index.ts:204-205`) — so the third `start` payload field is `attachments`, not `history`, and the documented `maxSteps` field on `start` (`API.md:71`) is a no-op over WebSocket (it defaults). The CLI `agent --steps` does honor it (`src/index.ts:44`).
Fix: change the signature in ARCHITECTURE/BACKEND to `(goal, emitter, attachments, maxSteps)`; in `docs/API.md` replace `history` with `attachments` on `start` and note `maxSteps` is currently ignored over WS.

### M2 — `chat_response` payload: API.md under-documents, FEATURES over-documents — CONFIRMED
Files: `docs/API.md:86` (lists `chat_response` with no field detail), `FEATURES.md:90` ("`intent`, `confidence`, `source` … attached to each `chat_response`").
Reality (`src/websocket/index.ts:272`): `chat_response` carries `{ message, meta, intent }` where `intent` is the **string** `intent.intent`, not the `{intent, confidence, source}` object FEATURES claims. `meta` (GenerationMeta: tokenCount/durationMs/tokensPerSecond/timeToFirstTokenMs) is real but undocumented in `docs/API.md`.
Fix: document `chat_response` fields in `docs/API.md` (`message`, `meta`, `intent: string`); correct FEATURES to "the classified intent string is attached" (confidence/source stay server-side).

### M3 — BACKEND.md tool list is wrong; FEATURES.md tool list is incomplete — CONFIRMED
Files: `docs/BACKEND.md:57-58`, `FEATURES.md:101-127`.
- BACKEND lists `calculator, expression, datetime, system_info, read_file, note_save, note_list`. `expression` is **not a tool** — it is the parameter name of `calculator` (`src/services/tools/registry.ts:42`). The real set is `calculator, datetime, system_info, read_file, note_save, note_list` (6 tools, `registry.ts:39-72`).
- FEATURES documents only `calculator, datetime, system_info` and omits `read_file`, `note_save`, `note_list` — the three that power the `/api/notes` UI surface. `read_file` is home-dir-sandboxed and truncates at 8000 chars (`registry.ts:57`, `handlers.ts:80,98`) — security-relevant and undocumented.
Fix: regenerate both lists from `AVAILABLE_TOOLS`; document `read_file`'s home-dir sandbox + truncation.

### M4 — `RUN_GUIDE.md` leaks a different username and hardcodes wrong absolute paths — CONFIRMED
File: `RUN_GUIDE.md:9,28`.
Both code blocks instruct `cd` into `/Users/s_avelova/Documents/projects/quenderin` (and `.../ui`) — a stale absolute path from another user (`s_avelova`); the repo lives under `svetlana`. Also `RUN_GUIDE.md:43` says the backend "relies on an offline **LLaMA 3** check-point," reinforcing the Llama-only myth (C4).
Fix: use relative instructions ("from the project root", "cd ui"). Never hardcode absolute home paths in a public-bound doc.

### M5 — QUICKSTART shows a fabricated startup banner the server never prints — CONFIRMED
File: `QUICKSTART.md:48-52,57-59`.
Claims `[Server] Starting Quenderin dashboard...`, `[WebSocket] WebSocket server ready`, and a `[Server] Dashboard running...` line. The actual log is `Dashboard running at http://localhost:${selectedPort}` via `logger.critical` (`src/server.ts:195`) — no `[Server] Starting...` and no `[WebSocket] WebSocket server ready` line exist. The "is busy" line is real (`src/server.ts:90`) but interpolates the actual ports.
Fix: paste the real log lines (or describe loosely); don't hardcode 3000/3001.

### M6 — TROUBLESHOOTING gives a `PORT` env var the server ignores — CONFIRMED
File: `TROUBLESHOOTING.md:32-34`.
"`PORT=3001 npm run dashboard`". The port comes only from the CLI `--port` flag / default 3000 (`src/index.ts:54`, `src/server.ts:84`); `process.env.PORT` is never read (verified grep empty). Correct form: `npm run dashboard -- --port 3001`.
Fix: replace with the `--port` flag form, or add `process.env.PORT` support.

### M6b — NEW (draft missed it): TROUBLESHOOTING's `LOG_LEVEL` debug command is a no-op
File: `TROUBLESHOOTING.md:299` (`LOG_LEVEL=debug npm run dashboard`).
The logger reads **`QUENDERIN_LOG_LEVEL`**, not `LOG_LEVEL` (`src/utils/logger.ts:4,26`). `process.env.LOG_LEVEL` is never read anywhere in `src/` (verified grep empty). So the documented verbose-logging command silently does nothing. This also makes the draft's **L4 partially wrong** — L4 listed `LOG_LEVEL` among env vars the code "honors"; it does not. The honored var is `QUENDERIN_LOG_LEVEL`.
Fix: change the doc to `QUENDERIN_LOG_LEVEL=debug npm run dashboard`; add `QUENDERIN_LOG_LEVEL` to the `docs/DEVELOPMENT.md` env table.

### M7 — TROUBLESHOOTING references a nonexistent "documentation generator" — CONFIRMED (examples/ note refined)
File: `TROUBLESHOOTING.md:245-269`.
- `:269` "Or re-create it by running the documentation generator." No such generator exists (no script in `package.json`/`scripts/`). The only recovery is `git checkout` (which the doc also shows).
- `:245` "(or `examples/` subdirectory)" — the docs route *does* implement a dual-path root→`examples/` lookup (`src/routes/docs.ts:32-46`), but there is no `examples/` dir, so the fallback always 404s. This is harmless code-wise but the doc implies a layout that doesn't exist. (Refinement: the draft said "the route checks for it and 404s" — accurate; the `examples/` reference is real code, just dead.)
Fix: drop the "documentation generator" line; either remove the `examples/` mention or note the dir is unused.

### M8 — No top-level docs index; four overlapping, contradicting onboarding docs — CONFIRMED
Files: root `README.md`, `QUICKSTART.md`, `SETUP.md`, `RUN_GUIDE.md`, `FEATURES.md`, `TROUBLESHOOTING.md`, plus `docs/DEVELOPMENT.md`.
At least four "install and run" docs (`QUICKSTART`, `SETUP`, `RUN_GUIDE`, `docs/DEVELOPMENT`) re-derive the same facts and disagree (model lists, ports, config, banners). `README.md` links into `docs/` but not to the root quickstarts, so there's no map of which doc is authoritative. The C3/C4/C5/M5/M6 drift is the direct consequence: the same fact restated in 4 places, only `docs/` kept current.
Fix: declare `docs/` authoritative (`docs/API.md` for protocol, `MODEL_CATALOG`/`shared/model-catalog.json` for models); collapse QUICKSTART/SETUP/RUN_GUIDE into one that links out rather than re-derives; add a one-line pointer in `README.md`.

---

## LOW

### L1 — Voice log string mismatch — CONFIRMED
`TROUBLESHOOTING.md:148` documents `[Voice] PICOVOICE_ACCESS_KEY not set — voice features disabled`; actual is `[Voice Control] PICOVOICE_ACCESS_KEY not set — voice controls disabled.` (`src/server.ts:141`). Users grepping for the doc string won't find it. Fix: match the real string.

### L2 — Project mandate unmet: no `docs/BUG_JOURNAL.md` — CONFIRMED
Only `docs/audits/` exists; no `docs/BUG_JOURNAL.md`. Fix: bootstrap it (`/init-bug-journal`) and seed the recurring "public-doc-vs-executed-code drift" pattern these findings exemplify.

### L3 — SETUP system-requirements Node "25.x" implausible; stale `off-grid-mobile` pointer — CONFIRMED
`SETUP.md:11` recommends Node "22.x or 25.x"; CI tests `[20.x, 22.x]` (`.github/workflows/ci.yml:16`) — 25.x is not an LTS line. `SETUP.md:20` points iOS dev at an "`off-grid-mobile` sub-project" — that dir is gitignored (`.gitignore:3`) and absent; the native app is in `apple/`. Fix: align Node to 20/22; repoint to `apple/`.

### L4 — `docs/DEVELOPMENT.md` env-var table is incomplete — CONFIRMED, with correction
`docs/DEVELOPMENT.md:60-64` lists only `PICOVOICE_ACCESS_KEY` and `CI`/`GITHUB_ACTIONS`. The code also honors `TARGET_OS` (`src/index.ts:29`, `src/server.ts:107`), `QUENDERIN_NO_BROWSER`/`BROWSER=none` (`src/server.ts:94`), `LLM_MODEL_PATH` (`src/constants.ts:284`), `QUENDERIN_LOG_LEVEL` (`src/utils/logger.ts:26`), `QUENDERIN_MAX_AGENT_STEPS` (`src/services/agent.service.ts`), `QUENDERIN_GIT_SHA`/`GITHUB_SHA` (`src/routes/health.ts:17`). **Correction vs draft:** the draft listed plain `LOG_LEVEL` here — the honored var is `QUENDERIN_LOG_LEVEL` (see M6b). `TARGET_OS` is the only switch for desktop-vs-Android automation and is wholly undocumented. Fix: complete the table with the correct names.

### L5 — STATUS.md "iOS → 90 tests" likely understated (verify) — CONFIRMED AS UNCERTAIN
`STATUS.md:13` claims `swift test → 90 tests`. The Swift test files contain **119** `func test` declarations (`apple/QuenderinKit/Tests/QuenderinKitTests/*.swift`; 120 incl. one in `INTEGRATION.md`). The gap may be legitimate (disabled/`measure`/perf variants or suite filtering), but the round 90 suggests a stale hand-count. Read-only — not asserting wrong; flag to re-derive from `swift test` output or state as approximate.

### L6 — LAUNCH_CHECKLIST website-deploy item — SOFTENED (draft overstated)
File: `LAUNCH_CHECKLIST.md:46-48`. The checklist says the deploy workflow "needs to live at `.github/workflows/`" and that pushing it requires a token with `workflow` scope. The workflow file does exist at `website/deploy/github-pages.yml`. **Refinement:** the checklist isn't claiming the file is missing — it's flagging that it isn't yet in the active `.github/workflows/` location (GitHub Pages only runs workflows from there). So this is a real, valid TODO, just imprecisely worded. Minor. Fix: name the source path (`website/deploy/github-pages.yml`) and reframe as "move/enable," not "create."

---

## What's solid (not one-sided) — CONFIRMED
- `docs/README.md`, `docs/ARCHITECTURE.md`, `docs/API.md`, `docs/BACKEND.md`, `docs/FRONTEND.md`, `docs/DEVELOPMENT.md` match the code on REST routes, the WS message catalog (`docs/API.md:71-95` vs `src/websocket/index.ts`), service map, and build/run scripts. `CONTRIBUTING.md` is consistent.
- `STATUS.md` is unusually honest (mock-vs-real engine, "11-model catalog … enforced in sync" via `shared/model-catalog.json`, measured-vs-estimated chip scores) — a model for the rest.
- `QUICKSTART.md:104-110` presets table (General 0.7 / Code Review 0.3 / Creative 0.9 / Tutor 0.5 / Summarizer 0.3) matches `src/services/presets.ts` exactly. FEATURES sections 6–9 (download resume, model lifecycle, port management) match the code.

---

## Root cause
Every CRITICAL/HIGH finding traces to one fossil: the project pivoted **away from a cloud/Ollama/OpenAI-provider design toward offline-only GGUF**, and the root marketing/setup docs + `ui/README.md` were never updated. The dead `src/config.ts` provider fields, `SECURITY.md`'s cloud language, `ui/README.md`'s connection wizard, and the Llama-only catalog are all artifacts of that abandoned design. `docs/` was migrated; the root files were not.

## Recommended next steps (highest leverage first)
1. **Rewrite or delete `ui/README.md`** (point to `docs/FRONTEND.md`) and **confirm-then-delete `ui/app.js`**. (C1)
2. **Rewrite `SECURITY.md`** to the real local-only threat model; remove rate-limiting/Ollama/cloud/Dependabot claims; if `quenderin.json` keeps secrets, **add it to `.gitignore`**. (C2)
3. **Strip the dead `quenderin.json`/provider story from `SETUP.md`** (or wire `loadConfig()` in). (C3)
4. **Regenerate every model table** (`FEATURES.md`, `QUICKSTART.md`, `TROUBLESHOOTING.md`) from `MODEL_CATALOG`/`shared/model-catalog.json`; ideally auto-generate. (C4)
5. **Delete invented WS message types** (`download_model`, `download_progress`, `switch_model`, `reset_settings`) from SETUP/FEATURES; point to `docs/API.md`. (C5)
6. **Fix the public-API docs**: `runAgentLoop(goal, emitter, attachments, maxSteps)` in ARCHITECTURE/BACKEND; `attachments` (not `history`) + "maxSteps ignored over WS" in `docs/API.md`; document `chat_response` `{message, meta, intent:string}`; fix the BACKEND `expression` tool name and add the 3 missing tools. (M1, M2, M3)
7. **Fix the no-op commands**: `PORT=` → `--port` (M6) and `LOG_LEVEL=` → `QUENDERIN_LOG_LEVEL=` (M6b); complete the `docs/DEVELOPMENT.md` env table incl. `TARGET_OS`/`QUENDERIN_LOG_LEVEL`. (L4)
8. **Scrub `RUN_GUIDE.md`** of the `s_avelova` absolute paths (M4); align Node to 20/22 and repoint `off-grid-mobile`→`apple/` in SETUP (L3); fix the real startup banner (M5) and voice log string (L1).
9. **Declare `docs/` authoritative** and collapse the four overlapping onboarding docs into one that links out (M8); bootstrap `docs/BUG_JOURNAL.md` (L2).
10. **Verify, don't assume**: re-derive the iOS test count from `swift test` (L5); repoint the LAUNCH_CHECKLIST deploy item at `website/deploy/github-pages.yml` (L6).

Note: this was a read-only audit — no files were modified.
