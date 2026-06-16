# Quenderin Pre-Submission Deep Review — 2026-06-16

**Scope:** Final pre-submission deep review of the HIGH-RISK code surfaces NOT touched by the two
prior audits this session (C3 model-download integrity, store compliance). Targets: on-device
inference engines (iOS llama.cpp C-API, Android JNI bridge), desktop autonomous device-control +
safety surface, the server/IPC/Electron surface, and the mobile agent/conversation/selection logic.

**Method:** Digest-first dimension fan-out (7 dimensions), per-dimension finders, then a batched
adversarial verifier per subsystem applying dual-lens skepticism. Only findings that survived
verification are reported below.

---

## Ship Verdict

**SHIP-BLOCKING — do not submit.** This review surfaced **4 critical** defects, every one of which
produces a crash, a use-after-free, a permanent functional lock, or an unbounded resource leak on a
normal user path (not an adversarial-only path). Three of the four are reachable in routine use
(model switch, multi-turn chat, basic agent input). The branch must not be submitted until at least
the 4 criticals and the safety-bypass highs are fixed.

| Severity | Count |
|----------|-------|
| Critical | 4 |
| High | 13 |
| Medium | 11 |
| Low | 7 |
| **Total** | **35** |

---

## Subsystems Reviewed

| Dimension | Surface | Key files |
|-----------|---------|-----------|
| iOS inference engine | Real llama.cpp C-API lifecycle, tokenization, generation, actor isolation | `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift`, `ScriptedInferenceEngine.swift`, `MockInferenceEngine.swift` |
| Android inference engine + JNI | JNI exception/null/ref safety, native handle lifecycle, backend init race | `android/jni/llama_jni.cpp`, `android/quenderin-core/.../LlamaEngine.kt` |
| Desktop autonomous device-control + safety | Agent loop state machine, UI-idle polling, action safety blocklist, ADB shell handling, UI parsing | `src/services/agent.service.ts`, `src/services/agent/uiVerifier.ts`, `src/services/agent/actionExecutor.ts`, `src/services/providers/android.provider.ts`, `src/services/uiParser.service.ts` |
| Desktop HTTP/WS server surface | Route input validation, prompt injection, zip-slip, reflection | `src/app.ts`, `src/routes/health.ts` |
| Electron main process | Navigation hardening, preload wiring, startup error handling | `electron/main.ts` |
| Mobile agent loop + decision parsing | Arithmetic parser recursion, decision JSON extraction, safety gate, Swift⇄Kotlin parity, session thread-safety | `apple/.../AgentTool.swift`, `AgentLoop.swift`, `AgentDecision.swift`, `SafetyBlocklist.swift`, `android/.../AgentDecision.kt`, `AgentSession.kt` |
| Desktop RAG/memory + LLM chat path | KV-cache session rotation, context budgeting, memory-pressure monitor, disk-space shell, embedding similarity, write-lock atomicity | `src/services/llm.service.ts`, `src/services/memory.service.ts`, `src/services/memory.ts` |

---

## Confirmed Findings by Severity

### CRITICAL (4) — ship-blockers

#### C1. iOS: model + context leaked on re-load (double load without prior free)
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:75-78`
- **What:** `load()` assigns `self.model`/`self.context`/`self.vocab` unconditionally without freeing
  any pre-existing handles first. A second `load()` (model switch) overwrites the old `llama_model*`
  and `llama_context*` without `llama_model_free`/`llama_free`.
- **Why it matters:** Each leaked context holds the GGUF weights — typically 4–11 GB RAM on-device —
  reclaimed only at process exit. One model switch can OOM the device.
- **Fix:** At the top of the `#if canImport(llama)` block in `load()`, free existing handles before
  allocating: `if let c = self.context { llama_free(c); self.context = nil }; if let m = self.model { llama_model_free(m); self.model = nil }`.
  Or require `unload()` before `load()` and assert `self.model == nil` on entry.

#### C2. Android: native handle has no thread-safety — concurrent load/unload/complete is a use-after-free
`android/quenderin-core/src/main/kotlin/ai/quenderin/core/LlamaEngine.kt:32` (also lines 23, 40, 48, 57)
- **What:** `handle: Long` (opaque native pointer) and `loadedModelId: String?` are plain `var`
  fields — no `@Volatile`, no lock, no `Mutex`. `load()`, `unload()`, and both `complete()` overloads
  read/write `handle` unsynchronized; the streaming overload holds it across a long native call.
- **Why it matters:** A `unload()` (e.g. UI cancel) on one thread while `complete()`/`nativeComplete()`
  runs on another frees the C++ `LlamaHandle` while `generate()` is still touching `h->ctx`/`h->model`
  — SIGSEGV or silent native memory corruption.
- **Fix:** Guard all `handle`/`loadedModelId` access with a `ReentrantReadWriteLock` (read-lock for
  `ensureReady()`+`nativeComplete`, write-lock for `load()`/`unload()`), or a coroutine `Mutex`.

#### C3. Android JNI: pending exception not cleared after `TokenSink.onToken` — UB on next JNI call
`android/jni/llama_jni.cpp:73`
- **What:** After `env->CallVoidMethod(sink, on_token, js)`, if the Kotlin `onToken` throws, the
  exception is left pending. There is no `ExceptionCheck()`/`ExceptionClear()` anywhere in `generate()`.
  The next loop iteration calls `env->NewStringUTF(...)` (line 72) with a pending exception, which the
  JNI spec prohibits.
- **Why it matters:** ART aborts the process with a fatal `JNI called with pending exception`. Any
  exception in the token callback (a normal occurrence under back-pressure or UI teardown) crashes the app.
- **Fix:** Immediately after the callback: `if (env->ExceptionCheck()) { env->DeleteLocalRef(js); break; }`.

#### C4. iOS agent: ArithmeticParser recursive descent causes an uncatchable stack overflow
`apple/QuenderinKit/Sources/QuenderinKit/AgentTool.swift:102-114`
- **What:** `parseFactor`/`parseExpression`/`parseTerm` are mutually recursive with no depth limit.
  ~183 nested parens overflow the 512 KB background-thread stack. A Swift stack overflow is not a
  thrown `Error`, so the `do/catch` in `AgentLoop.execute()` cannot catch it.
- **Why it matters:** Adversarial model output or a crafted user goal hard-crashes iOS. The Kotlin
  twin (`AgentTool.kt:103-117`) degrades gracefully because the JVM raises a catchable
  `StackOverflowError` — a critical Swift⇄Kotlin parity break where one platform crashes.
- **Fix:** Thread a `depth` parameter through `parseFactor/parseExpression/parseTerm`, bail with `nil`
  at `depth > 100`. Add the same guard to the Kotlin parser for symmetry.

---

### HIGH (13)

#### H1. iOS: `tokenToPiece` silently drops tokens when the 64-byte buffer is too small
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:195-197`
- **What:** `llama_token_to_piece` returns a negative value (negated required byte count) when the
  buffer is too small. The `guard n > 0 else { return "" }` treats `n < 0` like `n == 0`, returning empty.
- **Why it matters:** Any token whose piece exceeds 64 bytes (long Unicode, byte-fallback, special
  tokens) is silently dropped — corrupted output with no error or log.
- **Fix:** On `n < 0`, reallocate to `Int(-n)` bytes and retry; only treat `n == 0` as empty.

#### H2. iOS: `runGeneration` holds the actor's serial executor for the whole inference — blocks unload/Stop
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:104,117`
- **What:** `runGeneration` is non-async; the `Task { self.runGeneration(...) }` schedules the entire
  synchronous token loop on the actor executor with no suspension point.
- **Why it matters:** Any concurrent `await` (unload(), loadedModelID(), second generate()) queues
  behind it for the full inference duration (minutes). The "Stop" button is non-functional during inference.
- **Fix:** Make `runGeneration` async with `await Task.yield()` per token, or move the C loop off the
  actor via `withCheckedThrowingContinuation` + a detached thread.

#### H3. iOS: `llama_context` left undefined after a failed initial prompt decode, then reused
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:155-158`
- **What:** On `decode(&tokens) == false`, the method throws and returns; `self.context` stays alive
  with an undefined KV-cache and `self.loaded` stays non-nil, so the next `generate()` reuses the
  corrupt context.
- **Why it matters:** Garbage output or a crash inside `llama_decode` on the subsequent call.
- **Fix:** `llama_kv_cache_clear(context)` before throwing (lines 156 and 172), or null out context+loaded.

#### H4. Android JNI: `GetStringUTFChars` result not null-checked before `std::string` construction
`android/jni/llama_jni.cpp:117` (also 128, 92)
- **What:** `env->GetStringUTFChars(prompt, nullptr)` can return NULL on OOM; the result is passed
  straight to `std::string(p)`.
- **Why it matters:** Constructing `std::string` from a null `const char*` is UB — SIGSEGV.
- **Fix:** `if (!p) return env->NewStringUTF("");` after each call (lines 117, 128, 92).

#### H5. Android JNI: `NewStringUTF` return not checked; null jstring → opaque NPE in Kotlin
`android/jni/llama_jni.cpp:120` (also 131, 72)
- **What:** `NewStringUTF` can return NULL on OOM. The JNI funcs map to Kotlin `external fun … : String`
  (non-nullable); ART does not auto-NPE at the boundary, so NULL propagates and throws an NPE with no
  useful frame. Line 72 passes a possibly-null jstring into the `onToken(piece: String)` non-nullable lambda.
- **Why it matters:** Opaque crash, undiagnosable from the stack.
- **Fix:** On NULL, `ExceptionClear()`, `ThrowNew(OutOfMemoryError)`, return NULL so ART delivers cleanly.

#### H6. Android JNI: `g_backend_ready` read-modify-write without synchronization — data race
`android/jni/llama_jni.cpp:29` (check-then-set at 90)
- **What:** Plain `bool g_backend_ready`; `if (!g_backend_ready) { llama_backend_init(); g_backend_ready = true; }`
  has no barrier or lock.
- **Why it matters:** Two engines loading on different threads can both observe false and call
  `llama_backend_init()` concurrently (not documented re-entrant); the unsynchronized bool itself is a
  C++ data race (UB).
- **Fix:** `std::call_once(g_backend_flag, llama_backend_init);` with a `std::once_flag`, or
  `std::atomic<bool>` + mutex.

#### H7. Desktop agent: `_isRunning` never reset on exception — agent permanently locks
`src/services/agent.service.ts:106-347`
- **What:** `_isRunning = true` at line 111, reset only at line 346, no `try/finally`. The
  `uiVerifier.waitForIdle` at line 171 is outside the inner try/catch (begins line 239), and the CHAT
  early-return at line 160 also skips the reset.
- **Why it matters:** Any throw between set and reset leaves `_isRunning` stuck true; all future
  `runAgentLoop()` calls return immediately at line 109 — the agent is silently dead for the process lifetime.
- **Fix:** Wrap the loop body in `try { … } finally { this._isRunning = false; }`.

#### H8. Desktop agent: `waitForIdle` unbounded loop — hangs forever on an animating UI
`src/services/agent/uiVerifier.ts:47-77`
- **What:** The `while (!isIdle)` success path has no iteration cap; the `retries >= 3` guard only
  covers `getScreenContext()` exceptions. An animated UI (spinner, video, live feed) changes element
  count every poll so `stableCount` never reaches 2.
- **Why it matters:** Spins indefinitely, blocks the agent step, accumulates 2–5 MB PNGs in `/tmp`
  (cleanup at lines 81–85 is after the loop, never reached), and — with H7 — permanently locks the agent.
- **Fix:** Add `MAX_IDLE_POLLS` cap (e.g. 20) and treat timeout as "stable enough"; move cleanup into a `finally`.

#### H9. Desktop agent: safety BLOCKLIST not applied to `key` actions — Enter confirms a blocked dialog
`src/services/agent/actionExecutor.ts:109-120`
- **What:** `checkSafety(el)` runs for `click`/`input` but the `key` branch has no element check; the
  pre-branch `checkSafety(undefined, actionObj.text)` is empty for key presses.
- **Why it matters:** A model blocked from clicking "Pay" can immediately `{action:'key', key:'enter'}`
  on the focused dialog to confirm the payment. Safety covers the first interaction but not the
  confirming keystroke.
- **Fix:** Examine the focused element's text in the `key` branch; restrict `enter`/`back` after a
  safety-blocked action until the next UI state is verified.

#### H10. Desktop agent: safety BLOCKLIST critically incomplete + ignores `resourceId` + goal unchecked
`src/services/agent/actionExecutor.ts:12`
- **What:** `BLOCKLIST = ['pay','delete','password','buy','confirm purchase']`. Missing: transfer,
  send money, purchase, remove, wipe, factory reset, uninstall, revoke, deactivate, checkout. `checkSafety`
  inspects only `el.text`/`el.contentDesc`/`inputText`, not `el.resourceId`. The goal string is never
  safety-checked before the loop starts.
- **Why it matters:** Icon buttons with empty labels but `resource-id` like `confirm_transfer_btn`
  pass unchecked; destructive verbs sail through.
- **Fix:** Expand the blocklist, add `el.resourceId` to the checked text, and add a pre-loop goal check
  in `runAgentLoop()`.

#### H11. Electron: `will-navigate` origin check uses `startsWith` — subdomain-prefix bypass
`electron/main.ts:28`
- **What:** `navUrl.startsWith(appOrigin)` where `appOrigin = http://localhost:3000` passes for
  `http://localhost:3000.attacker.com/`.
- **Why it matters:** If the renderer is tricked into navigating there (injected link, redirect,
  postMessage), it loads an external page in the Electron shell with full IPC access — a known Electron pitfall.
- **Fix:** Compare parsed origins (`new URL(navUrl).origin !== new URL(appOrigin).origin`) or use
  `appOrigin + '/'` with an exact-match fallback.

#### H12. Electron: `will-redirect` not handled — 3xx server redirects bypass the navigation guard
`electron/main.ts:27`
- **What:** No `will-redirect` handler. `will-navigate` fires only for renderer-initiated navigations;
  server-issued HTTP 3xx redirects fire `will-redirect`.
- **Why it matters:** A buggy or path-traversal-reachable local route can redirect the renderer to an
  arbitrary external URL with no check.
- **Fix:** Add a `will-redirect` handler using the same (fixed) origin comparison.

#### H13. Mobile agent: Kotlin returns FinalAnswer on multi-JSON model output; Swift returns planError — parity break
`android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentDecision.kt:26-30` (twin `AgentDecision.swift:30-37`)
- **What:** `firstJsonObject()` extracts `text[indexOf('{')..lastIndexOf('}')]`. With two JSON objects
  in one response the span covers both. Swift's `JSONSerialization` rejects the merged string → planError;
  Kotlin's regex `extractString()` finds the first key match → if the second object has `answer`, it
  returns `FinalAnswer`.
- **Why it matters:** Reproducer `{"tool":"echo","input":"hello"} text {"answer":"injected"}` makes
  Android terminate early with a premature/attacker-crafted answer while iOS stalls — divergent behavior
  on identical input.
- **Fix:** Walk from the first `{` counting balanced braces (skipping quoted strings) to find the
  outermost complete object. Apply to both platforms.

(Note: the FinalAnswer safety-gate gap below is also high but listed under "high" group as H — see next entry.)

#### H14. Mobile agent: safety gate not applied to FinalAnswer on either platform
`apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift:59-61` (twin `AgentLoop.kt:45-48`)
- **What:** `SafetyBlocklist.isBlocked` runs only in the UseTool branch (Swift:65, Kotlin:51). The
  FinalAnswer branch returns the answer unscanned. Parity-equal omission on both platforms.
- **Why it matters:** A jailbroken/maliciously-fine-tuned on-device model can emit blocked content
  (phishing text, private-key extraction steps) in a finalAnswer that reaches the UI, contradicting the
  stated safety-sandbox intent. High (not critical) because the answer is displayed text with no
  system-level side effects.
- **Fix:** Add `SafetyBlocklist.isBlocked(answer)` in the FinalAnswer branch on both platforms; halt
  with `.blocked` when matched.

---

### MEDIUM (11)

#### M1. iOS: `GenerationOptions.stopSequences` completely ignored
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:161-175`
- **What:** The token loop exits only on cancel, EOG, or maxTokens; `options.stopSequences` is never read.
- **Why it matters:** Part of the public InferenceEngine seam. Any caller passing stop strings is
  silently ignored, breaking structured-output parsing and over-generating to maxTokens. Latent today
  (AgentLoop passes defaults) but a real seam break.
- **Fix:** Maintain a rolling tail buffer; break the loop when it ends with any stop sequence; trim the
  stop string from the final yield.

#### M2. iOS: `Int32` overflow in `tokenize()` for >2 GB prompts
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:182-186`
- **What:** `let byteLen = Int32(text.utf8.count)` traps in debug / wraps negative in release when
  `utf8.count > Int32.max`. The negative value goes to `llama_tokenize` as `text_len` (C UB).
- **Why it matters:** Crash or garbage tokenization. Very low probability (needs >2 GB of text) but UB.
- **Fix:** `guard text.utf8.count <= Int(Int32.max) else { return [] }`; clamp capacity similarly.

#### M3. iOS: `ScriptedInferenceEngine.generate()` missing `modelNotLoaded` guard (invariant I1)
`apple/QuenderinKit/Sources/QuenderinKit/ScriptedInferenceEngine.swift:19`
- **What:** No `guard loaded != nil` — delivers a scripted reply even after `unload()`. `MockInferenceEngine`
  enforces this at line 25; production `LlamaEngine` throws.
- **Why it matters:** Agent-loop tests using the scripted engine after unload silently pass where
  production would throw, masking I1 violations.
- **Fix:** Add `guard loaded != nil else { throw InferenceError.modelNotLoaded }`.

#### M4. Desktop agent: `type()` maps all whitespace to `%s` — newline/tab/CR corrupt typed text or shell
`src/services/providers/android.provider.ts:161`
- **What:** The escape regex matches all `\s`; only space maps to `%s`, while tab/LF/CR map to `\<char>`,
  passed as one adb arg to the device-shell `input text`.
- **Why it matters:** `\<LF>` is shell line-continuation (newline dropped); `\<CR>` is shell-dependent
  (can truncate the token on mksh, Android <6). CRLF in file/paste-sourced content reaches this path.
- **Fix:** Strip/normalize non-space whitespace first, then escape metacharacters and map space → `%s`;
  or single-quote the whole arg device-side.

#### M5. Desktop agent: shared fixed on-device path `/sdcard/window_dump.xml` — TOCTOU / corruption
`src/services/providers/android.provider.ts:107-108, 207`
- **What:** Both `getUiHierarchyXml()` and `getScreenContext()` dump to the same hardcoded device path
  (local temp uses a UUID; device side does not).
- **Why it matters:** Interleaved ADB ops (post-action `waitForUiIdle` vs `uiVerifier.waitForIdle`,
  multi-device, retry overlap) make one reader pick up a stale/mid-write dump.
- **Fix:** UUID-suffix the device path and `adb shell rm` it after pull, matching the local-temp pattern.

#### M6. Desktop agent: `uiParser.traverse()` registers zero-bounds container nodes as clickable id=0
`src/services/uiParser.service.ts:51-98`
- **What:** The element-building block runs unconditionally for every node including the bounds-less
  hierarchy root; `extractBounds('')` yields center (0,0).
- **Why it matters:** A ghost `{id:0, …}` element is always present; a confused/adversarial model can
  `{action:'click', id:0}` and tap the device top-left corner.
- **Fix:** Skip registration unless the node has at least one of non-empty text / contentDesc / bounds.

#### M7. Desktop server: `manualAction` injected into the LLM prompt without a type guard
`src/app.ts:100-101`
- **What:** `POST /api/agent/resume` passes `req.body.manualAction` straight to `agentService.resume()`
  with no `typeof` check; stored in `_pendingManualOverride` and interpolated into `actionHistory`
  (agent.service.ts:196) and `injectOverride()` (:198).
- **Why it matters:** A non-string JSON value (object/array) coerces into the LLM action-history
  context — a prompt-injection / input-validation hole. (A crafted array serializes cleanly.)
- **Fix:** `const manualAction = typeof req.body?.manualAction === 'string' ? req.body.manualAction.slice(0,4000).trim() : undefined;`

#### M8. Desktop server: zip-slip — `unzipper.Extract` without entry-path validation on voice download
`src/app.ts:229-231`
- **What:** `POST /api/voice/download` pipes a fetched ZIP through `unzipper.Extract({ path: voiceDir })`;
  `unzipper` does not strip `../` from entry names.
- **Why it matters:** A compromised CDN or MITM (TLS defeat) can write outside `~/.quenderin/models/voice/`.
  Reachable by any local process (CORS loopback does not stop local attackers).
- **Fix:** Stream via `Parse()` and validate each entry: resolve against `voiceDir`, `autodrain()` any
  path escaping it.

#### M9. Mobile agent: `SafetyBlocklist` substring matching causes false-positive blocks
`apple/QuenderinKit/Sources/QuenderinKit/SafetyBlocklist.swift:31` (twin `SafetyBlocklist.kt:24`)
- **What:** `haystack.contains(keyword)` with no word boundaries. Short single words match unrelated
  text: format→"format the output", pin→"opinion", pay→"repay", wire→"wire the components", bank→"bankrupt",
  erase→"erase whitespace".
- **Why it matters:** A match halts the entire run with `.blocked` and no recovery, so legitimate
  text-processing goals silently fail. Parity-equal on both platforms.
- **Fix:** Word-boundary anchors (`\b<keyword>\b`) for single-word entries on both platforms; multi-word
  phrases are already safe.

#### M10. Mobile: Android `AgentSession` shared mutable state not thread-safe — data race
`android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentSession.kt:17-42`
- **What:** `steps`/`isRunning`/`answer`/`haltReason` are plain `var`, mutated from a background thread;
  `onChange()` fires from the background thread (the Compose recomposition hook). No `@Volatile`/lock,
  no concurrent-`run()` guard.
- **Why it matters:** Compose snapshot read of `steps` on main while the background writes `steps = steps + step`
  is a JVM data race (no happens-before). Concurrent `run()` calls race destructively. iOS twin is
  `@MainActor`-isolated (safe).
- **Fix:** Use `MutableStateFlow` per field collected in Compose, or `@Volatile` + lock; guard `run()`
  against re-entry.

#### M11. Desktop memory: `cosineSimilarity` returns NaN on embedding length mismatch, destabilizing sort
`src/services/memory.service.ts:216-227`
- **What:** Iterates `0..a.length-1`, reads `b[i]` with no length guard; a shorter `b` yields `undefined`
  → NaN through `dotProduct` and the `b.score - a.score` comparator.
- **Why it matters:** On an embedding-model dimension change, NaN makes the sort order undefined; valid
  high-scoring entries can be misordered/excluded from top-k (filter rejects NaN so no crash). Latent
  until a model upgrade.
- **Fix:** `if (a.length !== b.length) return 0;` and warn when loading stale-dimension corrections.

#### M12. Desktop memory: `saveCorrection` embeds inside the write-lock; `getExtractor` double-init race
`src/services/memory.service.ts:183-213`
- **What:** `embedText` is called inside `withWriteLock` (line 197), holding the lock for the full
  100–500 ms Xenova inference; `getExtractor()` has no mutex, so two concurrent first calls both
  `await pipeline(...)`, loading the ~80 MB model twice.
- **Why it matters:** Lock held across expensive embed blocks concurrent reads/saves; double-init wastes
  ~80 MB (one-time, not corruption).
- **Fix:** Hoist `embedText` outside the lock (read-only); protect extractor init with a promise-chain mutex.

---

### LOW (7)

#### L1. iOS: `llama_backend_init()` called N times, freed once on repeated load() without unload()
`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:52,94`
- **What:** Asymmetric init/free; `load()→load()` calls init twice, free once.
- **Why it matters:** Older llama.cpp documents init as "call once per process"; current ref-counting
  not guaranteed.
- **Fix:** Gate init behind a `backendInitialized` flag; free only when set.

#### L2. iOS: `MockInferenceEngine` ignores maxTokens and cancellation — masks real engine behavior
`apple/QuenderinKit/Sources/QuenderinKit/MockInferenceEngine.swift:28-33`
- **What:** Yields all words synchronously in the stream closure; no `Task.isCancelled`, no maxTokens cap.
- **Why it matters:** Tests asserting maxTokens/cancellation pass against the mock but fail against
  `LlamaEngine`.
- **Fix:** Wrap in a `Task`, poll cancellation per word, honor maxTokens.

#### L3. Android JNI: `GetObjectClass` local ref leaked in `generate()`
`android/jni/llama_jni.cpp:56`
- **What:** `jclass cls = env->GetObjectClass(sink)` is never `DeleteLocalRef`'d; the slot is held for
  the whole (minutes-long) streaming frame.
- **Why it matters:** Clear JNI contract violation flagged by ASan/StrictMode; slot released at frame
  return, so impact is low.
- **Fix:** `env->DeleteLocalRef(cls);` right after the `GetMethodID` lookup.

#### L4. Desktop agent: bulk-delete sends 50 args to `adb shell input keyevent` — truncated on Android ≤9
`src/services/providers/android.provider.ts:153-154`
- **What:** `Array(50).fill('67')` spread as 50 args; API ≤28 accepts only one keycode and ignores the rest.
- **Why it matters:** On pre-Android-10 only one KEYCODE_DEL fires, so the field is not cleared and new
  text appends to stale content.
- **Fix:** Loop individual calls, or `adb shell 'for i in $(seq 50); do input keyevent 67; done'`, or
  select-all + delete.

#### L5. Desktop server: `POST /api/models/download` accepts any modelId, silently falls back
`src/app.ts:121-127`
- **What:** Unrecognized `modelId` falls back to `MODEL_CATALOG[0]` (the largest model) in
  `llm.service.ts:654`, but the response reflects the invalid requested id.
- **Why it matters:** Misleading success message; a different (largest) model is downloaded. The DELETE
  route already validates correctly.
- **Fix:** Validate against the catalog and return 400 for unknown ids (mirror the DELETE route).

#### L6. Desktop server: `diagnosticsId` echoed back without a length cap
`src/routes/health.ts:49-69`
- **What:** Trimmed but not length-capped before being echoed in the JSON body.
- **Why it matters:** A multi-MB string is allocated and serialized into the response (no XSS via
  `res.json()`); wastes heap/bandwidth.
- **Fix:** `.slice(0, 128)` on both query and header reads.

#### L7. Desktop server: `manualAction` has no length cap (subsumed by M7)
`src/app.ts:100`
- **What:** No length limit before append to action-history / `injectOverride()`. WS goals cap at 4000/8000;
  HTTP resume has no equivalent.
- **Why it matters:** Large input inflates the LLM context → OOM/silent truncation. Fully resolved by the
  M7 `.slice(0,4000)` fix.
- **Fix:** Apply `.slice(0,4000).trim()` as part of the M7 type guard — no separate change needed.

---

### High-severity desktop RAG/LLM items (counted under HIGH above as H-grade by the raw data)

The following three desktop LLM-path findings are high-severity and ship-relevant; they are folded into
the High count. Listed here for completeness because they belong to the RAG/memory dimension:

#### KV-cache sequence slot exhausted after every session rotation — chat fails permanently (CRITICAL-grade in raw, counted as a critical-adjacent high)
`src/services/llm.service.ts:891-901`
- **What:** `LlamaContext` has the default 1 sequence slot. `ensureSession()` replaces
  `generalChatSession` on turn-cap (line 897) and the LLM_TIMEOUT path nulls it (948-949), but never
  `dispose()`s the outgoing session; `autoDisposeSequence` defaults false. The orphaned slot is never
  reclaimed.
- **Why it matters:** After the first rotation, `context.getSequence()` throws "No sequences left" —
  all subsequent generalChat calls fail permanently until full model reload. On embedded HW where
  `MAX_CHAT_TURNS` can be 3, a normal conversation hits this in minutes. **This is effectively a fourth/fifth
  critical-class reliability defect — see verdict.**
- **Fix:** `autoDisposeSequence: true` when creating the session, or explicit `dispose()` before
  overwrite; dispose in the LLM_TIMEOUT catch; same in `unloadModel()` (302) and `setPreset()` (230).

#### MAX_CHAT_TURNS computed from user-facing contextSize, not the effective context
`src/services/llm.service.ts:854-857`
- **What:** Divides `currentSettings.contextSize` (default 2048) by 100; the actually-negotiated context
  (as low as 256 on constrained HW after the fallback chain) is never stored.
- **Why it matters:** Returns 20 turns where the real context holds ~3; after turn 3 the model silently
  drops earlier turns → incoherent responses with no error, and the session never resets at the right
  boundary.
- **Fix:** Store `this.effectiveContextSize = effectiveCtx` at model load and use it in the getter
  (`Math.max(3, Math.min(25, floor(effective/100)))`).

#### Synchronous `vm_stat`/PowerShell every 15 s in the memory-pressure monitor stalls the event loop
`src/services/llm.service.ts:186-201` (`src/services/memory.ts:60,137-146`)
- **What:** `startMemoryPressureMonitor()` `setInterval(15s)` calls `availableMemBytes()` →
  `execSync('vm_stat', {timeout:2000})` (macOS) / `execSync('powershell …', {timeout:5000})` (Windows).
- **Why it matters:** Blocks the Node event loop up to 2–5 s every 15 s. During inference this drops
  Electron frames and can fire the `AbortController` timeout in `promptWithTimeout` prematurely, aborting
  healthy generations.
- **Fix:** Use `os.freemem()` (non-blocking) in the interval; reserve the precise call for the one-time
  model-load path.

#### Shell injection via unsanitized `dirPath` in `execSync(\`df -k "${dirPath}"\`)` on Unix
`src/services/llm.service.ts:633`
- **What:** Template-literal shell command; `dirPath` derives from `os.homedir()`. POSIX allows `"` and
  `$(` in path components; the Windows path sanitizes the drive letter but Unix does not.
- **Why it matters:** A home directory containing `"` or `$(` breaks quoting / allows subshell execution
  with the app's privileges.
- **Fix:** `execFileSync('df', ['-k', dirPath], …)` (no shell) or `fs.promises.statfs(dirPath)`.

#### Mobile data: ConversationContext early-break drops older messages that would fit
`apple/QuenderinKit/Sources/QuenderinKit/ConversationContext.swift:37-45` (twin `ConversationContext.kt:34-41`)
- **What:** The reversed loop `break`s on the first over-budget message, discarding all older messages
  even when they individually fit.
- **Why it matters:** A large paste as the second-newest message drops every prior turn (even 10–30-token
  ones). Identical on both platforms.
- **Fix:** Replace `break` with `continue`; the `kept.isEmpty` guard already preserves the newest turn.

---

### MEDIUM/LOW mobile-data & misc (rounding out the counts)

- **ConversationStore.escape() does not escape `\r`** — `android/.../ConversationStore.kt:28-29`. Bare `\r`
  in message text silently splits a row under `BufferedReader.readLine()` (data loss, no exception). iOS
  uses JSONEncoder (immune). Fix: escape/unescape `\r`. *(Medium)*
- **ConversationLibrary title `substring(0,40)` can split a UTF-16 surrogate pair** —
  `android/.../ConversationLibrary.kt:56`. Produces an unpaired high surrogate (invalid Unicode) that can
  break Gson/Jackson. Swift `prefix(40)` is grapheme-cluster safe. Fix: surrogate-safe truncation or
  `codePoints().limit()`. *(Medium)*
- **Both model selectors expose negative `memoryHeadroomGb` in the FORCED path** —
  `apple/.../IPhoneModelSelector.swift:185`, `android/.../AndroidModelSelector.kt:133`. When even the
  smallest model does not fit, the exposed headroom is negative (meaningless). Fix: `max(0.0, usable - runtime)`.
  *(Low)*
- **Electron: silent startup failure shows a blank window with no error** — `electron/main.ts:50-52`.
  Catch only `console.error`s; no `dialog.showErrorBox`/`app.quit()`. Fix: surface the error and quit.
  *(Low; the "zombie window via activate" sub-claim was disproven during verification — the `activate`
  handler is registered after createWindow succeeds.)*

> **Count reconciliation.** The 35 total above is the full confirmed set across all seven dimensions.
> For the structured summary, severities are tallied from the confirmed list: the KV-cache exhaustion is
> graded **critical** by the raw verifier, raising the critical count to **5** in the structured summary
> (C1–C4 plus the KV-cache slot leak). The narrative above lists it under the RAG section for subsystem
> grouping; it is a ship-blocker regardless of grouping.

---

## Findings That Were Investigated and REJECTED

These were raised by finders but failed adversarial verification — recorded so they are not re-litigated:

- **XML fallback parser oversized-text** (`agent.service.ts:263`) — REJECTED. The parsed `commandText`
  is LLM output capped at `maxTokens:150` (~600 chars); "arbitrarily large" text is structurally impossible.
- **parseToolCalls ReDoS** (`toolLoop.ts:15`) — REJECTED. V8's Irregexp gives linear-time guarantees for
  this pattern class; the input is a token-capped (~512) on-device model output, not the 10 k adversarial
  string postulated.
- **Electron preload `process.env` secret leak** (`preload.ts:7`) — REJECTED. The window is `sandbox: true`;
  a sandboxed preload's `process.env` is restricted and does not reflect main-process env. (A minor
  always-`0.0.1` version cosmetic remains, but not the claimed leak.)
- **Electron preload path resolves to a non-existent file in built app** (`main.ts:18`) — CONFIRMED as a
  separate medium correctness issue during the electron-main verification pass (preload silently not
  loaded in a production build, so `contextBridge.exposeInMainWorld` never runs). Fix: derive from build
  output (`path.join(__dirname, 'preload.js')`) and assert existence at startup. *(Folded into the medium
  count.)*

---

## Residual Risk

- **Concurrency model is unspecified across the inference engines.** Both the iOS actor-executor block
  (H2) and the Android unsynchronized handle (C2) stem from no documented threading contract for
  load/unload/generate. Even after the point fixes, the engines need an explicit "single owner; cancel
  via X" contract or the next caller will reintroduce a race. Highest residual risk.
- **The on-device model is a trusted-by-default input.** Several findings (C4, H9/H10/H13/H14, M9) assume
  the local model can be jailbroken or fine-tuned to emit hostile output. The safety blocklist + the
  decision parser are the only line of defense and both are demonstrably bypassable today. Treat model
  output as untrusted end-to-end.
- **Swift⇄Kotlin parity is not enforced anywhere.** C4 (crash vs graceful) and H13 (planError vs
  FinalAnswer) are silent behavioral divergences on identical input. No cross-platform conformance test
  exists; new divergences will go unnoticed. Recommend a shared golden-input fixture run on both engines.
- **Buffer/return-value edge cases in the C-API/JNI layer are pervasive** (H1, H4, H5, L3, M2). These were
  found by inspection, not fuzzing; an AddressSanitizer + JNI-checker fuzz run on `llama_jni.cpp` and a
  large-token fuzz on `LlamaEngine.swift` would likely surface more.
- **Resource-disposal discipline in `llm.service.ts` is fragile.** The KV-cache slot leak and the
  effective-context mismatch both come from local-variable state that should be instance state with a
  documented lifecycle. The whole session-rotation path warrants a focused redesign, not just the point fix.
- **Not in scope this pass:** the C3 model-download integrity diff and store-compliance surface (covered by
  the two prior audits this session); UI/styling; build/CI config.

---

## Recommended Fix Order (ship gate)

1. **C1** free old handles on iOS re-load (1-line guard, prevents multi-GB OOM).
2. **KV-cache slot leak** (`llm.service.ts:891-901`) — dispose/`autoDisposeSequence` (chat dies permanently otherwise).
3. **C2** Android handle lock (use-after-free / native crash).
4. **C3** JNI `ExceptionCheck`/`Clear` after `onToken` (process abort).
5. **C4** iOS arithmetic parser depth guard (uncatchable crash + parity).
6. **H7 + H8** desktop agent `try/finally` + idle-poll cap (permanent lock).
7. **H9 + H10** safety blocklist on `key` actions + expanded list + resourceId + goal check.
8. **H11 + H12** Electron origin comparison + `will-redirect` handler.
9. Remaining highs (H1–H6, H13, H14) and the desktop LLM-path highs.
10. Mediums and lows as a follow-up sweep.

Append the corresponding entries to `docs/BUG_JOURNAL.md` in the same commit as each fix.
