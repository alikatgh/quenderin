---
title: Correctness Audit — quenderin (Round 2, verified)
repo: quenderin
lens: correctness
date: 2026-06-14
round: 2
---

Confirmed: the desktop provider uses UUID-named files (`desktop_screen_${uuid}.png`) with no shared fixed path, so finding #2 is Android-specific only. Good.

I now have everything needed. Let me compile the final verified report.

Summary of verification verdicts:
- #1 calculator trailing tokens: **CONFIRMED**
- #2 shared device-side dump path: **CONFIRMED** (but draft's "DaemonService also polls" is wrong — dead code; and draft's local-temp-file framing correct)
- #3 falsy-id verifier: **CONFIRMED** (but draft's line-126 code description is stale, and "phantom = id 0" is wrong — root gets highest id, not 0)
- #4 trajectory cap: **CONFIRMED**
- #5 dual electron entry: **CONFIRMED & strengthened** (build main IS the buggy file) — but "force-opens browser" is mitigated by TTY guard
- #6 telemetry race: **CONFIRMED** (appendMetrics no lock; getHabits compaction race) — downgrade to medium-low
- #7 phantom root + post-order: **CONFIRMED** (root is highest id, not 0)
- #8 input text whitespace: **CONFIRMED** (real Android `input text` quirk)
- #9 WelcomeWizard Next: **CONFIRMED**
- #10 queued attachments dropped: **CONFIRMED**
- #11 errorHandler headersSent + CORS 500: **CONFIRMED**
- #12 LLM-fallback cache eviction: **CONFIRMED**
- #13 MAX_CHAT_TURNS off effective ctx: **CONFIRMED**
- #14 voice buffer off-by-one + unguarded unlink: **CONFIRMED**
- #15 isPortFree IPv6: **CONFIRMED**
- #16 PrivacyLock theater: **CONFIRMED**
- #17 chat_response raw send: **CONFIRMED**
- NEW: initPromise left as rejected promise after synchronous MODEL_MISSING throw (the draft dismissed this as "not a bug" — it's actually a real latent issue)

# Correctness Audit — quenderin (verified)

Read-only audit of `/Users/svetlana/Documents/projects/quenderin`. Every finding below was re-checked against the live source. Severity: critical / high / medium / low. The draft contained several stale line-citations and two factual errors (the "phantom root = id 0" claim and the "DaemonService also polls" claim) — both corrected here. No edits were made; this is strictly read-only. No `docs/BUG_JOURNAL.md` exists, so per project convention these belong there once fixes land.

## High

### 1. Calculator silently ignores trailing tokens → confidently wrong results
**File:** `src/services/tools/calculator.ts:213-227` (`safeCalculate`)
**Status:** CONFIRMED.
`safeCalculate` calls `parser.parseExpression()` and returns without ever checking that all tokens were consumed (no `this.pos === this.tokens.length` guard; `Parser` exposes no `pos`/`isAtEnd()`). Leftover tokens are silently discarded:
- `"2 3"` → `2`; `"2)"` → `2`; `"3+4 5"` → `7`; `"(1+2)(3+4)"` → `3`.
This is an LLM-exposed tool (`handlers.ts:41-48`), so the model receives a plausible-but-wrong number and presents it as fact. **Fix:** after `parseExpression()`, throw `CalculatorError('Unexpected trailing input')` if not at end-of-tokens. Related minor: `tokenize` (`:34-40`) accepts `"1.2.3"` (collects `[\d.]+`, `parseFloat` truncates to `1.2`) — reject number tokens with >1 decimal point.

### 2. Android provider uses fixed device-side dump paths → screenshot/XML race with the always-on daemon
**File:** `src/services/providers/android.provider.ts:107-108, 202-205`
**Status:** CONFIRMED, with a correction to the draft.
Local temp files are UUID-named (`:103-104, :194-195`) — good — but the **device-side paths are fixed constants**: `uiautomator dump /sdcard/window_dump.xml` then `pull` (`:107-108` and `:202-203`), and `screencap -p /sdcard/screen.png` (`:204-205`). In `server.ts:119` the same `AndroidProvider` instance is shared by `agentService` and `backgroundDaemon`, and `backgroundDaemon.start()` (`server.ts:128`) polls `getScreenContext` continuously (`backgroundDaemon.service.ts:111`). The agent loop concurrently calls `getScreenContext` via `uiVerifier.waitForIdle` (`agent.service.ts:172,307` → `uiVerifier.ts:49`). Two concurrent `uiautomator dump`s / `screencap`s to the same `/sdcard` path mean one consumer can `pull` a half-written or wrong-frame file.
**Correction to the draft:** `DaemonService` (`daemon.service.ts`) is **dead code — never instantiated** anywhere in `src/` (only `BackgroundDaemonService` is wired). The race is daemon-vs-agent, not "both daemons." The `DesktopProvider` is NOT affected — it uses a UUID PNG path and empty XML (`desktop.provider.ts:150-161`). **Fix:** per-call UUID device path (e.g. `/sdcard/window_dump_<uuid>.xml`) with cleanup, or a provider-level mutex serializing `getScreenContext`/`getUiHierarchyXml`.

### 3. `verifyAction` treats element id `0` as "no target" (falsy-id bug)
**File:** `src/services/agent/uiVerifier.ts:126,129`
**Status:** CONFIRMED — but the draft's description was stale.
The draft claimed line 126 reads `target_id ?? id`; the actual code at `:126` already uses `actionObj.target_id !== undefined ? actionObj.target_id : actionObj.id` (correct). The real bug is at **`:129`**: `if (!targetIdRaw || (actionType !== 'click' && actionType !== 'input'))` uses a **falsy** check. `uiParser.service.ts:25,73` assigns IDs from `0` (`idCounter++`), so a valid element with `id: 0` makes `!targetIdRaw` true → the verifier skips the real pre/post element-existence check and returns a generic `[Success] Executed click.` even if the click did nothing. The executor (`actionExecutor.ts:48,50`) correctly uses `!== undefined && !== null` — the two paths disagree about whether `0` is valid. **Fix:** at `:129` use `targetIdRaw === undefined || targetIdRaw === null` to mirror the executor.
**Correction:** the draft tied this to "the phantom root element which is id 0." That is wrong — see #7; the root wrapper gets the *highest* id, not 0. The id-0 element is the first-processed leaf. The bug stands regardless.

## Medium

### 4. Trajectory memory cap never actually caps (ineffective bulk limit)
**File:** `src/services/memory.service.ts:113-115` and `137-139`
**Status:** CONFIRMED.
```
if (records.length > 50) { records = records.slice(1); }   // removes ONE
records.push(...)
```
Comment says "Limit memory to the last 50," but `slice(1)` drops only one element. At 51 entries the file stays pinned at 51 forever (drop 1, push 1) and never truncates to 50; if it ever exceeds 51 a single call can't bring it back. Both `saveTrajectory` and `injectOverride` have the bug. The correct pattern already exists in the same file: `saveCorrection` (`:187-188`) does `records.slice(-(MAX_CORRECTIONS - 1))`. **Fix:** `if (records.length >= 50) records = records.slice(records.length - 49);` then push.

### 5. Two Electron entry points; `package.json` `main` resolves to the BUGGY one (hardcoded port 3000)
**File:** root `electron/main.ts:23,31` vs `src/electron/main.ts:29,33,54`
**Status:** CONFIRMED and strengthened; one sub-claim corrected.
`package.json` `main = dist/electron/main.js`. With `tsconfig.json` `rootDir: "./"`, `outDir: "./dist"`, and `include: ["src/**/*","electron/**/*"]`, the root `electron/main.ts` compiles to exactly `dist/electron/main.js` (the file `main` points to), while the *correct* `src/electron/main.ts` compiles to `dist/src/electron/main.js` and is never used as the entry. So the shipped entry is the buggy one: it calls `startDashboardServer(3000)` and then hardcodes `win.loadURL('http://localhost:3000')` (`:23`), but `startDashboardServer` auto-shifts to a free port when 3000 is busy (`server.ts:88-91`) — the window can load a dead port while the backend listens elsewhere. `src/electron/main.ts` does it right (`findFreePort` → `loadURL(\`...${PORT}\`)`, `openBrowser=false`).
**Correction to the draft:** the "force-opens a system browser" claim is mitigated — `server.ts:95` gates browser-open behind `isInteractiveShell` (`stdout.isTTY && stdin.isTTY`), which is false in a packaged Electron app, so the browser won't actually spawn. The real, confirmed defect is the port mismatch + having two divergent entries. **Fix:** retire the root `electron/main.ts` (or make it use the resolved port + `openBrowser=false`), and confirm the build maps `main` to the intended file.

### 6. UI parser emits a phantom root element and assigns IDs in post-order
**File:** `src/services/uiParser.service.ts:48-93`
**Status:** CONFIRMED — with a correction to the draft.
`traverse` recurses into `node.node` children **first** (`:51-56`), then unconditionally builds a `UIElement` for *every* node including the top-level `hierarchy` wrapper passed at `:91-92` (the wrapper has no bounds/clickable → a junk element at `{0,0}`). Two consequences: (a) a phantom element always exists; (b) IDs are assigned post-order, so leaves get low IDs and parents/root get high IDs — unintuitive for the LLM to reference.
**Correction to the draft:** because numbering is post-order, the phantom `hierarchy` wrapper receives the **highest** id (assigned last), not `id: 0`. The draft's "phantom root becomes id 0" is incorrect. **Fix:** skip the root wrapper (emit only real `node` entries) and assign IDs in a stable pre-order.

### 7. `adb shell input text` mis-handles whitespace/special chars
**File:** `src/services/providers/android.provider.ts:157`
**Status:** CONFIRMED.
`spawnAdb(['shell','input','text', text])` passes `text` as one argv element, but the on-device `input text` re-splits on spaces, so `"hello world"` types only `hello` (the rest is treated as extra args / dropped), and shell-reserved chars misbehave. The inline comment ("Safely passes text as an exact argument, no shell parsing") is true for the host process spawn but does not address the device-side `input` re-tokenization. **Fix:** replace spaces with `%s` and percent-encode reserved chars per Android `input text` conventions, or send per-character keyevents.

### 8. WelcomeWizard "Next" can get stuck disabled mid-download
**File:** `ui/src/App.tsx:148-151` (with `:32-40`)
**Status:** CONFIRMED.
`disabled={downloadProgress < 100 && isModelDownloading}`. `isModelDownloading` is set true on click (`:33`) and only reset on a fetch **rejection** (`:38`). The POST returns immediately (`app.ts:120-127` just initiates a background download), so on success `isModelDownloading` stays true; `downloadProgress` is driven purely by WS `model_download_progress` events (`useAgentSocket.ts:144-146`). If those events stall or never reach 100 (slow/broken network), the user is stuck on step 2 with no skip affordance. (If the model already exists, `llm.service.ts:669` emits progress 100 immediately, which unblocks — so the stall path is the real risk.) **Fix:** drive `disabled` off `downloadProgress` alone, and/or clear `isModelDownloading` when progress hits 100; add a skip option.

## Low

### 9. Queued chat follow-ups silently drop their attachments
**File:** `ui/src/components/GeneralChatArea.tsx:130-141, 171-182`
**Status:** CONFIRMED.
When `status === 'running'`, `handleStart` queues only the string (`:133` `setMessageQueue(prev => [...prev, chatInput])`) and the flush effect sends `onSend(combined, [])` (`:178`). Any attachments staged while a response streams are not carried into the queued send. **Fix:** queue `{ message, attachments }` tuples and forward attachments on flush.

### 10. `errorHandler` ignores `res.headersSent`; CORS rejections return 500 not 403
**File:** `src/middlewares/errorHandler.ts:14`, `src/app.ts:55-62`
**Status:** CONFIRMED (severity low).
`errorHandler` unconditionally does `res.status(500).json(...)` with no `res.headersSent` guard, so an error after the response has begun throws `ERR_HTTP_HEADERS_SENT`. Note: most routes buffer (`res.send`/`res.json`), and `/api/sessions/:id/export` (`app.ts:186-193`) uses buffered `res.send`, so this is largely theoretical today but is a latent footgun for any future streaming route. Separately, the CORS `origin` callback rejects with a bare `Error` (`app.ts:60`) which reaches `errorHandler` and returns **500** instead of **403**. **Fix:** `if (res.headersSent) return _next(err);` first; map CORS errors to 403.

### 11. LLM-fallback intent results bypass cache-size eviction
**File:** `src/services/intentClassifier.ts:140-141`
**Status:** CONFIRMED.
`classifyWithLlmFallback` does `cache.set(key, result)` with no `cache.size >= MAX_CACHE_SIZE` eviction guard, unlike `classifyIntent` (`:64-68`). The module-level `Map` can grow past the intended 200 cap when the LLM path is exercised. **Fix:** route both writes through one `cacheSet` helper that always evicts. (Confirmed: regexes use `.test()` with no `/g`, so no `lastIndex` statefulness — the draft's "not a bug" note is correct.)

### 12. `MAX_CHAT_TURNS` keyed off the user setting, not the effective loaded context
**File:** `src/services/llm.service.ts:808-811`, used at `:875-877`
**Status:** CONFIRMED.
`MAX_CHAT_TURNS` derives from `this.currentSettings.contextSize` (user preference, default 2048 → ~20 turns), but the model may be loaded with a far smaller *effective* context via `resolveContextForSituation` (degraded mode / RAM caps, e.g. `HW.contextFloor` or 256). On a constrained box the session runs many more turns than its real context allows before the reset the comment at `:805-806` is meant to prevent — risking context overflow/thrash. **Fix:** record the effective context chosen at load (`effectiveCtx`, `:402-405`) and base `MAX_CHAT_TURNS` on that.

### 13. Voice capture buffer drops the last fitting frame; success-path unlink is unguarded
**File:** `src/services/voice.service.ts:118, 181`
**Status:** CONFIRMED.
`:118` uses `<` (`currentSampleIndex + pcm.length < MAX_RECORDING_SAMPLES`), rejecting a frame that would exactly fill the buffer — should be `<=` (off-by-one, drops up to one frame). `:181` `await fs.promises.unlink(wavPath)` is unguarded; if the WAV is already gone it throws into the generic catch (`:197`) and is misreported as "Transcription error" (contrast the early-return path at `:169` which `.catch()`es). **Fix:** use `<=`, and `.catch()` the success-path unlink.

### 14. `isPortFree` probes IPv6-only → possible false "free"
**File:** `src/server.ts:64-73`
**Status:** CONFIRMED.
The tester binds `.listen(port, '::')`, but the real server binds all interfaces (`server.listen(selectedPort)`, `:192`). A port free on IPv6 but occupied on IPv4 reports free; `listen` then fails (handled by the EADDRINUSE branch at `:177-186`, so not fatal — but it defeats the pre-check's purpose). **Fix:** probe without a host, or test both families.

### 15. PrivacyLock hashing is security theater
**File:** `ui/src/components/PrivacyLock.tsx:9-14, 53-57`; passphrase source `ui/src/hooks/useAgentSocket.ts:11,36-37`
**Status:** CONFIRMED.
The comment "so we never compare plaintext" is misleading: `expectedPassphrase` arrives as plaintext from `settings.privacyPassphrase` (stored unencrypted in `localStorage` under `quenderin_settings`) and is re-hashed (unsalted) at compare time (`:55`). The hash adds no protection — the secret is already client-side and the gate is bypassable by clearing React/localStorage state. (Comparison is also non-constant-time; immaterial here.) **Fix:** document it as a cosmetic UI gate, or move verification server-side with a salted hash if real protection is intended.

### 16. Final `chat_response` bypasses the backpressure guard used for streamed chunks
**File:** `src/websocket/index.ts:251,260,267` (`safeSend`) vs `:272` (raw `ws.send`)
**Status:** CONFIRMED.
Streamed `chat_stream` chunks honor `MAX_SEND_BUFFER_BYTES` via `safeSend` (`:251,260,267`), but the final full `chat_response` uses raw `ws.send` (`:272`). On a congested socket, mid-stream chunks may have been dropped while the final body is forced through — so the client can receive a final message inconsistent with the (partially dropped) stream. Acceptable as designed, but worth aligning or commenting.

### 17. After a synchronous `MODEL_MISSING`, `initPromise` is left pointing at a rejected promise (not cleared)
**File:** `src/services/llm.service.ts:362-380, 559-592`
**Status:** NEW — the draft explicitly dismissed this as "not a bug"; on re-trace it is a real latent issue.
The async IIFE created at `:362` runs synchronously up to its first `await`. On the `MODEL_MISSING` path, `selectBestModel` (`:365`, sync) returns null and the code **throws synchronously** at `:375-378` before any `await`. That synchronous throw is caught at `:559`, whose handler sets `this.initPromise = null` (`:575`) — but this runs *during* the IIFE invocation at `:362`, i.e. **before** `:580` executes `this.initPromise = promise`. So `:580` then overwrites the just-nulled field with the (already-rejected) promise, and the outer `catch` at `:583-591` only nulls `initPromise` on `LLM_INIT_TIMEOUT`, not on `MODEL_MISSING`. Net effect: after a missing-model error, `this.initPromise` stays set to a rejected promise; the next `getModelAndContext` call hits `if (this.initPromise)` at `:350` and re-throws the stale rejection via `waitWithInitTimeout` instead of re-attempting selection (which matters once the user downloads a model). The model is still loadable through `switchModel`/`downloadModel` flows, so impact is limited — hence Low. **Fix:** in the outer catch (`:583-591`), clear `initPromise` for `MODEL_MISSING`/`ENOENT` too, or set `this.initPromise = promise` *before* invoking the IIFE body.

## Verified NOT bugs (so the next reader can skip them)
- **WS `settings_update` partial-overwrite:** `updateSettings` overwrites the whole settings object, but `websocket/index.ts:303-305` always supplies both fields with defaults (`ALLOWED_CONTEXT_SIZES` validation + `=== true`), so no partial clobber. Not a bug.
- **`read_file` traversal guard** (`handlers.ts:25-29`): anchors on `home + path.sep` (or `=== home`); the double `~`-expansion (`:79-82` then inside `isInsideHome`) is a harmless no-op. Symlinks pointing outside home aren't resolved — a defense-in-depth gap, not a logic bug.
- **Intent regexes:** `.test()` with no `/g` flag → no `lastIndex` statefulness trap.
- **Download-default divergence** (`llm.service.ts:653` uses `MODEL_CATALOG[0]`=qwen3-14b/11GB; `/api/models/download` uses `getRecommendedModelIdForTotalRam`; UI `handleTriggerDownload` defaults `'llama32-1b'`): each call site picks a reasonable default and the route-level fallback is hardware-aware. Inconsistent, not incorrect.
- **`DaemonService`** (`daemon.service.ts`): dead code (never instantiated) — no runtime impact today, but a cleanup candidate.

## Recommended next steps (highest value first)
1. **#1 (calculator trailing tokens)** and **#3 (falsy-id verifier)** — these two most directly corrupt LLM/agent correctness: a wrong math result handed to the model as fact, and failed clicks mislabeled `[Success]`. Both are one-line, well-scoped fixes with the correct pattern already present nearby.
2. **#2 (shared `/sdcard` dump path)** — the worst latent runtime race; the always-on background daemon shares the provider with the agent. Switch to per-call UUID device paths or serialize through a provider mutex.
3. **#4 (trajectory cap)** — copy the `slice(-(N-1))` pattern already used by `saveCorrection` in the same file; trivial data-integrity fix.
4. **#5 (Electron entry)** — confirm the build's `dist/electron/main.js` source and retire the stale root entry; users on a busy port 3000 get a dead window.
5. **#6 / #7 / #8** — parser phantom-root + post-order IDs (#6) compounds #3 and confuses the LLM's element references; `input text` (#7) breaks any multi-word typing; the wizard lock (#8) is a real onboarding dead-end.
6. **Bootstrap `docs/BUG_JOURNAL.md`** and land each fix with its journal entry in the same commit (project convention). Add a "Patterns to scan for FIRST" entry for the recurring **falsy-vs-`!= null` id check** shape (#3) and the **`slice(1)` ineffective-cap** shape (#4), since both recur across this codebase.
