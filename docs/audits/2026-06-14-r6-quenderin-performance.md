---
title: Performance Audit (Verified) — Quenderin
repo: quenderin
lens: performance
date: 2026-06-14
round: 6
---

All sizes confirmed (react-syntax-highlighter 8.7M, refractor 2.8M, lucide-react 45M). M4 confirmed (`records.reverse()` at :167). No useMemo in GeneralChatArea or Metrics. 37 distinct exotic languages detected in the bundle from just a sample list — confirming the full Prism grammar set is bundled (C1).

I have verified every finding. Let me compile the final report.

---

# Performance Audit (Verified) — Quenderin

Repository: `/Users/svetlana/Documents/projects/quenderin`
Stack: Node.js/TypeScript backend (Express + `ws`), React 18 + Vite UI, Electron shell, optional native modules. Local-first offline AI agent targeting low-power hardware tiers (`embedded`/`constrained`).
Scope: performance only. Read-only audit — no files were modified. Every finding below was verified against the actual source; corrections to the draft are flagged inline.

## Verification summary

- **Confirmed as-written:** C1, C2, C3 (with one sub-bullet removed), H1, H2 (framing tightened), H3, H4 (framing tightened), H5, M1, M2, M3, M4, M5, M6, M7, L1, L3, L4, L5, L6.
- **Corrections made:** C3 lost one false sub-claim; H2 and H4 had their "every 2s / spins forever with no delay" framing tightened to match the real (debounced / backed-off) behavior; H4's fix references a method whose real signature is noted; L1's `data.reverse()` downgraded to a harmless smell.
- **False positives removed:** the C3 sub-bullet "`embeddingVector` is loaded but unused in `findSimilarGoal`" — see C3.
- **No net-new high-value findings** beyond the draft; one minor addition (L7) noted.

---

## CRITICAL

### C1. Frontend bundles all ~300 Prism languages — 1.1 MB single JS chunk — CONFIRMED
**File:** `ui/src/components/CodeBlock.tsx:3-4`
```ts
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism';
```
**Verified evidence:** `public/assets/index-oxnjuK6c.js` is a single file: **1,053,468 bytes raw / 343,131 bytes gzipped**. Grepping it confirms exotic grammars are present (`abap`, `cobol`, `fortran`, `verilog`, `vhdl`, `haskell`, `elixir`, `erlang`, `crystal`, `julia`, `nim`, `actionscript`, `arduino`, … — 37 distinct exotic languages from a sample list alone). On disk `react-syntax-highlighter` is 8.7 MB and `refractor` 2.8 MB; the full `Prism` build statically pulls every refractor grammar. `CodeBlock` is imported **eagerly** by `GeneralChatArea` (`ui/src/components/GeneralChatArea.tsx:6`), which renders on the default chat view — so lazy-loading other routes does not defer it.
**Why it matters:** This app explicitly tunes for `embedded`/`constrained` hardware. ~250+ unused grammars are the single largest first-paint liability.
**Fix:** Switch to `PrismLight` and `registerLanguage()` only the ~8 common langs; additionally `React.lazy()` the markdown renderer / `CodeBlock` so the highlighter is fetched only when a code fence first renders. Expected: highlighter contribution drops from ~500 KB raw to ~30–50 KB; gzipped main bundle well under 150 KB.

### C2. Shipped `public/` build has no code-splitting despite `manualChunks` config — CONFIRMED
**Files:** `ui/vite.config.ts:9-19`, `public/index.html`, `ui/src/App.tsx:15-18`
**Verified evidence:** `vite.config.ts` defines `manualChunks` for `react-vendor`, `markdown`, `syntax`, `icons`, and `App.tsx:15-18` wraps `Inspector`/`Docs`/`Metrics`/`SettingsArea` in `lazy()`. Yet `public/assets/` contains exactly **one** JS file (`index-oxnjuK6c.js`) and `public/index.html` references only `/assets/index-oxnjuK6c.js` — no vendor/markdown/syntax/icons chunks, no lazy-route chunks, no `modulepreload` links. The shipped artifact predates or collapsed the split.
**Why it matters:** All markdown, the syntax highlighter, all four lazy routes, and all of lucide-react load up-front. The authors' splitting/lazy work delivers zero benefit to end users today.
**Fix:** Rebuild (`cd ui && npm run build`), verify multiple hashed chunks land in `public/assets/` and `index.html` emits `modulepreload` for vendor chunks. Add a CI check that fails if `public/assets/*.js` collapses to a single file.

### C3. RAG self-correction runs a full embedding + linear similarity scan on every agent step — CONFIRMED (one sub-claim removed)
**Files:** `src/services/agent/promptBuilder.ts:15,21`, `src/services/memory.service.ts:223-253`, `src/services/agent.service.ts:223`
**Verified evidence:** `buildEnvironment` is called at `agent.service.ts:223`, inside `while (step < maxSteps && !isDone)` (loop opens at :167) — i.e. once per step. It calls:
- `findRelevantCorrections(textRepresentation)` → embeds the UI text via Xenova MiniLM (`embedText` → `pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2')`), then `fs.readFile` + `JSON.parse` of the entire `corrections.json` (up to `MAX_CORRECTIONS = 500` × 384-float vectors ≈ 1.5 MB) every call (`memory.service.ts:226-227`), then `cosineSimilarity` against all 500 vectors and a sort (`:234-240`).
- `findSimilarGoal(goal)` (`promptBuilder.ts:15`) → re-reads + parses `memory.json` every step (`memory.service.ts:161-162`).

**CORRECTION — false sub-claim removed:** The draft's bullet "The `embeddingVector` is loaded but unused in `findSimilarGoal`; skip vector deserialization there" is **wrong and removed**. `findSimilarGoal` reads `memory.json`, whose `TrajectoryEntry` type has only `{goal, actions, timestamp}` — no `embeddingVector` field. The `embeddingVector` lives only in `corrections.json`'s `CorrectionEntry`. `findSimilarGoal` never deserializes any vector.

**Why it matters:** Per step, on hardware already saturated by local LLM inference, this adds one ML embedding inference + a full file read/parse + an O(n·d) cosine scan (~192k float-mults), and re-allocates the whole vector array each parse.
**Fix:**
- Cache parsed `corrections.json` in RAM (writes already serialize through `withWriteLock`, so invalidate the cache on write) instead of re-reading per step.
- Cache `memory.json` similarly; `findSimilarGoal` is a trivial string match needing no per-step disk read.
- Skip the corrections RAG when the UI hash is unchanged (e.g. on retries where the screen is identical) — it's keyed on UI context anyway.

---

## HIGH

### H1. Double (nested) UI-idle wait — each step pays the idle-poll cost 2–3× and stacks 4+ waits per cycle — CONFIRMED
**Files:** `src/services/providers/android.provider.ts:117-143, 189-191, 145-187`, `src/services/agent/uiVerifier.ts:35-77`, `src/services/agent.service.ts:172,307`
**Verified evidence:** `AndroidProvider.getScreenContext()` calls `waitForUiIdle()` internally (`:191`) — up to `maxPolls = 10` iterations × `uiIdlePollMs`, each doing a `dump`+`pull` ADB round-trip. `UiVerifier.waitForIdle()` then calls `getScreenContext()` **inside its own stability loop** requiring `stableCount >= 2` (`uiVerifier.ts:47,61`), so it invokes `getScreenContext()` ≥2–3 times, each re-running the full inner 10-poll wait. Compounding: `agent.service.ts` calls `waitForIdle()` twice per step (`:172` pre, `:307` post), and `click`/`type`/`scroll`/`pressKey` each also call `waitForUiIdle()` after the input (`android.provider.ts:147,158,175,186`). A single click→settle→observe cycle stacks 4+ independent idle-wait loops.
**Why it matters:** Dominant per-step wall-clock latency (tens of seconds of pure ADB polling) and a flood of redundant `uiautomator dump` calls.
**Fix:** Make idle detection single-owner: either have `getScreenContext()` return one fresh snapshot (no internal idle loop) and let `UiVerifier.waitForIdle()` be the sole stability detector, or keep the provider's idle wait and have `UiVerifier` consume one snapshot without re-polling. Remove the per-input `waitForUiIdle()` calls in `click/type/scroll/pressKey` (the agent loop re-verifies afterward).

### H2. `SessionService` re-reads & parses every session file synchronously on each flush — CONFIRMED (framing tightened)
**Files:** `src/services/session.service.ts:205-228` (`flushNow` → `pruneOldSessions` → `listSessions:112-142`)
**Verified evidence:** `flushNow()` (`:205`) calls `pruneOldSessions()` (`:211`) → `listSessions()` (`:219`), which does `fs.readdirSync` + `fs.readFileSync` + `JSON.parse` of **every** session file (up to `MAX_SESSIONS = 100`, each up to `MAX_MESSAGES_PER_SESSION = 500`), all synchronously on the event loop, purely to count for pruning (`pruneOldSessions` early-returns when `summaries.length <= 100`).
**CORRECTION — framing:** The flush is **debounced**, not "every 2s continuously." `scheduleFlush()` (`:196-203`) sets the timer only if none is pending and clears it on fire, so a burst of messages produces one flush per `SESSION_FLUSH_INTERVAL_MS = 2000` window, not one every 2s indefinitely. The per-flush cost is still the full O(sessions × messages) sync read+parse for an almost-always-no-op prune.
**Why it matters:** Each flush during active chat blocks the event loop (sync FS) reading/parsing up to 100 JSON files, stalling WebSocket streaming.
**Fix:** Only prune when a new session is created (the only time the count grows), or keep an in-memory session count and skip `listSessions()` unless it crosses the cap. At minimum move the prune path to `fs.promises`.

### H3. Telemetry / memory / corrections do read-parse-rewrite-all on every write — CONFIRMED
**Files:** `src/services/metrics.service.ts:48-60`, `src/services/memory.service.ts:105-128, 130-156, 177-208`
**Verified evidence:** `appendMetrics` (`metrics.service.ts:48`) reads all of `telemetry.json` (cap 1000), parses, pushes one, and rewrites the whole array with `JSON.stringify(records, null, 2)`. `saveTrajectory`/`injectOverride` (`memory.service.ts:105,130`) do the same against `memory.json`. `saveCorrection` (`:177`) rewrites all of `corrections.json` (500 × 384-float vectors ≈ 1.5 MB) to persist one entry. The author already migrated *habits* to append-only NDJSON (`metrics.service.ts:25-26,73-79`) but left these three on read-modify-write-all.
**Why it matters:** O(n) disk write per append; pretty-print (`null, 2`) ~doubles bytes; corrections rewrites ~1.5 MB per entry. Slow and wear-inducing on Pi/SBC flash storage.
**Fix:** Convert telemetry, memory, and corrections to append-only NDJSON like habits. Compact lazily on read (as `getHabits` does, `:92-98`) or on a timer. Drop `null, 2` for machine-read files.

### H4. Background screenshot+diff+LLM daemon auto-starts for every server, regardless of device — CONFIRMED (framing tightened)
**Files:** `src/services/backgroundDaemon.service.ts:39-44, 61-105, 107-170`, `src/server.ts:119,128`
**Verified evidence:** `backgroundDaemon.start()` is called unconditionally at `server.ts:128`, regardless of `TARGET_OS` or whether a device exists. The loop calls `getScreenContext()` (`:111`), `parsePng` + full-frame `pixelmatch` over every pixel (`calculateVisualDiff:84-91`), and on `diffRatio > VISUAL_DIFF_THRESHOLD` (0.05) fires a full LLM vision inference (`:128-133`) sharing the single `LlmService` (which tracks a single `isGeneratingChat` flag — chat and daemon contend for one model).
**CORRECTION — framing:** The draft says the loop "keeps spinning forever" with no device. In fact, on each iteration the error is caught and the loop then sleeps `effectiveInterval` before continuing (`:154-168`), and the daemon has adaptive backoff (idle cycles → up to 3× the poll interval, `:162-167`). So it is not a tight no-delay spin — it is a **permanent polling loop that keeps running (and on Android with no device, keeps throwing-and-sleeping) forever**, with no terminal stop after repeated failures.
**Why it matters:** On a fresh install with no device, permanent throw/log/sleep churn. With a device attached, full-frame pixel-diff every 2–10 s plus possible LLM calls that contend with foreground chat for the one loaded model.
**Fix:** Don't auto-start; gate behind an explicit "passive observation" setting (the habit tracker it writes has no surfaced UI). Add a terminal stop after N consecutive `getScreenContext` failures instead of looping forever. Guard against concurrent LLM use before the daemon's `generateAction` — note the existing method is `llmService.isCurrentlyGenerating()` which returns `{ isGenerating, buffer }` (not a bare boolean), so check `.isGenerating`.

### H5. `pixelmatch` full-frame diff copies a fresh ~10 MB pixel buffer every tick — CONFIRMED
**File:** `src/services/backgroundDaemon.service.ts:72, 97`
**Verified evidence:** `diffScratch` is pre-allocated (good), but `this.lastPixelData = Buffer.from(currentPng.data)` runs on every diff (`:97`) and on first/dimension-change (`:72`). For a 1080×2400 RGBA frame that's ~10 MB copied and discarded each cycle, on top of `PNG.parse` allocating the decoded buffer.
**Why it matters:** Recurring 10 MB allocations every 2–10 s reintroduce the GC churn the scratch buffer was meant to avoid; retained `lastPixelData` doubles resident screenshot memory.
**Fix:** Ping-pong two pre-allocated pixel buffers (swap `current`/`last` references). `pixelmatch` reads both inputs without mutating, so alternate which buffer the next PNG decodes into.

---

## MEDIUM

### M1. `GeneralChatArea` re-derives the chat list (+ reverse scan) and re-highlights on every render/token — CONFIRMED
**File:** `ui/src/components/GeneralChatArea.tsx:62-63`
```ts
const chatLogs = logs.filter(l => ['chat','chat_response','error'].includes(l.type));
const lastUserMessage = [...logs].reverse().find((l) => l.type === 'chat')?.message;
```
**Verified evidence:** Both run every render with no `useMemo` (confirmed zero `useMemo` in the file). During streaming, `useAgentSocket.ts:95-104` mutates the last log entry per `chat_stream` token, re-rendering the parent — so each token re-`filter`s and re-`[...logs].reverse()`s the up-to-300-entry array and re-runs `ReactMarkdown` + `CodeBlock` over the whole growing message.
**Fix:** `useMemo` `chatLogs` keyed on `logs`; compute `lastUserMessage` with a backward `for` loop (no copy); `React.memo` a per-message component keyed on `log.id` + `message.length` + `isStreaming` so completed messages don't re-highlight while a new one streams; optionally coalesce token updates per frame.

### M2. `/health` does 11 synchronous `existsSync` per poll; `/api/models/catalog` uses sync `existsSync` inside `Promise.all` — CONFIRMED
**Files:** `src/routes/health.ts:121-123`, `src/app.ts:107-117`
**Verified evidence:** `commitSha` is resolved once at module load (`health.ts:28` — draft correctly credits this). But `/health` (`:123`) calls `MODEL_CATALOG.some(m => fs.existsSync(modelPath(m.id)))` — up to 11 sync stat calls per poll, and the UI polls `/health` on mount (`App.tsx:320`). `/api/models/catalog` (`app.ts:108-116`) wraps the catalog in `Promise.all` but uses sync `fsSync.existsSync` (`:110`) inside, so the parallelism is illusory for the existence check.
**Fix:** Cache `isBrainInstalled` with a short TTL (~5 s) or invalidate on model download/delete. Switch `/api/models/catalog` to `fs.promises.access` so the `Promise.all` actually parallelizes.

### M3. `Sidebar` refetches all sessions (full server-side disk scan) on every view change — CONFIRMED
**File:** `ui/src/components/Sidebar.tsx:40-47`
**Verified evidence:** `useEffect(..., [currentView])` calls `GET /api/sessions` on every tab switch → `listSessions()` → sync read+parse of all session files (`session.service.ts:112-142`).
**Fix:** Fetch on mount (and after a new conversation), not per `currentView`. Server-side, store a lightweight index (title/updatedAt/count) instead of parsing full message arrays to count them.

### M4. `MemoryService.findSimilarGoal` mutates the records array with `.reverse()` — CONFIRMED
**File:** `src/services/memory.service.ts:167`
```ts
const match = records.reverse().find(...)
```
**Verified evidence:** `records` is freshly parsed each call so the mutation isn't shared today, but `.reverse()` is an O(n) in-place reversal purely to iterate newest-first.
**Why it matters:** Minor now; becomes a real correctness bug the moment C3/H3's caching holds the parsed array. Fix before caching.
**Fix:** Iterate backwards with a `for` loop, or use `findLast`.

### M5. `App.tsx` auto-opens the unmemoized `Inspector` (100–400 positioned divs) on every `currentUI` change — CONFIRMED
**Files:** `ui/src/App.tsx:405-410`, `ui/src/components/Inspector.tsx:55-78`
**Verified evidence:** `useEffect([currentUI, isInspectorOpen, status])` (`App.tsx:406`) opens the Inspector; `currentUI` is replaced on every `observe` event (`useAgentSocket.ts:88`). `Inspector` is **not** memoized (no `React.memo`) and `currentUI.map` renders an absolutely-positioned `<div>` per node, recomputing `left/top/width/height` percentages inline (`Inspector.tsx:55-68`), each with a hover tooltip and `transition-all`, with no virtualization.
**Fix:** `React.memo` the Inspector and the per-node element; key the mapped JSX on the backend-computed UI hash (`state.hash` exists in the agent loop) so it only re-renders when the node set actually changes.

### M6. WebSocket tool-call suppression is O(n²) per token in the unclosed-tag case — CONFIRMED
**File:** `src/websocket/index.ts:234-268`
**Verified evidence:** Each streamed token appends to `streamBuf` (`:236`), then runs `while (streamBuf.includes(TOOL_CLOSE))` with `indexOf`/`lastIndexOf`/`slice` (`:239-245`), plus an `indexOf(TOOL_OPEN)` (`:248`) and a tail-prefix scan (`:257-264`). If a `<tool_call>` opens but never closes, `streamBuf` is held (`:252`) and grows unbounded; every subsequent token re-scans the whole accumulated string → O(n²) over the response length.
**Fix:** Track parser state (`inToolCall` flag + match offset) across tokens; scan only the newly appended slice.

### M7. Per-token `JSON.stringify` + `safeSend`, and a full client-side array copy per token — CONFIRMED
**Files:** `src/websocket/index.ts:251,260,267`, `ui/src/hooks/useAgentSocket.ts:95-104`
**Verified evidence:** Each token is sent as its own `JSON.stringify({type:'chat_stream', text})` + `safeSend` (`:251/260/267`). The client does a full `[...prev]` array spread + object spread per token (`useAgentSocket.ts:96-99`).
**Fix:** Coalesce tokens into ~30–60 ms batches before sending (perceived smoothness unchanged, message count drops 10–50×); compounds with M1's per-token re-render fix.

---

## LOW

### L1. `Metrics.tsx` recomputes KPIs every render without `useMemo` — CONFIRMED (one sub-claim downgraded)
**File:** `ui/src/components/Metrics.tsx:128-146`. `filter`/`reduce` over up to 1000 rows on each render (zero `useMemo` in file). Low impact — the view is static once loaded; wrap in `useMemo([metrics])`.
**CORRECTION:** the draft flags `data.reverse()` at `:121` as a mutation concern — it mutates the array returned by `res.json()`, which is freshly allocated and not shared, so it's harmless (cosmetic only). The `metrics.slice(0,20).reverse()` at `:142` operates on a fresh slice, also harmless.

### L2. `hashUiState` SHA-256 over concatenated element strings every idle settle — CONFIRMED
**File:** `src/services/agent/uiVerifier.ts:28-33`. Builds a joined string then SHA-256s it every `waitForIdle`. Fine per step; a cheaper FNV/rolling hash would suffice (no cryptographic strength needed for change detection).

### L3. `voice.service.ts` permanently holds a 320 KB Int16Array even when voice is unused — CONFIRMED
**File:** `src/services/voice.service.ts:29-30`. `MAX_RECORDING_SAMPLES = 16000 * 10 = 160,000` samples × 2 bytes = **320 KB** allocated at construction (`new Int16Array(...)`), held for the service lifetime. Minor; on `embedded` tier, allocate lazily on first `RECORDING` transition and release on return to `IDLE`.

### L4. `cleanupOrphanedTempFiles` reads the entire system temp dir — CONFIRMED
**File:** `src/server.ts:39-62`, scheduled every `TEMP_CLEANUP_INTERVAL_MS = 30 min` (`:150`). `fs.readdir(os.tmpdir())` then `fs.stat` each matching file; the prefix filter (`:46-52`) runs before stat (good). On shared/CI machines `/tmp` can hold thousands of files, so the `readdir` is O(all-tmp-files), but at 30-min cadence the impact is low. Acceptable.

### L5. `lucide-react` is 45 MB on disk; verify tree-shaking after C2 — CONFIRMED
**Files:** UI imports use named imports (correct; tree-shakeable under Vite), but because C2 broke splitting, confirm only the ~30 used icons land in the bundle once rebuilt. Inspect the `icons` chunk size after C2's fix.

### L6. `App.tsx` keeps polling timers + WS reconnect running on backgrounded tabs — CONFIRMED
**Files:** `ui/src/App.tsx:265-327` (`/health` once on mount, `/ready` on exponential backoff), `useAgentSocket.ts:163-191` (WS reconnect with backoff + jitter). Reasonable design; consider pausing polls on `document.hidden`.

### L7. (Minor addition) `Inspector` and `GeneralChatArea` both do `[...logs].reverse().find(...)` per render
**Files:** `Inspector.tsx:13`, `GeneralChatArea.tsx:63`. Same O(n) array-copy-then-reverse pattern as M4, on the client, on every render. Folds into the M1/M5 memoization fixes — replace with a backward `for` loop or `findLast`.

---

## Summary of priorities

| ID | Severity | One-line | Status | Effort |
|----|----------|----------|--------|--------|
| C1 | Critical | Full Prism bundles ~300 langs → 1.1 MB JS (343 KB gz); use `PrismLight` + register ~8 | Confirmed | Low |
| C2 | Critical | Shipped `public/` has no code-splitting despite config; rebuild + CI guard | Confirmed | Low |
| C3 | Critical | RAG embed + 500-vector scan + file re-read per step; cache in RAM | Confirmed (1 sub-claim removed) | Med |
| H1 | High | Nested/redundant UI-idle waits stack 4+ poll loops per step | Confirmed | Med |
| H2 | High | `SessionService` sync-reads ALL session files on each (debounced) flush | Confirmed | Low |
| H3 | High | Telemetry/memory/corrections read-rewrite-all per write; go NDJSON | Confirmed | Med |
| H4 | High | Background screenshot+diff+LLM daemon auto-runs forever (backs off, never stops) | Confirmed | Med |
| H5 | High | ~10 MB pixel buffer copy per daemon tick; ping-pong buffers | Confirmed | Low |
| M1 | Medium | `GeneralChatArea` re-filters/reverses logs + re-highlights per token | Confirmed | Med |
| M2 | Medium | `/health` 11 sync `existsSync` per poll; catalog sync inside `Promise.all` | Confirmed | Low |
| M3 | Medium | Sidebar refetches all sessions (full disk scan) per tab switch | Confirmed | Low |
| M4 | Medium | `findSimilarGoal` `.reverse()` mutates parsed array (bug once cached) | Confirmed | Low |
| M5 | Medium | Inspector renders 100–400 unmemoized positioned divs per observe | Confirmed | Med |
| M6 | Medium | WS tool-call suppression O(n²) per token on unclosed tag | Confirmed | Low |
| M7 | Medium | Per-token stringify/send + client O(n) array copy; batch tokens | Confirmed | Low |
| L1 | Low | `Metrics` recomputes KPIs without `useMemo` (reverse mutation harmless) | Confirmed | Low |
| L2 | Low | `hashUiState` crypto SHA-256 per settle; FNV suffices | Confirmed | Low |
| L3 | Low | Voice holds 320 KB Int16Array permanently | Confirmed | Low |
| L4 | Low | Temp cleanup reads whole `/tmp` every 30 min | Confirmed (acceptable) | Low |
| L5 | Low | lucide-react 45 MB on disk; verify tree-shake after C2 | Confirmed | Low |
| L6 | Low | Polls keep firing on backgrounded tab | Confirmed | Low |
| L7 | Low | Repeated `[...logs].reverse().find` per render in Inspector/Chat | Added | Low |

## Recommended next steps

1. **Ship C1 + C2 together (highest ROI, lowest effort).** Switch `CodeBlock.tsx` to `PrismLight` with ~8 registered languages, `React.lazy()` the markdown renderer, then rebuild the UI and confirm `public/assets/` produces multiple hashed chunks with `modulepreload`. Add a CI guard that fails when the build collapses to a single JS file. These two together likely cut first-paint download 60–75% on the exact low-power devices the codebase targets.
2. **Fix the agent-mode runtime hot path: C3 then H1.** Cache parsed `corrections.json` and `memory.json` in RAM (invalidate on write, which already goes through `withWriteLock`), and skip the corrections RAG when the UI hash is unchanged. Then collapse the nested idle waits to a single owner and drop the per-input `waitForUiIdle()` calls. Apply M4's `findLast`/backward-loop fix **before** caching, or the cache will be corrupted by the in-place `.reverse()`.
3. **Stop the always-on daemon (H4) and de-thrash persistence (H3, H5).** Gate `backgroundDaemon.start()` behind an explicit setting, add a terminal stop after N consecutive failures, and guard against concurrent LLM use via `isCurrentlyGenerating().isGenerating`. Ping-pong the pixel buffers (H5). Migrate telemetry/memory/corrections to append-only NDJSON like habits already are (H3).
4. **Batch the session/flush and health work (H2, M2, M3).** Prune sessions only on session creation (or via an in-memory count); cache `isBrainInstalled` with a short TTL; make `/api/models/catalog` use `fs.promises.access`; fetch sessions in the Sidebar on mount, not per view change.
5. **Smooth streaming (M1, M5, M6, M7).** Memoize `chatLogs` and per-message rendering; memoize the Inspector keyed on the UI hash; convert the WS tool-call suppressor to incremental parser state; coalesce streamed tokens into ~30–60 ms batches on the server.
6. **Low-priority cleanups (L1–L7)** are safe to batch into a single quality pass once the above land; none are urgent.

No files were modified during this audit.
