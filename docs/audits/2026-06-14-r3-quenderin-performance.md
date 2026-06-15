---
title: Performance Audit (Verified) — Quenderin
repo: quenderin
lens: performance
date: 2026-06-14
round: 3
---

L2 confirmed precisely. Note: `recordedFrames` passed to `writeWavFile` is the trimmed recording (line 159 `recordedFrames`), not the full 160k allocation, so the loop runs over actual recorded samples, not always 160k. The 320KB allocation per instance is one-time (constructor), not per-recording. Minor correction to L2.

I now have enough to finalize. Let me verify one more thing for M3/H3 — whether `appendMetrics` (telemetry) is the per-run write and confirm the corrections `null, 2` pretty-print. Both confirmed from earlier reads (memory.service line 201 `JSON.stringify(records, null, 2)`, metrics line 56 `JSON.stringify(records, null, 2)`).

I have verified all findings. Let me compile the final report.

The draft mentions an "H6" in the highest-leverage section that was never defined as a standalone finding (it's folded into C3). I'll keep the syntax-highlighter as part of C3.

Here is the final verified report:

# Performance Audit (Verified) — Quenderin

Read-only audit of `/Users/svetlana/Documents/projects/quenderin` @ commit `b1264dc`. Every finding below was checked against source. Verdict tags: **CONFIRMED** (verified in code), **CONFIRMED-REVISED** (real, but the draft's details/severity were corrected), **FALSE POSITIVE** (removed/downgraded).

Severity: **critical** = hangs/OOM/severe slowdown in normal use; **high** = significant hot-path cost; **medium** = noticeable but bounded; **low** = hygiene.

---

## CRITICAL

### C1. Background daemon and interactive chat/agent share one `LlmService`, and the `maxConcurrentHeavyOps` throttle is never wired up — CONFIRMED
`src/server.ts:128` (`backgroundDaemon.start()` runs unconditionally) → `src/services/backgroundDaemon.service.ts:107-133`. The daemon's `pollLoop` runs forever and on every >5% screen change (`VISUAL_DIFF_THRESHOLD = 0.05`, `constants.ts:266`) calls `this.llmProvider.generateAction(...)` (line 128) on the **same `LlmService` singleton** wired into chat and the agent loop (`server.ts:114,118,119`).

Verified detail: `generateAction` (`llm.service.ts:843`) creates a *fresh sequence per call* via `context.getSequence()`, while `generalChat` reuses one `generalChatSession`. Multiple sequences on one llama context can technically run, but on CPU tiers (1–2 tok/s) they contend for the same cores, so a user message queues behind an in-flight 100-token background vision generation. `getModelAndContext` serializes only *model load* (`initPromise`, line 350), not inference.

Confirmed: `maxConcurrentHeavyOps` is defined per tier (`hardware.ts:174/188/202/217`, commented "serialize everything") but `grep` shows its only consumer is `health.ts:108` — it gates nothing. No semaphore/acquire exists anywhere in `src/` (only the comment-only `_stateMutex` and the `initPromise` model-load lock).

Fix: (1) suspend the daemon while `isCurrentlyGenerating()` or `agentService.isRunning`; (2) implement the shared semaphore (size = `HW.maxConcurrentHeavyOps`) that all three inference paths acquire, user-interactive first; (3) make the daemon opt-in — it is on by default.

### C2. `availableMemBytes()` shells out synchronously (`execSync`) and blocks the event loop on hot paths — CONFIRMED-REVISED
`src/utils/memory.ts:60` (`vm_stat`), `:137,:146` (`powershell`/`wmic`), all via `execSync`. Callers verified: the 15s pressure monitor (`llm.service.ts:190`), model selection (`llm.service.ts:369,393`), `checkMemoryForModel` (`constants.ts:198`), `/health` (`health.ts:145`), and `system_info` tool (`handlers.ts:67`). `execSync` blocks the whole event loop; on Windows the PowerShell spawn can take hundreds of ms–seconds.

**Correction to the draft's "12 synchronous spawns per model load" claim:** `selectBestModel` (`llm.service.ts:105-122`) iterates the catalog smallest-first and **`return`s on the first model that fits**, calling `checkMemoryForModel` only for models that *don't* fit before that point. In the common case (the smallest downloaded model fits) it's 1 call, not 12. The worst case (only large models downloaded, none fit until the last) approaches N calls, but that is not the normal path. The event-loop-blocking concern is real; the "12× per load" framing is overstated.

Also worth noting (draft missed): `getModelAndContext` calls `availableMemBytes()` again at lines 369 and 393 *in addition* to whatever `selectBestModel`→`checkMemoryForModel` already spent — so a load does ≥2 synchronous spawns even in the happy path.

Fix: make detection async (`spawn`/`exec` + promise) or sample-and-cache for a few seconds; in `selectBestModel`, read memory once and pass it into the fitness check rather than re-reading per entry.

### C3. Shipped `public/assets/` is a single 1.1 MB JS chunk; the full Prism highlighter is in the eager (not lazy) path — CONFIRMED-REVISED, root cause corrected
`public/assets/` contains exactly one JS file (`index-oxnjuK6c.js`, 1.1 MB) + one CSS (85 KB), despite `ui/vite.config.ts:11-18` defining four `manualChunks` (react-vendor/markdown/syntax/icons).

**Root cause verified:** the build (`ui/package.json:8`: `tsc -b && vite build && rm -rf ../public && cp -r dist ../public`) copies `ui/dist`→`public`. A correct build *would* emit multiple chunks — so the committed `public/` is a **stale artifact built before `manualChunks` was added**. The config is valid; the checked-in bundle predates it. Rebuilding fixes the chunking.

**Important correction the draft got wrong:** the draft credits `App.tsx` lazy-loading with deferring the highlighter. It does not. `App.tsx:6-7` imports `ChatArea` and `GeneralChatArea` **eagerly**; both statically import `CodeBlock` (`GeneralChatArea.tsx:6`, `ChatArea.tsx:6`), which imports `{ Prism as SyntaxHighlighter }` — the **full Prism build** (`CodeBlock.tsx:3`, ~all language grammars; package is 8.7 MB on disk). Only `Inspector/Docs/Metrics/SettingsArea` are lazy (`App.tsx:15-18`). So the highlighter + `react-markdown` load on first paint regardless of chunking; `manualChunks` would split them into a separately-cached chunk but **still eagerly fetched**.

Verified: `react-syntax-highlighter/dist/esm/prism-light.js` exists, so `PrismLight` is a drop-in. 51 distinct lucide icons across 11 import sites (draft's "50 icons" was accurate; "barrel import" tree-shakes fine in a real build).

Fix: (1) rebuild so `public/` reflects the chunk config; (2) switch `CodeBlock` to `PrismLight` + register only supported languages (typically −400–600 KB); (3) to actually defer it, lazy-load the chat area or split `CodeBlock` behind its own dynamic import, since today it is eager.

---

## HIGH

### H1. Two sequential LLM vision calls per agent step (eye-description + action) — CONFIRMED
`src/services/agent.service.ts:206-233`. Each step runs `generateAction` for an "Autonomous Eye" description (line 211, `maxTokens:100`) **then** the action decision (line 228, `maxTokens:150`), both passing the same `state.screenshotPath`. With `maxSteps` 8–15 (`resolveDefaultMaxSteps`, line 99-105) that is up to ~30 vision inferences/task; on CPU tiers this roughly doubles per-step latency. Intent classification already demonstrates the tier-gating pattern to copy (`agent.service.ts:135`).

Fix: drop the separate eye call (the action call already receives the image at line 232), or gate it behind a tier check / only when the symbolic representation is empty.

### H2. `findRelevantCorrections` re-reads + re-parses `corrections.json` and embeds + scans all vectors on every prompt build — CONFIRMED
`src/services/memory.service.ts:223-253`, called from `promptBuilder.ts:21` every agent step. Verified: it `readFile`+`JSON.parse`s the entire corrections file (up to `MAX_CORRECTIONS = 500` entries each holding a 384-float vector), runs a Xenova embedding on the query, then `cosineSimilarity` (384 mults, line 210-221) across all records. `package.json:55` declares `hnswlib-node` but `grep` confirms it is **never imported** in `src/`.

Added (draft missed): `promptBuilder.ts:15` *also* calls `findSimilarGoal` every step, which re-reads + parses `memory.json` (line 161). So each step does **two** full JSON read-parse passes plus an embedding.

Fix: cache the parsed arrays in memory and invalidate on write (the service is a singleton); keep vectors in a `Float32Array` matrix or use the declared `hnswlib-node`; memoize the query embedding by `textRepresentation` hash across steps.

### H3. Read-modify-write rewrites the whole JSON file on every correction/trajectory/telemetry save — CONFIRMED
`memory.service.ts:105-128` (`saveTrajectory`), `:130-156` (`injectOverride`), `:177-208` (`saveCorrection`) and `metrics.service.ts:48-60` (`appendMetrics`) each `readFile`→`JSON.parse`→push→`writeFile(JSON.stringify(records, null, 2))`. Verified the pretty-print (`null, 2`) on all four. For `corrections.json` (500 × 384-float vectors) each save re-serializes ~1.5 MB; `appendMetrics` rewrites up to 1000 telemetry records per agent run. The NDJSON-append pattern already exists for habit logs (`metrics.service.ts:73-79`).

Fix: move corrections/trajectories/telemetry to NDJSON append; drop `null, 2` on hot-write files; or keep arrays in memory and debounce-flush like `SessionService`.

### H4. Android idle-polling is tripled: `getScreenContext` self-waits, every action also waits, and the verifier waits again — CONFIRMED, understated by the draft
`src/services/providers/android.provider.ts`. `getScreenContext()` (line 189) calls `waitForUiIdle()` (line 191) which loops up to **10×** (line 121-142), each iteration sleeping `uiIdlePollMs` (500ms–1s) then doing dump+pull (two ADB spawns via `getUiHierarchyXml`, line 107-108). After settling it does *another* dump+pull+screencap+pull (line 201-206).

The triple-settle the draft hinted at is **worse than stated**: every action method also self-waits — `click` (line 147), `type` (line 158), `scroll` (line 175), `pressKey` (line 186) each end with `await this.waitForUiIdle()`. The agent loop calls `actionExecutor.execute()` (→ e.g. `click`→`waitForUiIdle`), then `uiVerifier.waitForIdle()` (`agent.service.ts:307`) → `getScreenContext()` → `waitForUiIdle()` again. So a single post-action verification can settle the UI **three independent times**, each a 0–10s ADB poll loop.

Fix: make `getScreenContext` a pure one-shot capture; let the verifier's `waitForIdle` be the single settle authority; consider `exec-out uiautomator dump /dev/tty` to drop the separate `pull`.

### H5. `Inspector` renders one DOM node per UI element with no memoization/virtualization and clones the logs array each render — CONFIRMED
`ui/src/components/Inspector.tsx`. Renders an absolutely-positioned `<div>` per `currentUI` node (line 55-78); the component is not wrapped in `React.memo`; `[...logs].reverse().find(...)` (line 13) clones the entire (≤300) logs array every render. Verified upstream: `parseUI` keeps **every** node (`uiParser.service.ts:88` sets all into the map), and `useAgentSocket.ts:88` sets `currentUI` to the raw `data.elements`. `App.tsx:406-410` auto-opens the Inspector on every `observe` while running, so each observe re-lays-out all nodes.

Fix: `React.memo` the Inspector; render only interactable nodes; cap/virtualize for large hierarchies; replace the array clone with a reverse `for` loop or derive `lastDecide` upstream.

---

## MEDIUM

### M1. Parser keeps all nodes; LLM text + `observe` payload include non-interactable nodes — CONFIRMED
`src/services/uiParser.service.ts:98-121`. `buildLLMPromptRepresentation` iterates the full `stateMap` (every node) and JSON-stringifies all of them (each row carries `isInteractable`, but non-interactable rows are still emitted). This bloats prompt tokens and the WS `observe` payload (`agent.service.ts:184` sends `state.elements` = all nodes). Note `bounds` is hard-coded `null` in the LLM rows (line 116), so coordinates aren't even leaking — but the node count still is. The `observe` WS message labels these "interactable nodes" (`useAgentSocket.ts:84`), which is misleading since it's all of them. Also `traverse` (line 48-56) recurses children before assigning the parent id.

Fix: filter to interactable / text-bearing nodes before building the representation and emitting `observe` — shrinks prompt, WS payload, and Inspector render set together.

### M2. Per-step O(n) hashing and linear `verifyAction` scans — CONFIRMED
`src/services/agent/uiVerifier.ts:28-33` (`hashUiState` concatenates all elements into one big string then SHA-256s), `:143-147` (`verifyAction` does `.find` + `.some` over the element arrays). `hashUiState` is called at line 110 of each `waitForIdle`, and `waitForIdle` runs twice per agent step (lines 172 and 307 of `agent.service.ts`), so ~2 full hashes + 2 scans/step over hundreds of elements.

Fix: hash only the interactable subset (consistent with M1); index pre-state elements by `id` in a `Map` for `verifyAction`.

### M3. `cleanupOrphanedTempFiles` `stat`s/`unlink`s temp entries serially — CONFIRMED
`src/server.ts:39-62`. Runs at startup and every 30 min (`TEMP_CLEANUP_INTERVAL_MS`). Prefix-filters (good), then `await fs.stat` / `await fs.unlink` serially per matching entry. Low frequency keeps it medium; the serial awaits are the issue.

Fix: bounded-concurrency `Promise.all` over the stats.

### M4. `Metrics` recomputes ~5 full-array reductions over up to 1000 records every render, no `useMemo` — CONFIRMED
`ui/src/components/Metrics.tsx:128-146`. `totalRuns/successRuns/avgRetries/avgDurationSec/avgSteps` + chart slices each iterate `metrics` on every render with no memoization. Renders are infrequent (single fetch at line 116-126), so bounded — but trivially fixed.

Fix: wrap derived stats in `useMemo([metrics])`.

### M5. `chat_stream` spreads the entire logs array per token — CONFIRMED
`ui/src/hooks/useAgentSocket.ts:95-104`. Every streamed token runs `setLogs(prev => { const newLogs = [...prev]; ... })` — a full copy of the (≤300) logs array and a React re-render per token. Capped, but wasteful.

Fix: accumulate streamed text in a ref and flush to state on a RAF / ~50ms cadence.

### M6. `react-markdown` + `remark-gfm` re-parse the entire growing message every token — CONFIRMED
`ui/src/components/GeneralChatArea.tsx:281-301`. During streaming the `<ReactMarkdown>` re-parses the full accumulated string each render (per M5, per token), with `CodeBlock` (full Prism) re-instantiated in its `components.code` slot — quadratic in total output length. Same pattern present in `ChatArea.tsx`.

Fix: throttle streaming re-renders (tie to M5); render streaming text as `whitespace-pre-wrap` and switch to `<ReactMarkdown>` only once `isStreaming` is false.

### M7. `git rev-parse` shelled out at health-route module load — CONFIRMED
`src/routes/health.ts:16-28`. `resolveCommitSha()` runs `execSync('git rev-parse ...')` at import time (cached in `commitSha`, line 28). One-time and already prefers `QUENDERIN_GIT_SHA`/`GITHUB_SHA` env vars (line 17) and swallows failures, so impact is small.

Fix: rely on the env injection in packaged builds; skip the spawn when `.git` is absent (minor).

---

## LOW

### L1. `findSimilarGoal` mutates+reverses the trajectory array — CONFIRMED
`src/services/memory.service.ts:167`. `records.reverse().find(...)` on up to 50 records per agent prompt build. Bounded; use a reverse-iterating loop.

### L2. Voice WAV writer copies PCM sample-by-sample; `writeFileSync` blocks — CONFIRMED-REVISED
`src/services/voice.service.ts:236-239` writes `writeInt16LE` in a per-sample loop, then `fs.writeFileSync` (line 241) blocks the event loop. **Correction:** the 320 KB `Int16Array(160000)` is allocated **once in the constructor** (line 29-30), not per recording; and `writeWavFile` receives `recordedFrames` (the trimmed buffer, `voice.service.ts:159`), so the loop length is the actual recording, not always 160k. Still: bulk-copy via `Buffer.from(pcmBuffer.buffer)` and use `fs.promises.writeFile`.

### L3. `calculateVisualDiff` copies the full RGBA frame every poll — CONFIRMED
`src/services/backgroundDaemon.service.ts:97` (`this.lastPixelData = Buffer.from(currentPng.data)`) copies the whole frame (multi-MB; ~10 MB at 1080×2400) every tick (2–10s). The diff *scratch* buffer is reused (good, line 76-78), but the last-frame store reallocates each tick.

Fix: double-buffer two pre-allocated buffers and `.copy()`/swap rather than `Buffer.from` each tick.

### L4. `pruneOldSessions` reads+parses every session file on every flush — CONFIRMED
`src/services/session.service.ts:211` calls `pruneOldSessions` → `listSessions` (line 217-228 → 112-142) which `readFileSync`+`JSON.parse`s **every** session file (≤100). `flushNow` runs on the 2s debounce (`scheduleFlush`, line 196-203), so an active chat re-parses up to 100 files every couple seconds.

Fix: prune only in `startSession` (where a new file appears), not on every flush; or cache the list and `stat` for sort instead of parsing.

### L5. `ui/app.js` legacy entrypoint — DOWNGRADED (draft's "bypasses chunked build" claim is a FALSE POSITIVE)
`ui/app.js` (7.8 KB) exists but `grep` confirms it is **not referenced** anywhere: `ui/index.html` loads only `/src/main.tsx` (line 13), and the only `app.js` import in the repo is `src/server.ts:7` (`./app.js` = compiled `src/app.ts`, unrelated). It is **not** shipped or served, so the draft's concern that it "bypasses the chunked build" or "serves a stale duplicate" is wrong. It is simply a dead orphan file. Per the project's CLAUDE.md delete-audit rule, deletion needs confirmation (it's source).

Verdict: harmless dead code, not a performance issue. Confirm and delete for hygiene only.

---

## Verified as already-handled (do not "fix")
- Habit logs use NDJSON append (`metrics.service.ts:73-79`) — confirmed; H3 extends this pattern to the other stores.
- Download streaming respects backpressure (`llm.service.ts:782-785`) and supports resume (`:710-724`) — confirmed.
- `getHardwareProfile()` is cached (`hardware.ts:55-61`); intent classification has regex-first fast path + LLM skip on low tiers (`agent.service.ts:135-149`) — confirmed.
- WS logs capped at 300 (`useAgentSocket.ts:24-25`); model/extractor idle-unload timers reclaim RAM (`llm.service.ts:285-294`, `memory.service.ts:76-87`) — confirmed.
- Daemon stores only raw RGBA, not the PNG object, to bound heap (`backgroundDaemon.service.ts:21-22,71-72`) — confirmed (but see L3 for the per-tick copy).
- `waitForIdle` deletes intermediate screenshots, keeping only the final one (`uiVerifier.ts:79-85`) — confirmed.

---

## Recommended next steps (highest leverage first)
1. **C1** — gate daemon inference on user-interaction state + make it opt-in, and wire the `maxConcurrentHeavyOps` semaphore that is currently dead config. Biggest real-world latency win.
2. **C2** — make `availableMemBytes()` async/cached; stop the extra reads in `getModelAndContext` (lines 369/393) and the per-non-fitting-entry reads in `selectBestModel`. Removes event-loop stalls (especially Windows).
3. **C3** — rebuild so `public/` reflects `manualChunks`, switch `CodeBlock` to `PrismLight` with registered languages, and actually defer the chat area / `CodeBlock` (today it is eager, so the highlighter ships on first paint). ~50%+ smaller initial download.
4. **H1** — drop the redundant per-step eye-description LLM call (or tier-gate it). Roughly halves agent step latency on CPU.
5. **H4** — collapse the tripled Android idle-polling into one settle authority. Cuts seconds of ADB round-trips off every action.
6. **H2 + H3** — cache parsed corrections/trajectories in memory and move hot writes to NDJSON append; drop `null, 2`. Removes ~1.5 MB parse + serialize from every agent step.

Changes from the draft: C2 "12 spawns per load" corrected to "first-fit returns early; ~1–2 in the common path, plus 2 unconditional reads in getModelAndContext"; C3 root cause pinned to a stale committed `public/` and the highlighter shown to be in the **eager** path (the draft wrongly credited lazy-loading); H2 expanded to include the per-step `findSimilarGoal` read; H4 shown to be a *triple* (not double) settle; L2 corrected (one-time allocation, trimmed buffer); **L5 downgraded — the "bypasses chunked build / stale duplicate" claim is a false positive** (`ui/app.js` is unreferenced and never served). No files were modified; strictly read-only.
