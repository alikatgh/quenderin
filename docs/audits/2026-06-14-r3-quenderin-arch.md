---
title: Architecture Audit (Verified) — Quenderin
repo: quenderin
lens: arch
date: 2026-06-14
round: 3
---

C2 fully confirmed: the UI only does download/delete/catalog (SettingsArea.tsx lines 149-171). There is NO "pin/select/activate model" call anywhere — `activeModel` in the UI is read-only display from health data. WS handlers (start/chat/settings_update/preset_switch/voice) have no `switch_model`. So `switchModel` is genuinely unreachable, and even if called, `getModelAndContext` would override the choice via `selectBestModel`. The "picker pins a model" capability does not exist. Confirmed.

I have verified every finding. Here is my final report.

---

# Architecture Audit (Verified) — Quenderin (`/Users/svetlana/Documents/projects/quenderin`)

Read-only audit. I independently verified every finding in the draft against the source. Verdict per finding is marked **[CONFIRMED]**, **[CONFIRMED w/ correction]**, **[PARTLY WRONG]**, or **[FALSE POSITIVE]**. Two draft claims were materially wrong (H4 overstated; H5 had fabricated string-match examples) and are corrected below. One new low-severity finding (N1) was added. No files were modified.

Scope: desktop TS backend (`src/`), React UI (`ui/`), Electron wrapper, build/packaging, and coupling to `apple/`/`android/`.

Overall: service decomposition and DI are genuinely good. The real issues cluster in (1) a build/serve/package dir mismatch, (2) public-contract-vs-executed-code drift (model picker, agent action verbs), and (3) process-global singletons making the server single-session.

---

## CRITICAL

### C1. UI build output, served path, and packaged path are three different dirs — packaged app ships no servable UI [CONFIRMED]
- `ui/package.json:8`: `build` = `tsc -b && vite build && rm -rf ../public && cp -r dist ../public` → artifacts land in repo-root `public/`.
- `src/app.ts:70-75`: compiled mode resolves `publicPath` = `path.join(__dirname,'..','..','public')`. With `tsconfig.json` `rootDir:"./"`, `outDir:"./dist"`, `app.ts`→`dist/src/app.js`, so `dist/src/../../public` = **repo-root `public/`**. Confirmed.
- `electron-builder.yaml:46-50`: `files` = `dist/**`, `node_modules/**`, **`ui/dist/**`**, `package.json`. `public/` is NOT listed → excluded from the package (`asar: false`, so this is a real on-disk exclusion). `ui/dist/**` IS packaged but **nothing in `src/` references `ui/dist`** (grep confirms zero references).
- Root `package.json:29-30`: `build` = `build:tsc` = `tsc` only. `electron:build` = `tsc && electron-builder`. **No script runs the UI build.** `.github/workflows/ci.yml` `Build` step runs only `npm run build` (`tsc`). So `public/` is a frozen committed snapshot (`git ls-files` shows `public/assets/index-oxnjuK6c.js` etc. tracked); `ui/dist/` is empty/untracked.

Net: `npm run electron:build` (a) never rebuilds the UI, and (b) packages `ui/dist` (which nothing serves and which the build never populated) while the server reads `public/` (which is excluded from the package). Dev works only because Vite proxies `:5173→:3000` and the committed `public/` snapshot happens to exist.
**Fix:** pick ONE dir. Set Vite `build.outDir:'../public'`, drop the `cp` hack; make root `build` = `npm --prefix ui run build && tsc`; add `public/**` to electron-builder `files` (and drop the unused `ui/dist/**`). Add a CI assertion that served dir == packaged dir.

### C2. Desktop "model picker" cannot pin a model — engine always auto-loads the *smallest* downloaded model [CONFIRMED]
- `getModelAndContext()` (`llm.service.ts:342`) unconditionally calls `selectBestModel(...)` at `:365` and then overwrites `this.activeModelId = selected.entry.id` at `:389`. Any previously-set `activeModelId` is discarded.
- `switchModel()` (`:317`) sets `this.activeModelId = modelId` (`:327`) then calls `getModelAndContext()` (`:329`) — which immediately overrides it. So even calling `switchModel` does not pin the model.
- `switchModel` is **unreachable**: grep shows only its own definition; no REST route, no WS handler (`websocket/index.ts` handles only `start/chat/settings_update/preset_switch/manual_voice_*`). The UI only calls `/api/models/download|catalog|DELETE` (`SettingsArea.tsx:149-171`); `activeModel` in the UI (`App.tsx:230,272`) is read-only display from health data. **No "pin/select/activate model" path exists anywhere.**
- `selectBestModel` (`:105-122`) re-sorts `MODEL_CATALOG` **smallest→largest** (`:107`, comment "responsiveness first") and returns the first that fits — so with both 1B and 14B downloaded and fitting, it always returns 1B, contradicting the catalog's "best → smallest" ordering comment (`constants.ts:62`).
- `LLM_MODEL_PATH` (`constants.ts:284`) and its "user last selected" comment (`:280-282`) are dead — grep confirms it is defined but read nowhere.
**Fix:** honor `activeModelId` in `getModelAndContext()` (load the pinned entry; fall back to `selectBestModel` only when unset/doesn't fit). Expose `switchModel` via WS/REST. Delete `LLM_MODEL_PATH` or use it.

### C3. Agent system prompt advertises actions the executor cannot perform — `back`/`home`/`enter`/`swipe` are unreachable [CONFIRMED]
- `SYSTEM_PROMPT` (`agent.service.ts:24-27`) tells the model to emit `{"action":"swipe",x1,y1,x2,y2}`, `back`, `home`, `enter`.
- `AgentAction.action` (`types/index.ts:53`) = `'click' | 'input' | 'scroll' | 'done'` only.
- `actionExecutor.execute` (`actionExecutor.ts:33-112`) handles only `done/click/input/scroll`; everything else hits `emit('error', 'Unknown action type: ...')` (`:111`).
- Both providers implement `pressKey` (Android `:178` maps back→4/home→3/enter→66; Desktop `:136` maps back→escape/home→command) but the **executor never calls `pressKey`** — the capability is unreachable from the loop.
- `swipe` coords are dropped: the JSON path keeps unknown keys but the executor ignores them; the XML fallback parser (`agent.service.ts:261-268`) extracts only `id/text/x/y`, never `x1/y1/x2/y2`.

Guaranteed recurring failed steps on back/home/form-submit/swipe.
**Fix:** either remove the unsupported verbs from the prompt, or add them to `AgentAction`, route `back/home/enter` through `pressKey`, add a provider `swipe(...)` method, and extend both parsers to capture `x1..y2`.

---

## HIGH

### H1. Server is structurally single-session/single-user via process-global singletons [CONFIRMED, with line correction]
Services are created once in `server.ts:109-121` (draft said 113-121) and shared by all WS clients + the voice trigger.
- `AgentService._isRunning` is a single instance flag (`agent.service.ts:65,108`). The voice trigger (`server.ts:134`) and a UI `start` (`websocket/index.ts:205`) both call `runAgentLoop` on the same object; the second is silently dropped (`agent.service.ts:108-110`). Two tabs cannot run independent agents. (Note: the per-`start` `AgentEventEmitter` IS per-connection — `websocket/index.ts:175` — but the shared `_isRunning` is the bottleneck.)
- `WebSocketManager.activeWs` (`websocket/index.ts:30`) keeps only the latest socket.
- `generalChat` uses a single `generalChatSession` + `isGeneratingChat` (`llm.service.ts:137-138`); concurrent chats from two clients share one session.
- `SessionService`'s `startSession()` fires on every new WS connection (`websocket/index.ts:126`), so a second tab hijacks the first's "current session."

Defensible for a single-window Electron app, but it's an undeclared invariant.
**Fix:** document the single-session invariant loudly, OR scope state per-connection; at minimum reject/queue overlapping agent runs with a user-visible message instead of the silent drop.

### H2. WebSocket server upgrades on ANY path; `/ws` contract is honored only by accident [CONFIRMED]
- UI connects to `…/ws` (`useAgentSocket.ts:56`); Vite proxies `/ws` (`vite.config.ts:32`).
- `new WebSocketServer({ server })` (`websocket/index.ts:58`) has **no `path` option** → upgrades any path. Origin is checked (`:98`) but path is not.
**Fix:** `new WebSocketServer({ server, path: '/ws' })`.

### H3. Listener-accumulation papered over with `setMaxListeners(30)` [CONFIRMED]
`websocket/index.ts:63-65` raises the ceiling to 30 on `llmService`/`voiceService`/`deviceProvider`. Each connection registers `action_required`/`model_download_progress` handlers on long-lived singletons; cleanup relies on `ws.on('close')` (`:326-339`) plus a single-slot stale-handler guard (`activeActionRequiredHandler`/`activeDownloadProgressHandler`, `:33-34, 108-115`). Because only the single most-recent handler pair is tracked, rapid reconnects that don't fire `close` in order can still orphan listeners — which is exactly what the 30 ceiling masks.
**Fix:** per-connection cleanup array scoped to the socket lifetime; remove the ceiling bump so leaks resurface.

### H4. `runToolLoop` is dead, but `toolLoop.ts` itself is NOT dead — tool-loop logic is duplicated in 2 live places, not 3 [CONFIRMED w/ correction — draft overstated]
Correction to the draft: `toolLoop.ts` is **imported and used** — `llm.service.ts:46` imports `hasToolCalls/parseToolCalls/stripToolCalls/formatToolResults` from it and uses them at `:954-983`. So the module is alive; only the `runToolLoop` *function* (`toolLoop.ts:67`) is dead (grep: only its own definition).
What IS true:
- `runToolLoop` (bounded to `MAX_ITERATIONS=3`) is never called — dead.
- `generalChat` (`llm.service.ts:949-985`) re-implements the loop inline as a **single round** of tool calls (one re-prompt), diverging from the dead 3-iteration `runToolLoop`.
- Stream-level tool-call suppression is independently re-implemented in `websocket/index.ts:230-268`.
So "how a tool call is detected/stripped/executed" lives in 2 live, subtly-divergent spots (inline single-round vs. the dead 3-round helper), plus a third copy of stream-suppression.
**Fix:** route `generalChat` through `runToolLoop` (or delete it), keep stream-suppression in exactly one layer.

### H5. Safety blocklist is a 5-word English substring list — the only gate for autonomous OS control [CONFIRMED; draft's string-match examples were wrong and are removed]
`actionExecutor.ts:12` `BLOCKLIST = ['pay','delete','password','buy','confirm purchase']`, matched by case-insensitive `includes` over element `text`/`contentDesc`/input text (`:16-31`).
Correction: the draft's examples were fabricated — `includes('pay')` does **not** match "display"/"okay", and there is no live "Deleted items" path. The real, verifiable weaknesses stand: substring matching over-blocks (`'pay'` matches "payee"/"repay"/"payment"; `'delete'` matches any "Delete" button incl. benign ones) and under-blocks paraphrases/non-English ("send money", "transfer", "wipe", "purchase"). It is also moot for `back/home/enter` since those never execute (C3). For a product pitched on autonomous device control, this deserves a structured, locale-aware, default-deny policy on financial/credential surfaces.
**Fix:** replace with a configurable, categorized policy; do not rely on substring `includes`.

### H6 (was M5/part of H5 in draft). Two owners of one data store + a mutex bypass [CONFIRMED — promoted, was H5 in draft]
- **Notes:** `app.ts:248-299` (`/api/notes` GET/GET-one/DELETE) reads/writes `~/.quenderin/notes` directly with `path.basename` sanitization, while `tools/handlers.ts:12-147` (`note_save`/`note_list`) owns the same dir with *different* regex sanitization (`:119`). Two owners, two sanitizers.
- **Memory:** `app.ts:303-328` parses/overwrites `~/.quenderin/memory.json` directly (`fs.readFile`/`fs.writeFile(memPath,'[]')`), **bypassing `MemoryService.withWriteLock`** (`memory.service.ts:64-74`). A `DELETE /api/memory/trajectories` can interleave with `saveTrajectory`/`injectOverride` (both lock-guarded read-modify-write at `:107,132`) and corrupt/clobber the file. Real single-writer-invariant violation.
- This is a layering violation: HTTP routes do filesystem + business logic directly, bypassing the service layer.
**Fix:** move notes + memory file access behind `MemoryService`/a `NotesService`; routes call services only.

---

## MEDIUM

### M1. Cross-platform model catalog is hand-triplicated (TS + Swift + Kotlin); parity guard covers only a subset [CONFIRMED]
`scripts/check_catalog_parity.py` asserts only `{id, paramsBillions, quantization}` parity across `src/constants.ts` / `apple/.../ModelCatalog.swift` / `android/.../ModelCatalog.kt`. Its own docstring states it does **NOT** catch `label/filename/url/ramGb` drift or recommender-threshold drift (`getRecommendedModelIdForTotalRam` in TS vs the per-platform selectors). A wrong `url` ships a broken per-platform download with no guard.
**Fix:** extend the parity check to all catalog fields; treat `shared/model-catalog.json` as the build-time source the platforms generate/validate against, not a subset checksum.

### M2. `getHardwareProfile()` captured as module-load-time `const HW` in 6 modules [CONFIRMED]
`const HW = getHardwareProfile()` at module top in `llm.service.ts:57`, `agent.service.ts:14`, `backgroundDaemon.service.ts:11`, `agent/uiVerifier.ts:10`, `tools/registry.ts` (per draft), `providers/android.provider.ts:10`. The profile is memoized and env overrides are applied inside detection, so it works — but it hard-binds tuning to import order and makes those modules untestable with a different tier without module-cache surgery.
**Fix:** read `getHardwareProfile()` at call sites (already memoized) or inject the profile.

### M3. Dead modules / legacy types contradicting the offline thesis [CONFIRMED — all four verified dead]
- `src/services/daemon.service.ts` (`DaemonService`, ~99 LOC) — never imported (only `BackgroundDaemonService` is used; grep confirms). Carries its own `hashUiState` (`:47`), duplicating `uiVerifier.ts:28`.
- `src/config.ts` (`loadConfig`/`saveConfig`/`createDefaultConfig`/`QuenderinConfig`) — never imported. Its `provider?: 'ollama'|'openai'|'auto'|'gguf'` + `apiKey`/`baseURL` (`:7-10`) directly contradict the offline/no-API-key thesis in `docs/ARCHITECTURE.md`.
- `src/types.ts` (Ollama types + `QuenderinError`/`ConfigError`/`ProviderError`/`GenerationError`) — never imported; coexists confusingly with the real `src/types/index.ts`.
- `ILlmProvider.generateCode` (`types/index.ts:47`) + `LlmService.generateCode` (`llm.service.ts:813`) — no caller (grep: only interface + impl).
**Fix:** delete the four dead units per the project's Delete Audit Protocol (CLAUDE.md §1). `config.ts` is the most misleading — it implies a cloud-provider path that doesn't exist.

### M4. `parseUI` is Android-XML-shaped; desktop perception is degraded-by-design but leaks through the shared interface [CONFIRMED]
`DesktopProvider.getScreenContext()` returns `xml: ""` (`desktop.provider.ts:153`). On desktop, `uiVerifier.waitForIdle` calls `parseUI("")` → 0 elements, which is `< 5`, so it **always** drops into the OCR vision fallback (`uiVerifier.ts:88`), and `promptBuilder.buildEnvironment` instructs the model to output raw `x/y` (`promptBuilder.ts:30`). The `IDeviceProvider.getScreenContext(): {xml, screenshotPath}` contract pretends both platforms produce an XML tree; desktop cannot, so callers must "know" desktop is screenshot-only.
**Fix:** make perception mode explicit in the contract (e.g. `{ tree?: UIElement[]; screenshotPath: string; mode: 'tree' | 'vision' }`) instead of smuggling it through an empty string + element-count heuristic.

---

## LOW

### L1. Four `~/.quenderin/` stores, four different persistence strategies [CONFIRMED]
`MetricsService`: NDJSON-append for habits (`metrics.service.ts:75`) vs read-modify-write JSON for telemetry (`:50-56`). `MemoryService`: full-rewrite JSON behind a mutex (`memory.service.ts`). `SessionService`: per-file JSON with debounced flush. No shared convention.
**Fix:** small `JsonStore`/`NdjsonStore` utility.

### L2. `scroll` can't express horizontal, but prompt/parser carry `left`/`right` [CONFIRMED]
`IDeviceProvider.scroll` is `'up'|'down'` (`types/index.ts:41`); `actionExecutor.ts:101-103` explicitly errors on left/right; `ParsedAgentAction.direction` (`agent.service.ts:55`) and `AgentAction.direction` (`types/index.ts:59`) advertise all four. Same drift family as C3.

### L3. `isAllowedLocalOrigin` implemented twice, identically [CONFIRMED]
`app.ts:37-45` (CORS) and `websocket/index.ts:85-93` (WS). Extract to one shared helper.

### L4. `errCode`/`getErrorCode` helper duplicated in 4 spots [CONFIRMED]
`llm.service.ts:52`, `websocket/index.ts:159`, inline in `backgroundDaemon.service.ts:155` and `daemon.service.ts:88` (the latter dies with M3).

### L5. No `docs/BUG_JOURNAL.md` despite the project's own mandate [CONFIRMED]
`docs/audits/` has three reviews dated 2026-06-14, but `docs/BUG_JOURNAL.md` is absent and CLAUDE.md/global rules require it. The C2/C3/H4 "public contract diverges from executed code" class is exactly the pattern a journal's "scan first" section should capture.

### N1 (NEW). `model_download_progress` event type omits `modelId` that the emitters send [CONFIRMED — low impact]
`AgentEvents.model_download_progress` is typed `payload: { progress: number }` (`types/index.ts:35`), but `LlmService` emits `{ progress, modelId }` (`llm.service.ts:669,776`). The UI consumes only `data.data.progress` (`useAgentSocket.ts:145`), so there's **no runtime bug today** — but the type under-describes the payload, so per-model progress UI can't be built type-safely and a future consumer would see `modelId` as `never`.
**Fix:** add `modelId` to the event type (or have emitters stop sending it). Trivial.

---

## What's solid (not one-sided)
- Clean constructor DI in `server.ts`/`index.ts`; the agent loop and daemons depend on `ILlmProvider`/`IDeviceProvider`, not concretes.
- Centralized limits/thresholds in `constants.ts`; a single memoized `HardwareProfile` instead of scattered arch checks.
- Strong `LlmService` lifecycle hygiene: idle unload, memory-pressure monitor (`:183-209`), abort-based timeouts, GPU→CPU and flash-attn→reduced-context fallback chains (`:435-549`), download resume support.
- Careful resource cleanup: screenshot unlinking in `uiVerifier`/`agent.service`/`backgroundDaemon`, NDJSON for habits to avoid heap thrash, pre-allocated pixelmatch scratch buffer, `.unref()` on all timers.
- Real operability surface: `readiness.service` + `/ready` + health wiring.

---

## Recommended next steps (priority order)
1. **C1** — unify the UI build/serve/package dir and wire the UI build into `build`/CI (today the packaged app ships no servable UI).
2. **C2** — make `getModelAndContext` honor `activeModelId`, and expose `switchModel` via WS/REST so the picker is real; fix the smallest-vs-best selection; delete `LLM_MODEL_PATH`.
3. **C3 / L2** — reconcile prompt ↔ `AgentAction` ↔ executor ↔ provider: wire `back/home/enter` through `pressKey`, add a `swipe` method + parser fields, or drop the verbs.
4. **H1/H2/H3** — declare or enforce the single-session invariant (reject overlapping runs visibly); scope WS to `/ws`; scope listeners per-connection and drop `setMaxListeners(30)`.
5. **H6** — route notes + memory file access through services to restore `withWriteLock`'s single-writer guarantee.
6. **H4/H5/M3** — collapse the tool-loop into `runToolLoop` (or delete it); replace the substring blocklist with a structured policy; delete dead `config.ts`/`types.ts`/`daemon.service.ts`/`generateCode` per the Delete Audit Protocol.
7. **M1/M2/M4/L1/L3/L4/N1/L5** — extend catalog parity to all fields; read `getHardwareProfile()` at call sites; make perception-mode explicit; add shared persistence + origin + errCode helpers; widen the `model_download_progress` type; bootstrap `docs/BUG_JOURNAL.md` (`/init-bug-journal`) and seed it with the "contract-vs-executed-code" pattern.

Summary of changes vs. the draft: H4 corrected (toolLoop.ts is used; only `runToolLoop` is dead — 2 live duplicates, not 3); H5 fabricated string-match examples removed and the finding kept on its valid basis; the notes/memory store-ownership issue promoted to HIGH (H6) since it includes a real mutex-bypass corruption window; H1 line reference corrected to `server.ts:109-121`; new low finding N1 added. All other findings independently CONFIRMED at the cited file:line. No false positives requiring deletion.
