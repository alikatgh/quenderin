# Quenderin bug hunt — 2026-08-09

**Method:** digest-first, subsystem-scoped bug hunt. One cheap digest pass mapped the shared
files (key functions, line ranges, invariants) so no finder re-read the large shared sources
from scratch. Scoped finders then ran per subsystem (android, off-grid-mobile, apple,
core/ui, tests/scripts), each restricted to its own files. Every subsystem's raw findings
were handed to **one batched adversarial verifier per subsystem** — a fresh context that read
that subsystem's files once and applied **both lenses** to all of its findings together:

1. **Correctness lens** — does the cited code actually do what the finding claims, at the
   cited lines, with the cited control flow?
2. **Reachability lens** — can a real user / real call site / real deployment actually reach
   that state, or is the path structurally impossible (guards upstream, UI disabled, dead
   branch, race window not achievable by a human)?

A finding survives only if it passes both. Refute-by-default: the verifier's job was to kill
findings, not to confirm them.

**Result:** 15 raw findings → **12 confirmed**, 3 refuted. No criticals. Machine-readable
detail (including each verifier's full reasoning) lives in
`2026-08-09-quenderin-bughunt.raw.json` next to this file.

---

## Summary

| Subsystem | Raw findings | Confirmed | Refuted |
|---|---|---|---|
| android (JNI + quenderin-core Kotlin) | 4 | 2 | 2 |
| off-grid-mobile (RN) | 2 | 2 | 0 |
| apple (QuenderinKit) | 3 | 3 | 0 |
| core / ui (React + agent server) | 3 | 2 | 1 |
| tests / scripts (maintenance tooling) | 3 | 3 | 0 |
| **Total** | **15** | **12** | **3** |

Confirmed by severity: **5 high**, **6 medium**, **1 low**.

| # | Sev | Subsystem | Location | Title |
|---|---|---|---|---|
| 1 | HIGH | android | `android/jni/llama_jni.cpp:416` | q8_0→F16 KV-cache fallback keeps the q8_0-sized `n_ctx`, ~2× the intended KV memory |
| 2 | HIGH | apple | `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift:148` | Fresh-download SHA-256 resolved via curated catalog lookup — HF/sideloaded models skip the hash check |
| 3 | HIGH | offgrid | `off-grid-mobile/src/services/activeModelService/loaders.ts:107` | Load timeout doesn't cancel the loser — concurrent native init leaks a `LlamaContext` |
| 4 | HIGH | offgrid | `off-grid-mobile/src/screens/ChatScreen/useChatGenerationActions.ts:290` | Stop routed through `llmService` instead of `generationService` — next send silently dropped |
| 5 | HIGH | tests | `scripts/refresh_model_hashes.py:129` | Hash patcher inserts sha256 after a named `languagesLabel` arg — emits uncompilable Kotlin |
| 6 | MEDIUM | apple | `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift:63` | `persist()` no-ops mid-generation — switching conversations silently loses the just-sent message |
| 7 | MEDIUM | android | `.../core/JvmDownloadIO.kt:46` | HTTP 206 trusted without validating the `Content-Range` **start** before appending |
| 8 | MEDIUM | core | `ui/src/components/PrivacyLock.tsx:13` | Brute-force lockout lives only in component state — a page reload resets it |
| 9 | MEDIUM | core | `ui/src/hooks/useAgentSocket.ts:265` | Truthy check on `data.answer` renders a successful empty answer as the halt text "answered" |
| 10 | MEDIUM | tests | `scripts/build_xcstrings.py:26` | Format-specifier check compares an unordered multiset — position/type transposition passes |
| 11 | MEDIUM | tests | `scripts/merge_kja_zh_1.py:137` | OR-guard, AND-write: one empty column causes all three to be overwritten |
| 12 | LOW | apple | `apple/QuenderinKit/Sources/QuenderinKit/ChatModel.swift:104` | `continueLast()` drops the model → Continue always uses the `.small` tier system prompt |

---

## Confirmed findings

### #1 [HIGH] q8_0→F16 KV-cache fallback keeps the q8_0-sized `n_ctx`
- **Location:** `android/jni/llama_jni.cpp:416` (android) — category: resource-management
- **Symptom:** After a failed q8_0 KV-cache context init, the F16 retry reuses an `n_ctx` that
  was sized assuming q8_0's smaller per-token footprint, roughly doubling actual KV-cache
  memory on exactly the memory-tight devices the sizing exists to protect.
- **Failure scenario:** `KVCachePolicy.recommend()` picks `Q8_0` only when headroom < 1.2 GB
  (e.g. `appBudgetGb=1.8`, `modelWeightsGb=0.9` → headroom 0.765 GB).
  `ContextWindow.recommend(appBudgetGb, modelWeightsGb, Q8_0)` then scales `n_ctx` by `/0.53`
  (~1.9×) versus the F16-safe value: base 2048 for that bracket → `n_ctx = 3840`. `nativeLoad`
  (llama_jni.cpp:412-415) sets `cp.type_k/type_v = GGML_TYPE_Q8_0` and calls
  `llama_init_from_model` with `cp.n_ctx = 3840`. If that init fails because the model/backend
  lacks flash-attention support for a quantized V-cache (a real llama.cpp constraint, explicitly
  anticipated by the comment at 408-411 and the retry at 417-425), the code retries with an F16
  KV cache at the **same** `cp.n_ctx = 3840` (422-424) instead of recomputing `n_ctx` for F16
  (2048 for that headroom). F16 costs ~1.9× more per token, so the allocation is sized for a
  budget the device doesn't have — native-heap OOM / low-memory kill mid-conversation.
- **Suggested fix:** On the q8_0→f16 fallback, recompute a safe `n_ctx` for F16 — either reuse
  `ContextWindow.recommend(appBudgetGb, modelWeightsGb, KVCacheType.F16)` on the Kotlin side and
  pass it down, or shrink `cp.n_ctx` by the `KVCacheType.Q8_0.relativeCostPerToken` ratio before
  retrying — so the fallback context never exceeds the memory budget the original sizing assumed.
- **Verifier (high confidence):** Confirmed against llama_jni.cpp:394-426. `cp.n_ctx` is set once
  from the Kotlin-computed `context_tokens` (sized for q8_0's 0.53× cost) and is never recomputed
  on the F16 retry at 421-424 — only `type_k`/`type_v` change back. Cross-checked
  `KVCachePolicy.kt` and `ContextWindow.kt`: the 3-arg `recommend()` scales base `n_ctx` by
  `1/relativeCostPerToken`, so a q8_0-sized 3840 is genuinely ~1.9× the F16-safe 2048 for the same
  headroom. The comment block at 408-411/418-420 documents this fallback as an anticipated real
  scenario (models whose `FLASH_ATTN_TYPE_AUTO` resolves to disabled), so it is not a dead path.

### #2 [HIGH] Fresh-download SHA-256 is resolved by curated-catalog URL lookup
- **Location:** `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift:148` (apple)
- **Symptom:** Any model outside the compiled-in `ModelCatalog` — every sideloaded or
  Hugging-Face-searched GGUF — silently skips SHA verification on first download.
- **Failure scenario:** A user searches Hugging Face and installs a community GGUF.
  `HuggingFaceCatalog.candidate(from:label:)` correctly populates `ModelEntry.sha256` from HF's
  LFS oid (HuggingFaceModelSearch.swift:176), and `OnboardingModel.install()` correctly
  re-verifies the SHA for an already-cached file (OnboardingModel.swift:199, `model.sha256`).
  But `ModelDownloader`'s protocol `download(from:to:)` takes only a URL/destination — not the
  `ModelEntry` — so `ChunkedDownloadDelegate`'s completion handler must re-derive the hash via
  `ModelCatalog.models.first { $0.downloadURL == sourceURL }?.sha256` (line 148).
  `ModelCatalog.models` is the small curated compiled-in list and never contains an HF-search or
  sideloaded entry, so the lookup always returns `nil` for those downloads. `ModelIntegrity.verify`
  then falls back to a magic-header-only check (the bug journal's C3-2 "integrity gate downgrade"
  pattern), so a MITM'd or corrupted community-model download that keeps a valid GGUF header passes
  silently — on the very path (untrusted, community-uploaded files) where SHA checking matters most,
  and while the correct hash was already in hand at the call site.
- **Suggested fix:** Thread the expected hash through the call instead of re-deriving it: add
  `expectedSHA256: String?` to `ModelDownloader.download(from:to:)` and `ChunkedDownloadDelegate`'s
  init, have `OnboardingModel.install()` pass `model.sha256`, and use it in place of the
  `ModelCatalog.models.first { ... }` lookup at line 148.
- **Verifier (high confidence):** Confirmed across ModelDownloader.swift, OnboardingModel.swift,
  ModelCatalog.swift, HuggingFaceModelSearch.swift and ModelIntegrity.swift. The HF candidate's
  `huggingface.co` download URL is never in the curated array, so line 148 yields `nil` for every
  HF/sideloaded install. `OnboardingModel.install()` line 199 demonstrably already has and uses
  `model.sha256` for the cached-file path, while line 248's
  `downloader.download(from: url, to: destination)` passes no hash at all — the value was available
  and simply not threaded through. Both lenses pass.

### #3 [HIGH] Load timeout doesn't cancel the loser — concurrent native init leaks a context
- **Location:** `off-grid-mobile/src/services/activeModelService/loaders.ts:107` (offgrid) —
  category: concurrency / native-handle leak
- **Symptom:** The `Promise.race` timeout around `llmService.loadModel()` abandons but does not
  cancel the native load; a retry can race it and orphan a multi-GB `LlamaContext`.
- **Failure scenario:** User selects large model A; load exceeds `timeoutMs` (default 120 s).
  `doLoadTextModel`'s `Promise.race` rejects, `ctx.onError()` resets `loadedTextModelId` to null,
  `ctx.onFinally()` clears `textLoadPromise` — but `llmService.loadModel(A)` (llm.ts:53-88) keeps
  running natively since nothing awaits or cancels it. The user then retries with model B (the
  natural "try a smaller model" reaction): `loadTextModel('B')` sees `loadedTextModelId === null`
  and skips the unload-before-load branch (loaders.ts:87-90); llm.ts's guard (54-55) also sees
  `this.context` still null (A hasn't finished) and proceeds into a **second concurrent**
  `initContextWithFallback()`. Whichever native init finishes last silently wins `this.context`;
  the other's `LlamaContext` is never released — a multi-GB native leak — and JS state
  (`loadedTextModelId = B`) can diverge from which model is actually resident natively.
- **Suggested fix:** Give `llmService.loadModel()` its own reentrancy guard (an in-flight
  `loadingPromise` it joins, like `ActiveModelService`'s `textLoadPromise` but inside llm.ts), so a
  second call always waits for or supersedes-and-frees the first. At minimum, on an
  ActiveModelService-level timeout keep a reference to the still-pending promise and release
  whichever context eventually wins, rather than abandoning it.
- **Verifier (high confidence):** `Promise.race` only races `doLoadTextModel`'s own await; it never
  cancels or awaits A's `initContextWithFallback()`. `onFinally` clears `textLoadPromise` and
  `onError` clears `loadedTextModelId` synchronously before the outer promise settles, so an
  immediate retry skips both the wait-lock (index.ts:67) and the unload branch. Inside
  `loadModel(B)` the guards at llm.ts:54-55 key off `this.context`, still null. There is no
  single-flight lock anywhere in llm.ts or activeModelService, and no cancellation path for the
  loser's context.

### #4 [HIGH] Stop routed through `llmService` instead of `generationService`
- **Location:** `off-grid-mobile/src/screens/ChatScreen/useChatGenerationActions.ts:290`
  (sibling: `useChatModelActions.ts:217`) (offgrid) — category: state desync / lifecycle
- **Symptom:** These call sites bypass `generationService`'s abort bookkeeping, so the service
  still believes a generation is in flight and silently swallows the user's next message; a model
  unload can also proceed without confirming the native generation finished.
- **Failure scenario:** Mid-stream, the user deletes the active conversation.
  `executeDeleteConversationFn` (289-292) awaits `llmService.stopGeneration()` (native stop signal +
  llm.ts's own flag) and calls `chatStore.clearStreamingMessage()`, but never calls
  `generationService.stopGeneration()` — unlike `handleStopFn` (272-275), which correctly calls
  both. `generationService.state.isGenerating` (generationService.ts:126) stays true until the
  original `generateResponse()`'s `onComplete` fires, once the native `completion()` promise
  settles. If the user switches conversation and sends a message before then, `generateResponse()` /
  `generateWithTools()` hit the early-return guard (generationService.ts:115-118 / ~198-201,
  "Already generating, ignoring request") and the message is **silently dropped with no error
  surfaced**. Separately `handleUnloadModelFn` (useChatModelActions.ts:214-219) does the same and
  then calls `activeModelService.unloadTextModel()` → `llmService.unloadModel()` →
  `context.release()` (llm.ts:137-146) without waiting for the in-flight `completion()` to resolve.
- **Suggested fix:** Route every "stop generation before doing X" call site through
  `generationService.stopGeneration()` (which already awaits `llmService.stopGeneration()` and
  resets `abortRequested` / `tokenBuffer` / `flushTimer` / `isGenerating`), never
  `llmService.stopGeneration()` directly. Additionally, have `unloadTextModel()` await
  `generationService`'s in-flight generation settling (not just `chatStore.isStreaming`) before
  calling `unloadModel()`.
- **Verifier (medium confidence):** Both call sites confirmed at their actual lines (289-291 and
  214-217), contrasted with `handleStopFn` (271-275) which calls both. `state.isGenerating` is only
  cleared via `resetState()`, reachable only from the `onComplete` callback wired into
  `llmService.generateResponse()` (158-169) or from `generationService.stopGeneration()` itself
  (258-277) — neither triggered by a bare `llmService.stopGeneration()`. The early-return guards
  are real, so the dropped-message path is JS-level verifiable without any native timing
  assumptions. The secondary `context.release()`-races-native-decode claim depends on llama.rn's
  `stopCompletion()` blocking semantics, unverifiable from this repo — treated as corroborating
  detail, not the load-bearing part.

### #5 [HIGH] `refresh_model_hashes.py` emits uncompilable Kotlin
- **Location:** `scripts/refresh_model_hashes.py:129` (tests)
- **Symptom:** `patch_kotlin()` inserts the sha256 before the line's **last** `)`, i.e. after a
  trailing named `languagesLabel = "..."` argument — a positional arg after a named arg, which
  does not compile in Kotlin.
- **Failure scenario:** `check_catalog_parity.py`'s own Kotlin regex (line 78) documents that a
  `ModelEntry(...)` call may end with an optional trailing `, languagesLabel = "..."` **after** the
  optional positional sha256, and `export_catalog.py`/`constants.ts` already support a per-model
  `languages` field, so this shape is real. `patch_line()` (123-129) matches the id by prefix and
  then blindly runs `re.sub(r"\)(\s*,?\s*)$", ..., line, count=1)`, matching the final `)`
  regardless of what precedes it. So
  `ModelEntry("gemma3-4b", ..., "url", languagesLabel = "ru"),` becomes
  `ModelEntry("gemma3-4b", ..., "url", languagesLabel = "ru", "<hash>"),` — breaking the Android
  build the next time anyone runs this maintenance script.
- **Suggested fix:** In `patch_line()`, locate the insertion point relative to the
  `languagesLabel = "..."` clause when present (insert immediately before `, languagesLabel`), and
  only fall back to "before the final `)`" when it isn't. Fix the idempotent-removal regex on the
  preceding line for the same reason — it only matches a hash immediately followed by `)`, so it
  can't find or replace an existing hash sitting before a `languagesLabel` clause.
- **Verifier (high confidence):** Traced against the actual current `ModelCatalog.kt`: **every**
  entry (lines 56-68) already ends `..., "<hash>", languagesLabel = "..."),`. The drop-existing-hash
  regex on line 128 (`,\s*{HEX64}(\s*\))`) requires the hash to be immediately followed by `)`, so
  it never matches and the old hash survives; line 129 then appends a **second, duplicate** hash as
  a bare positional arg after the named one. Not hypothetical — it reproduces on every current entry
  in the real file, directly contradicting the module's own "idempotent — re-running updates
  existing sha256 values in place" claim.

### #6 [MEDIUM] `persist()` no-ops mid-generation — conversation switch loses the sent message
- **Location:** `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift:63` (apple)
- **Symptom:** Switching, starting, or opening a conversation while a reply is streaming silently
  discards the just-sent user message (and any partial reply) with no save and no warning.
- **Failure scenario:** User opens a saved conversation (`savedCount = N`), types a new message;
  `ChatModel.send()` appends the user turn (`messages.count = N+1`) and streams a reply with
  `isGenerating == true`. Before it finishes the user taps another history item (`open(otherID)`)
  or "New Chat" (`startNew()`). Both call `persist()` first (63-69, 76, 85), but its guard
  `!chat.isGenerating` fails, so nothing is saved and `savedCount` never advances past N.
  Immediately after, `chat.restore(...)` / `chat.reset()` cancels the engine and replaces or wipes
  `chat.messages` (ChatModel.swift:233-244). The typed message and any streamed tokens are gone from
  both the live chat and the store — violating the app's own "persist on turn + switch" invariant.
- **Suggested fix:** Before restoring/resetting on a mid-generation switch, either (a) stop
  generation and persist the transcript through the last completed message (trimming the in-flight
  assistant placeholder) instead of skipping the save, or (b) block the switch while
  `chat.isGenerating` and reflect that in the UI (disable New Chat / history taps during
  generation).
- **Verifier (high confidence):** `persist()` (line 64) guards on `!chat.isGenerating`; the code's
  own comment acknowledges `startNew()`/`open()` "can run mid-stream." Grepping all `isGenerating`
  usages in `apple/` shows **no** `.disabled(chat.isGenerating)` on the New-chat toolbar button
  (ConversationHistoryView.swift:70) or on `onOpen`/list-row taps — only the composer's send control
  is disabled. The `onChange(of: isGenerating)` → persist handlers only fire on the *original*
  conversation's stream lifecycle and don't help once `messages` has already been replaced. This is
  not merely the acknowledged "don't save the partial assistant placeholder" tradeoff — the fully
  typed user message is lost too.

### #7 [MEDIUM] HTTP 206 trusted without validating the `Content-Range` start
- **Location:** `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt:46`
  (android) — category: correctness
- **Symptom:** A resumed download treats any 206 as a valid resume, so a non-compliant
  server/proxy can silently misalign the appended bytes.
- **Failure scenario:** `JvmHttpRangeClient.open()` sends `Range: bytes=$offsetBytes-` and sets
  `resumed = true` on any `HTTP_PARTIAL` (line 46); `totalBytes()` (66-77) parses only the total
  size out of `Content-Range`, never the range **start**. The caller
  (`ModelDownloadEngine.download`) then appends the body straight onto the existing `.part` file via
  `JvmFileSink.append` (seek-to-end, write). If a CDN/proxy returns 206 but actually serves from
  byte 0 (ignoring `Range` while still using 206), the appended bytes are the wrong slice and the
  `.part` file is corrupted where the segments meet. The project's own `docs/BUG_JOURNAL.md`
  records this exact pattern (H9: "verify a 206's Content-Range start before appending") as already
  fixed on the TS/desktop twin; the Android JVM implementation never got the same check.
- **Suggested fix:** Parse `start` out of `Content-Range` (`bytes start-end/total`) and compare it
  to `offsetBytes`; on mismatch (or a missing header on a 206), treat the response like a
  non-resumable 200 — truncate the `.part` file and restart from 0, exactly as the existing
  200-with-partial-existing branch already does (ModelDownloadEngine.kt:136-139).
- **Verifier (medium confidence):** Confirmed in JvmDownloadIO.kt — nothing in the file
  cross-checks a `Content-Range` start. Confidence is medium only because triggering it requires a
  non-RFC-compliant server/proxy; that is a real (if not universal) class of CDN misbehavior, and
  the twin already carries the fix, so this is a legitimate defensive gap rather than a fabricated
  scenario.

### #8 [MEDIUM] Privacy-lock brute-force lockout resets on page reload
- **Location:** `ui/src/components/PrivacyLock.tsx:13` (core)
- **Symptom:** `failedAttempts` / `lockoutUntil` live only in React state with no persistence, so
  a reload clears the throttle and allows unlimited guessing.
- **Failure scenario:** PrivacyLock enforces `MAX_FAILED_ATTEMPTS = 5` then a 5-minute
  `LOCKOUT_DURATION_MS` via `useState` (13-14), with no write to localStorage/sessionStorage
  anywhere in the file. Someone with physical/local access — the exact threat model this lock
  exists for — makes 5 wrong guesses, triggers the lockout, then reloads the page. The component
  remounts with `failedAttempts = 0` and `lockoutUntil = null`; the throttle is defeated by an
  action requiring no special access.
- **Suggested fix:** Persist `failedAttempts`/`lockoutUntil` under a dedicated localStorage key
  (separate from the plaintext-sensitive settings) and rehydrate on mount, so a reload can neither
  reset the counter nor cut a lockout short.
- **Verifier (high confidence):** Confirmed — `useState` only, no storage read/write in the file,
  and no parent (App.tsx) tracks or persists these either. Matches the component's own stated
  threat model.

### #9 [MEDIUM] Empty-but-successful task answer renders as the halt text "answered"
- **Location:** `ui/src/hooks/useAgentSocket.ts:265` (core)
- **Symptom:** The `task_done` handler uses a truthy check on `data.answer`, so a legitimate
  empty-string result is misrendered as an unexplained halt whose text is literally "answered".
- **Failure scenario:** The governed task agent
  (`src/services/capability/capabilityAgent.ts:137`) returns
  `{ answer: decision.text, steps, halt: 'answered' }`, where `decision.text` comes straight from
  the model's `{"answer": "..."}` JSON (capabilityAgent.ts:240 — `if (typeof o.answer === 'string')
  return { kind: 'answer', text: o.answer }`, no length/trim check). A weak local model that
  finishes with `{"answer":""}` after using tools produces `task_done` with `answer: ''` and
  `halt: 'answered'`. The client's `if (data.answer)` is false for `''`, so it falls into the halt
  branch; the `why` lookup table (268-273) has no `'answered'` key, so `why[data.halt] ?? data.halt`
  yields the raw string `'answered'`. TasksArea.tsx renders a halt-styled (amber) log entry reading
  literally "answered" — a successful completion presented as an unexplained failure.
- **Suggested fix:** Check `data.answer !== null` (or `typeof data.answer === 'string'`) rather
  than truthiness, and push an "answer" log entry (with a placeholder such as "(no answer text)")
  whenever `halt === 'answered'`, reserving the `why` halt-message branch for genuine non-success
  halts.
- **Verifier (high confidence):** Confirmed end to end — capabilityAgent.ts:240/137 permit an
  empty successful answer, `websocket/index.ts:531` spreads the result verbatim into `task_done`,
  and useAgentSocket.ts:265 takes the halt branch with no `'answered'` entry in the table. No
  upstream guard prevents it.

### #10 [MEDIUM] Format-specifier validation compares an unordered multiset
- **Location:** `scripts/build_xcstrings.py:26` (tests)
- **Symptom:** `specs()` strips positional markers down to a sorted multiset of specifier types, so
  the check at line 44 accepts a translation that swaps which **type** occupies which argument
  position.
- **Failure scenario:** For a key with two differently-typed positional specifiers — e.g.
  `"Move %1$@ to folder %2$lld"` (specs `[%@, %lld]`) — a translation that mis-numbers them as
  `"...%1$lld...%2$@..."` normalizes via `re.sub(r'%\d+\$', '%', ...)` to the same sorted list, so
  `specs(val) != ks` is False and the mismatch is never flagged — despite the script's own docstring
  saying the check exists because "a mismatched %@ crashes at render." That translation ships into
  `Localizable.xcstrings`, and at runtime `String(format:)` / `String(localized:)` reads the string
  argument through `%lld` and the integer through `%@` — undefined behavior in the ObjC/Swift
  varargs path, typically a crash or garbage text.
- **Suggested fix:** Validate per position, not as a multiset: build an ordered
  position-number → specifier-type map for the key and for each translation (defaulting unnumbered
  specifiers to scan order) and compare those maps, so a translation can't reuse position N with a
  different type than the key's position N.
- **Verifier (high confidence):** Confirmed that `specs()` (24-26) strips positional index info per
  match before sorting. Not hypothetical: `scripts/translations.tsv` line 231
  (`%lld of %lld installed · %@ on disk · %@ free`) is a real key with two distinct specifier types
  across multiple positions — exactly the shape a translator can transpose while keeping the sorted
  multiset identical.

### #11 [MEDIUM] ko/ja/zh merge overwrites all three columns when only one is empty
- **Location:** `scripts/merge_kja_zh_1.py:137` (tests) — same block in `merge_kja_zh_2.py` and
  `merge_kja_zh_3.py`
- **Symptom:** An OR-guard paired with an unconditional three-column write silently clobbers
  already-filled (possibly hand-reviewed) translations.
- **Failure scenario:** Line 135's guard is `(not cols[2] or not cols[3] or not cols[4])` — true if
  even one of ko/ja/zh is missing — but line 137 unconditionally assigns
  `cols[2], cols[3], cols[4] = ko, ja, zh` from the script's hardcoded dict `T`. A row with a
  correct, reviewed `ja` and `zh` (hand-edited by a translator, or filled by a previous chunk
  script) but a blank `ko` gets its good `ja`/`zh` cells overwritten with this script's own possibly
  stale values, discarding real translator work with no warning — the script reports only `hit`
  counts and missed keys, never a per-column diff.
- **Suggested fix:** Overwrite only the columns that are actually empty
  (`if not cols[2]: cols[2] = ko`, etc.), and count `hit` only when at least one column actually
  changed.
- **Verifier (medium confidence):** Code-level mechanism confirmed exactly as claimed at 135-137.
  Confidence is medium because actual data loss requires a specific (but entirely plausible)
  intermediate TSV state — a partial external fill — in a script designed to be re-run repeatedly
  across incremental states.

### #12 [LOW] `continueLast()` drops the model and always resolves the `.small` tier
- **Location:** `apple/QuenderinKit/Sources/QuenderinKit/ChatModel.swift:104` (apple)
- **Symptom:** Continue after a token-cap stop always resolves `ChatTier.of(model: nil)` → `.small`
  for the system prompt, regardless of which model actually generated the original reply.
- **Failure scenario:** A loaded 7B+ model (`ChatTier.full`, no length-restricting suffix, 512-token
  cap) produces a long reply that hits `resolvedOptions.maxTokens`, setting `lastHitTokenCap = true`.
  The user taps Continue; `continueLast(options:)` (104-107) calls
  `send(ChatUserFacing.continueCue(), options: options)` with no `model:` argument, so inside
  `send()` (line 143) `ChatTier.of(model: nil)` returns `.small` and the system prompt gains the
  `.small` suffix "Prefer 1–3 short paragraphs or a tight bullet list." (ChatTier.swift:39) — a
  style constraint the original generation never had, silently changing the continuation's
  tone/length policy mid-conversation.
- **Suggested fix:** Give `continueLast` a `model: ModelEntry? = nil` parameter and forward it to
  `send(_:documents:options:model:)` so the continuation uses the same tier (system prompt + token
  budget) as the turn it extends.
- **Verifier (high confidence):** Confirmed — `ChatTier.of(model:)` (ChatTier.swift:19-22)
  explicitly returns `.small` via `guard let model else { return .small }`, and the UI call site
  `model.continueLast()` (ChatView.swift:368) passes zero arguments, so the path is reachable via
  the real Continue chip after any token-cap stop.

---

## Refuted — do not re-hunt

| Location | Claim | Why it was dropped |
|---|---|---|
| `.../core/OnboardingModel.kt:213` | Failed retry of the *currently active* model skips the restore path (`previousId?.takeIf { it != model.id }` → nil), leaving the engine unloaded | **Unreachable.** Every production caller structurally prevents `model.id == previousId`: `ModelPickerSheet` disables the current model's row (`!isCurrent`, line 140), both call sites add `if (picked.id != model.id)` (ChatScreen.kt:563, SettingsScreen.kt:381), the quick-preset buttons carry the same guard (120/123/126), and the onboarding path only runs while `phase == Idle/Recommended` with `loadedModelId == null`. |
| `.../core/LlamaEngine.kt:131` | `load()` clears `handle`/`loadedModelId` but not `loadedContextTokens`, so a failed reload leaves a stale non-null value | **Code fact true, no reachable consumer.** The only reader, ChatModel.kt:194, renders only while `phase is OnboardingPhase.Ready` (OnboardingScreen.kt:176), and Ready is only entered right after a load that just succeeded and set the field correctly. On a failed load + failed restore the phase becomes `Failed` and that UI unmounts. Grep found no other reader. Legitimate API-contract nit, not a bug. |
| `ui/src/App.tsx:416` | The one-time plaintext-passphrase migration can clobber a passphrase the user changes while the old hash is in flight | **Race window not achievable.** `hashPassphrase` is a single `crypto.subtle.digest('SHA-256', …)` over a short string — sub-millisecond — and the migration effect fires as soon as settings load. A human cannot navigate into Settings, type a new passphrase, and click Save inside that window; the finding itself conceded it is "unlikely to be hit by normal human interaction." |

---

## Patterns worth adding to BUG_JOURNAL.md

Journal entries ship with the fix commit, not with this audit — these are the lessons that
generalise, staged for whoever writes the fixes.

1. **A fallback that changes a resource's unit cost must re-derive the size that was computed from
   that cost.** Any retry that swaps a quantization / encoding / compression mode (KV cache
   F16 ↔ q8_0, and anything shaped like it) inherits a capacity number computed under the *old*
   cost model. Grep every `catch`/retry that changes a type or mode and check which precomputed
   sizes are now stale. (#1)

2. **Never re-derive a security value that the caller already had.** When an integrity/auth check
   looks its expected value up from a static table by URL/id instead of receiving it as a
   parameter, the check silently degrades to nothing for every entry outside that table. Thread
   the value through the API. Corollary lint: any `catalog.first { $0.x == y }?.secret` feeding a
   verification path is a smell. (#2)

3. **A `Promise.race` timeout is not cancellation.** Racing a timeout against a native/expensive
   init leaves the loser running. Every such site needs either a real cancel token or single-flight
   joining inside the service that owns the resource — plus a plan for releasing whichever handle
   eventually wins. (#3)

4. **Layered services need one canonical "stop" entry point.** When a low-level service and its
   supervising service both expose `stopGeneration()`, any call site that hits the low-level one
   leaves the supervisor's `isGenerating` latched — and a latched guard usually manifests as a
   *silently dropped* user action, not an error. Audit for direct calls into the lower layer. (#4)

5. **"Idempotent" codemods must be tested against the file's current real shape, including optional
   trailing named arguments.** Anchoring a regex on the line's last `)` breaks the moment a trailing
   named/keyword argument exists. Run the script and diff, don't trust the docstring. (#5)

6. **Guard set ≠ write set.** `if (a is empty OR b is empty OR c is empty) { a = ...; b = ...; c = ... }`
   destroys good data in the columns that weren't empty. Whenever a guard is an OR across N fields,
   the write must be per-field. (#11)

7. **Any "don't persist while busy" guard needs a matching UI guard.** A `persist()` that no-ops
   mid-operation is only safe if the UI physically prevents the destructive follow-up action while
   busy; otherwise it's a silent data-loss path. Check both halves together. (#6)

8. **Truthy checks on protocol payload fields treat legitimate empty values as absent.** `if (x)`
   over a `string`-typed wire field conflates `''` with "no value" and routes success into the
   error/halt branch. Use `!== undefined` / `typeof === 'string'` for any field a peer may
   legitimately send empty. (#9)

9. **Structural validators must compare structure, not a bag of parts.** Sorting format specifiers
   (or any positional tokens) into a multiset before comparing discards the position↔type binding
   that is the whole point of the check. (#10)

10. **Client-side rate limits held only in component state are not rate limits.** Any lockout /
    attempt counter that lives in `useState` is reset by F5. If the threat model includes local
    access, the counter must be persisted. (#8)

11. **When a lesson is applied to one twin, apply it to all twins.** H9's Content-Range-start check
    was fixed on the TS/desktop path and never ported to the Android JVM path (#7). After any
    journal entry on shared-behavior code, grep the sibling platform implementations before closing
    the fix.
