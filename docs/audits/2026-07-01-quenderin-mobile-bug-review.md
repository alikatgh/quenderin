# Quenderin Mobile (Android + iOS) Bug Review — 2026-07-01

**Method:** 6 cross-platform subsystems (download, inference, agent-safety, ui, conversation — with `inference`
and `ui` each covering both Android and iOS twins) were each hunted for parity/correctness bugs, then every
candidate finding was adversarially verified through two independent lenses (does the bug reproduce; is the
fix real and non-regressive) before being applied. This run's summary: **9 confirmed, 9 fixed, 0 uncertain,
0 rejected** across the 6 subsystems.

## Summary

| Subsystems hunted | Confirmed | Fixed | Uncertain | Rejected |
|---|---|---|---|---|
| 6 | 9 | 9 | 0 | 0 |

## Confirmed findings

| # | Severity | Subsystem | File:line | Title | Applied? |
|---|----------|-----------|-----------|-------|----------|
| 1 | high | download | `apple/QuenderinKit/Sources/QuenderinKit/OnboardingModel.swift:101-121` | iOS fast-path for already-downloaded models skips the C3 integrity gate (magic + SHA-256) that the fresh-download path enforces | yes |
| 2 | high | inference | `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:227-273` | iOS decode loop collapses recoverable KV-cache-full (rc==1) into fatal, unlike Android's shared loop which already fixed this | yes |
| 3 | high | agent-safety | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentDecision.kt:55-59` | Android's regex-based JSON key extraction ignores nesting; iOS's JSONSerialization only reads top-level keys — parser can diverge on which tool/answer is selected | yes |
| 4 | high | ui | `android/app/src/main/kotlin/ai/quenderin/app/ui/MainTabs.kt:62-68` | Chat/Agent in-flight work silently cancelled on tab switch (Android only) — iOS TabView keeps tabs alive, Android's single-slot `when` tears them down | yes |
| 5 | medium | download | `android/app/src/main/kotlin/ai/quenderin/app/ModelDownloadWorker.kt:50` | Android's production DownloadStore is never persisted across WorkManager worker runs, defeating its documented purpose | yes |
| 6 | medium | inference | `android/jni/llama_generate.h:99-134` | iOS applies an in-flight thermal governor that re-tunes threads mid-generation; Android has an equivalent ThermalGovernor class but never wires it into the native decode loop | yes |
| 7 | medium | conversation | `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift:38-58` | ConversationCoordinator.open()/startNew() can persist a mid-stream placeholder/partial assistant message (iOS-only risk; Android's synchronous send() cannot expose this state) | yes |
| 8 | medium | ui | `android/app/src/main/kotlin/ai/quenderin/app/ui/AgentScreen.kt:166-173` | AgentScreen Run button missing the synchronous busy-flag guard that ChatScreen explicitly added to close the exact same double-tap race | yes |
| 9 | low | conversation | `apple/QuenderinKit/Sources/QuenderinKit/ConversationStore.swift:36` | ConversationStore.decode() diverges cross-platform on an unrecognized role byte: Android drops the message, iOS relabels it as assistant | yes |

---

## Finding details

### 1. [high] iOS integrity-gate skip on the already-downloaded fast path

**File:** `apple/QuenderinKit/Sources/QuenderinKit/OnboardingModel.swift:101-121`

**Symptom:** On relaunch, if a model file is already present at `destination`, `OnboardingModel.install()`
skips straight to `engine.load()` without ever calling `ModelIntegrity.verify` — no GGUF magic check, no
SHA-256 comparison against the catalog-pinned hash.

**Root cause:** `if !FileManager.default.fileExists(atPath: destination.path) { ...download... }` only gates
the download step; there is no re-verification of a file that already exists at `destination` before
`engine.load(model:at:)` runs. Both `ModelDownloader.swift` (`ChunkedDownloadDelegate`, lines 131-145) and
`BackgroundModelDownloader.swift` (lines 145-164) call `ModelIntegrity.verify` right after a completed
download and delete the file on failure — but if the process is killed in the crash window between
`moveItem(at:to:)` succeeding and `ModelIntegrity.verify` completing (SHA-256 over a multi-GB file takes real
wall-clock time, and iOS can jetsam/kill an app anytime), the file is left sitting at `destination` fully
un-verified. The next launch's `fileExists` check treats it as good and loads it directly. Android's
`ModelDownloadEngine.download()` already re-verifies GGUF magic AND SHA-256 on its "already exists" fast-path
(`ModelDownloadEngine.kt:84-92`) before trusting a pre-existing final file; iOS's equivalent fast-path had no
such check.

**Failure scenario:** User is mid-onboarding, iOS kills the app (memory pressure / user force-quit) in the
~1-5s window after the multi-GB file is moved to its final destination but before SHA-256 verification
finishes. On next launch, the app finds the file present, skips the download, and hands a never-verified
(potentially truncated/corrupted/MITM'd) GGUF straight to the inference engine.

**Exactly what was changed:** In `OnboardingModel.install()`, before the existing "download if missing"
gate, added a re-verification step: if a file already exists at `destination`, run the same
`ModelIntegrity.verify(fileURL:expectedSHA256:)` gate the fresh-download path enforces (using
`ModelCatalog.entry(id: model.id)?.sha256`). On failure (or thrown error, via `try?`) the file is deleted so
control falls through into the existing `!fileExists` branch and triggers a real re-download.

**How it was verified:** Read `ModelIntegrity.swift` to confirm `verify(fileURL:expectedSHA256:)` throws
`ModelIntegrityError` on bad magic/checksum mismatch, matching the pattern already used in
`ModelDownloader.swift` and `BackgroundModelDownloader.swift`. Ran `cd apple/QuenderinKit && swift build`
twice (before finalizing and again at the end) — both times "Build complete!" with zero errors/warnings.

---

### 2. [high] iOS decode loop treats recoverable KV-cache-full as fatal

**File:** `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:227-273`

**Symptom:** On iOS, a long chat that fills the KV cache mid-generation (or a reused-prefix prefill that no
longer fits) throws `InferenceError.generationFailed` and drops the reply entirely, instead of gracefully
stopping/reprefilling like Android does.

**Root cause:** The Swift `decode(_:)` helper (line 227-231) collapses `llama_decode`'s return code to a
plain `Bool` via `== 0`, so it cannot distinguish `rc == 1` ("no free KV slot — cache full, recoverable") from
a genuine negative/fatal error. Both the prefill call (line 242) and the mid-generation feedback call (line
269) treat any non-zero rc identically as fatal. The shared C++ loop in `llama_generate.h:42-51,83-96,126-132`
already special-cases `rc==1` on Android (documented in its own header comment: "Treating 1 as fatal ... the
original bug here ... silently blanks or truncates replies the moment a long chat fills the context") — the
equivalent fix was never ported to the Swift twin.

**Failure scenario:** A user has a long-running chat that approaches `n_ctx`. On Android, the reply gracefully
truncates and the user sees a complete (if shorter) response, with the next turn cleanly reprefilling. On iOS
with the identical conversation length, the exact same reply throws a hard error instead.

**Exactly what was changed:** Changed the nested `decode(_:)` helper to return the raw `Int32` llama_decode
return code instead of collapsing to `Bool`. At the prefill call site: if `rc==1` and the KV-reuse plan had
`decodeFrom>0` (a reused prefix was in play), clear the cache/mirror and retry a full reprefill once before
treating any remaining non-zero rc as fatal (mirrors `llama_generate.h:83-96`). At the mid-generation feedback
call site: captured `producedBefore` (the yield count before this token) so a `code==1` mid-stream is now a
graceful `continuation.finish()` instead of `finish(throwing:)`, and only a genuinely negative rc with nothing
yet produced (`producedBefore==0`) throws (mirrors `llama_generate.h:126-132`). Also caught and fixed a
self-introduced bug during the edit: the first attempt checked `produced == 0` AFTER `produced += 1` had
already run (always false / dead code) — fixed by capturing `producedBefore` prior to the increment.

**How it was verified:** Manually re-read the edited region (lines 223-298) for type/logic correctness. Ran
`swift build` in `apple/QuenderinKit` — "Build complete!" with no errors. Note: the edited code lives inside
`#if canImport(llama)`, which is false in this environment (no llama.xcframework/QUENDERIN_LLAMA_DIR linked),
so that block is compiled OUT of this particular `swift build` and was not type-checked by the compiler here —
verification for that block is manual read-through only. The surrounding actor code (outside the `#if`) does
compile, confirming no syntax damage to the file as a whole.

---

### 3. [high] Nesting-blind regex JSON parsing diverges from iOS's top-level-only JSONSerialization

**File:** `android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentDecision.kt:55-59`

**Symptom:** For the exact same planner output text, Android's `AgentDecisionParser.parse()` can select a
completely different `AgentDecision` than iOS's — either fabricating a `FinalAnswer` from a nested field, or
invoking a tool that iOS would refuse to run at all (`PLAN_ERROR`).

**Root cause:** `extractString(json, key)` uses a flat regex `"$key"\s*:\s*"..."` over the whole
brace-balanced substring returned by `firstJsonObject`, with no notion of JSON nesting/object depth — it
matches a key anywhere in the text, including inside a nested object value. iOS's parser instead runs the
text through `JSONSerialization.jsonObject` and only ever reads top-level `answer`/`tool`/`input` keys.
Verified by direct execution: for input
`{"tool":"calculator","input":{"nested":"x"},"extra":{"answer":"nested value"}}`, compiled Kotlin
`extractString(json,"answer")` returns `"nested value"` (Android would fabricate `FinalAnswer("nested
value")`), while the equivalent Swift `JSONSerialization` lookup returns `nil` for `answer` and correctly
picks up the top-level `tool`.

**Failure scenario:** A local on-device model (especially a smaller/quantized one that imitates the few-shot
schema imperfectly, or echoes a "thought"/"reasoning" scratch field before its real decision) emits JSON where
the true tool/answer keys are wrapped inside another object, e.g.
`{"reasoning":{"tool":"units","input":"..."},"final":true}`. Android silently invokes the `units` tool via the
nested keys and continues the loop; iOS returns `PLAN_ERROR` and shows the user a "couldn't turn this goal
into a valid plan" message — two platforms shipping "the same feature" behave differently for identical model
output, and Android can execute a tool call the iOS build would have rejected outright.

**Exactly what was changed:** Replaced the flat, nesting-blind regex in `extractString(json, key)` with a
depth-aware scan that walks the string the same way `firstJsonObject` already does (tracking brace/bracket
depth and skipping over quoted-string contents), only recognizing a `"key": "value"` match when it occurs at
depth == 1 (a direct top-level member of the outer object). Keys inside a nested object/array (depth > 1) are
now invisible to the parser, matching iOS's `JSONSerialization` top-level-only read. iOS's `AgentDecision.swift`
was already correct and required no change. Also added two new checks to
`android/quenderin-core/src/verify/CoreVerify.kt` using the exact repro inputs from the bug report, placed
next to the existing H13 parity check in the same style/comment convention.

**How it was verified:** Compiled with
`kotlinc src/main/kotlin/ai/quenderin/core/*.kt src/verify/CoreVerify.kt -include-runtime -d /tmp/core_verify_agent-safety.jar`
(zero errors/warnings). Ran the jar — output ends with `ALL PASSED`, zero `FAIL` lines. Confirmed the two new
checks explicitly print `ok`, reproducing both exact inputs from the bug report (nested `answer` no longer
fabricated; tool/answer only nested now correctly yields `nil`, matching iOS's `PLAN_ERROR`). Confirmed all
pre-existing parity/decision/blocklist/agent-loop checks still pass (no regression).

---

### 4. [high] Chat/Agent in-flight work silently cancelled on Android tab switch

**File:** `android/app/src/main/kotlin/ai/quenderin/app/ui/MainTabs.kt:62-68`

**Symptom:** User sends a chat message or runs an agent goal, then taps another bottom-nav tab before the
response finishes; when they tap back to Chat/Agent, the response never arrives, the transcript looks like the
message was never answered, and any unsent draft text in the input field is gone.

**Root cause:** `MainTabs.kt` renders exactly one tab's composable subtree at a time via
`when (tab) { 0 -> ChatScreen(...); 1 -> AgentScreen(...); else -> SettingsScreen(...) }`. `ChatScreen.kt` and
`AgentScreen.kt` each call `rememberCoroutineScope()` and launch the send/run coroutine on `Dispatchers.IO`
from that scope. A `rememberCoroutineScope()` is tied to the composable's slot in the composition; when the
`when` branch switches away, that whole subtree (and its remembered `ConversationCoordinator`/`AgentSession`-
bound state) leaves composition, cancelling any coroutine launched from it. On iOS, `RootView.swift` wraps all
three tab views in a SwiftUI `TabView`, which keeps every tab's view (and its `Task`-launched work) alive
across tab switches.

**Failure scenario:** Tap Send in Chat, immediately tap the Agent or Settings tab, wait, tap back to Chat: the
assistant's reply that was being generated is gone (coroutine was cancelled mid-`chat.send`), and the UI's
in-flight visual state is inconsistent with iOS behavior where the same navigation does not interrupt
generation.

**Exactly what was changed:** In `MainTabs.kt`, replaced the single-slot `when (tab)` (which tore down the
non-active tab's composable subtree) with three always-composed `Box` layers, one per tab, each wrapped with a
new private `Modifier.tabVisibility(visible: Boolean)` extension. The active tab gets alpha=1/zIndex=1;
inactive tabs get alpha=0/zIndex=0, are removed from the accessibility tree via `clearAndSetSemantics`, and
have their touch input swallowed via an indication-less `clickable(enabled = !visible) {}` so they can't be
tapped through. This keeps `ChatScreen`'s and `AgentScreen`'s composition (and their
`rememberCoroutineScope()`-launched coroutines) alive across tab switches, matching iOS's `TabView` behavior,
without touching `AgentScreen.kt`/`ChatScreen.kt` or hoisting state outside `MainTabs.kt`.

**How it was verified:** Full Gradle/Android-Studio build isn't available in this environment. Verified by
re-reading the complete edited file end-to-end to confirm imports resolve to real Compose APIs
(`androidx.compose.ui.draw.alpha`, `androidx.compose.ui.zIndex`, `androidx.compose.foundation.clickable`,
`androidx.compose.foundation.interaction.MutableInteractionSource`), confirming brace/paren balance (24/24
braces, 46/46 parens), and confirming the `@Composable fun Modifier.tabVisibility()` extension is only invoked
inline inside the `MainTabs` composable body (a valid Compose call site).

---

### 5. [medium] Android's production DownloadStore never persisted across WorkManager runs

**File:** `android/app/src/main/kotlin/ai/quenderin/app/ModelDownloadWorker.kt:50`

**Symptom:** `ModelDownloadWorker.doWork()` constructs `DownloadStore()` with the default empty `initial` list
every time WorkManager re-runs the worker (after process death, retry, or resume), and never wires `onChange`
to persist the snapshot anywhere. Any UI or diagnostic code that queries `DownloadStore.resumable()`,
`.get(modelId)`, or `.all()` for progress-after-relaunch sees an empty/wrong table, even though the underlying
`.part` file resume works correctly and is unaffected.

**Root cause:** `DownloadStore.kt`'s own doc comment states its purpose is "so progress survives the app being
suspended or killed" and that "the app persists [snapshot] ... and restores via the constructor." iOS's
`DownloadStore.swift` is a file-backed actor that actually implements that contract. The Android production
wiring in `ModelDownloadWorker.kt` never implements either half: `DownloadStore()` is always constructed with
the empty default, and `onChange` is never assigned to a persistence callback anywhere in the app module
(confirmed via grep).

**Failure scenario:** Any Android UI code added later that calls `DownloadStore.resumable()` or `.get(modelId)`
to show "resuming previous download" state after an app relaunch will always get an empty table / null record,
even while a WorkManager-managed download is genuinely mid-flight and correctly resuming its bytes on disk —
the observability layer silently desyncs from the real download state.

**Exactly what was changed:** In `ModelDownloadWorker.kt`'s `doWork()`, replaced the always-empty
`DownloadStore()` with a store constructed from a snapshot loaded off disk (`loadSnapshot(storeFile)`), and
wired `store.onChange = { saveSnapshot(storeFile, it) }` so every mutation is persisted back out. Added two
small private helpers (`loadSnapshot`/`saveSnapshot`) using a dependency-free tab-delimited text format (no
JSON library exists in this module) written to a `download_store.txt` file in `applicationContext.filesDir`,
mirroring iOS's fileURL-backed persistence contract.

**How it was verified:** `ModelDownloadWorker.kt` itself requires the Android SDK/AGP to build (per its own
doc comment), so it's out of scope for a standalone `kotlinc` build in this environment. Verified the change
doesn't touch or break `:quenderin-core` (only imports the unmodified `PersistedDownload` type): ran
`kotlinc src/main/kotlin/ai/quenderin/core/*.kt src/verify/CoreVerify.kt -include-runtime -d /tmp/core_verify_download.jar`
(compiled cleanly, zero errors), then ran the jar — "ALL PASSED" with zero FAIL lines across all checks
including the DownloadStore/PersistedDownload and ModelDownloadEngine suites. Also manually traced the Kotlin
syntax (field order/types, `PersistedDownload.State` enum values) against `DownloadStore.kt` to confirm
correctness.

---

### 6. [medium] Android's ThermalGovernor exists but is never wired into the native decode loop

**File:** `android/jni/llama_generate.h:99-134`

**Symptom:** On a long Android generation, once threads are set at load time (`nativeLoad`,
`llama_jni.cpp:165-166`), they are never adjusted again even if the device heats up mid-reply. On iOS,
`runGeneration` samples `ThermalMonitor.currentLevel()` every 32 tokens and calls `llama_set_n_threads` to shed
threads as the SoC heats (`LlamaEngine.swift:248-260`), so a long iOS generation self-throttles while the
equivalent Android generation does not.

**Root cause:** Android's `ThermalGovernor` class exists (`ThermalMonitor.kt:52`, explicitly documented as
"twin of iOS ThermalGovernor") but is never referenced anywhere in the native decode path — not in
`llama_jni.cpp`, not in the shared `generateWithKVReuse` loop in `llama_generate.h`, and not in
`LlamaEngine.kt`'s `complete()` (confirmed via grep, zero hits across all three files). Android only applies
thermal-aware thread selection ONCE, at load time. There is no `llama_set_n_threads` call anywhere in the JNI
bridge or generation loop, and the per-token loop has no periodic thermal check at all. `ThermalMonitor.kt`
even contains a stale comment claiming "the in-decode sampling ... live in the JNI C++ loop" — false against
the actual contents, indicating the wiring was documented but never implemented (or was ripped out without
updating the comment).

**Failure scenario:** A user on Android runs a long, multi-hundred-token generation on a device that starts
cool and heats up over the course of the reply. On iOS the same scenario sheds threads mid-generation and
sustains; on Android threads stay pinned at the load-time count for the whole generation, risking sustained
thermal throttling or a slower/hotter tail of the reply that iOS would have avoided.

**Exactly what was changed:**
1. `android/jni/llama_generate.h`: added an optional `ThermalPoll` template parameter (default no-op lambda,
   so existing callers are unaffected) to `generateWithKVReuse`. Inside the per-token loop, every 32 tokens
   (`kThermalSampleInterval`) it calls `thermalPoll()` and applies `llama_set_n_threads(ctx, n, n)` when it
   returns a positive count. Updated the function's doc comment.
2. `android/jni/llama_jni.cpp`: in `generate()`, resolved a new `recommendedThreads()` jmethodID on `thiz`
   (mirroring the existing `cancelRequested` jfieldID pattern), and built a `thermalPoll` lambda that calls
   back into Kotlin via `CallIntMethod`, only returning non-zero when the recommendation actually changes from
   the last-applied count. Passed this lambda as the new trailing argument to `generateWithKVReuse`.
3. `android/quenderin-core/.../LlamaEngine.kt`: added a `@Volatile private var loadedBaseThreads: Int = 1`
   field, set it in `load()` alongside the existing `base` computation, and added a public
   `fun recommendedThreads(): Int = ThermalThrottle.recommendedThreads(thermalLevel, loadedBaseThreads)` that
   the native side polls, reusing already-in-scope `ThermalThrottle`/`ThermalLevel` symbols.
4. `android/quenderin-core/src/verify/CoreVerify.kt`: added one check pinning that `recommendedThreads()` is
   callable and degrades safely (floor of 1 thread) when queried pre-load.

**How it was verified:** `kotlinc src/main/kotlin/ai/quenderin/core/*.kt src/verify/CoreVerify.kt -include-runtime -d /tmp/core_verify_inference.jar`
completed with zero compiler errors/warnings; running the jar printed "ALL PASSED" with zero FAIL lines,
including the new `recommendedThreads` check. No NDK build is available in this environment for the C++ side;
re-read both edited regions in full afterward — the new `ThermalPoll` template parameter with a matching
default lambda type is valid C++17 and only affects callers that omit the trailing args, the JNI call site's
`GetMethodID`/`CallIntMethod` usage matches the file's existing `cancel_fid`/`GetBooleanField` pattern exactly,
no ABI/signature changes to existing exported JNI functions, and `CMakeLists.txt` required no changes.

---

### 7. [medium] iOS ConversationCoordinator can persist a mid-stream placeholder assistant message

**File:** `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift:38-58`

**Symptom:** Calling `coordinator.open(id:)` or `coordinator.startNew()` while a reply is still streaming
(`ChatModel.isGenerating == true`) leaves the conversation being left with a trailing assistant message that
is empty (`""`) or truncated, instead of either the complete reply or no assistant turn at all.

**Root cause:** `ChatModel.swift`'s `send()` synchronously appends the user message AND a placeholder
empty-text assistant `ChatMessage` to `messages` before any `await` for the stream; that placeholder is then
mutated in place token-by-token. `ConversationCoordinator.persist()`, `open()`, and `startNew()` only guard on
`chat.messages.isEmpty` — never on `chat.isGenerating` — so if a caller navigates away/opens another
conversation while a reply is in flight, `persist()` writes `chat.messages` (including the half-built
assistant message) to disk. On Android, `ChatModel.kt`'s `send()` is fully synchronous and only appends the
assistant `ChatMessage` after `engine.complete()` returns the full reply, so this failure mode is structurally
impossible on Android — a cross-platform parity gap in addition to a plain bug.

**Failure scenario:** User sends a prompt, immediately taps "New Conversation" (or opens a different history
item) before the stream token loop appends any tokens; `coordinator.startNew()`/`open()` calls `persist()`
which writes a transcript ending in `ChatMessage(role: .assistant, text: "")` to disk for the abandoned
conversation. Re-opening that conversation later shows a dangling empty assistant bubble, and re-exporting via
`ConversationExporter` renders a `**Quenderin:**` block with no content.

**Exactly what was changed:** Added a `!chat.isGenerating` guard to `persist()`, alongside the existing
`manager.currentID`/`!chat.messages.isEmpty` guards, plus a comment explaining why: `chat.messages` ends in a
placeholder/partial assistant turn until `send()` completes, and `startNew()`/`open()` both route through
`persist()`, so guarding this single choke point stops a mid-stream transcript from ever being written to
disk. `delete()`'s fallback path calls `manager.open()`/`manager.startNew()` directly, not `persist()`, so it
was already unaffected and needed no change.

**How it was verified:** `swift build` succeeds cleanly. Added regression test
`testPersistIsNoOpWhileGenerating` in `ConversationCoordinatorTests.swift` using the same isGenerating
spin-wait pattern already used in `ChatModelTests`. Confirmed the test FAILS against the pre-fix code
(mid-stream title/content leaked to the persisted summary) and PASSES against the fixed code. Full
conversation-subsystem test run: 43 tests, 0 failures. Apple-only change; Kotlin `ChatModel.kt`/
`ConversationCoordinator.kt` are structurally immune and were not modified.

---

### 8. [medium] AgentScreen Run button missing the synchronous busy-flag guard ChatScreen already has

**File:** `android/app/src/main/kotlin/ai/quenderin/app/ui/AgentScreen.kt:166-173`

**Symptom:** Rapidly double-tapping "Run" on the Agent screen can enqueue two concurrent `session.run(g)`
calls before `running` flips to `true`, whereas the analogous double-tap on the Chat screen's Send button is
explicitly prevented.

**Root cause:** `ChatScreen.kt` sets `busy = true` synchronously in the onClick lambda, on the main thread,
before dispatching `scope.launch(Dispatchers.IO) { chat.send(text) }` — the code comment explicitly says this
is done "so a rapid double-tap can't enqueue a second send before IO flips the flag." `AgentScreen.kt`'s Run
button does not set `running = true` locally; `running` is only ever updated via the `onChange` callback,
which fires from inside `AgentSession` after `session.run(g)` actually executes on the `Dispatchers.IO`
thread. Between the click and that coroutine actually running, the Button stays
`enabled = !running && goal.isNotBlank()` = true, so a second rapid tap can call `session.run(g)` again before
the first call's `isRunning = true` has propagated back to Compose state.

**Failure scenario:** User double-taps "Run" quickly with a valid goal typed: both taps pass the `enabled`
check before the first `session.run()` call has set `isRunning`/`running` to true, so `AgentSession.run()` can
be invoked twice concurrently, racing on `steps`/`answer` state.

**Exactly what was changed:** In `AgentScreen.kt`'s Run button onClick handler, added `running = true`
synchronously on the main thread immediately before `scope.launch(Dispatchers.IO) { session.run(g) }`, with a
comment mirroring `ChatScreen.kt`'s existing busy-flag comment. This closes the same race `ChatScreen.kt`
already closes for Send.

**How it was verified:** Same environment constraint as finding 4 (app module needs Android Studio/Gradle,
not available standalone here). Verified by re-reading the edited region: the change is a single added line
plus a two-line comment, directly parallel to `ChatScreen.kt`'s existing `busy = true` guard, using the same
`running` `MutableState` already declared and wired via `onChange` — no new symbols, no signature changes.
Brace/paren balance for the full file confirmed (57/57 braces, 104/104 parens).

---

### 9. [low] ConversationStore.decode() diverges on an unrecognized role byte

**File:** `apple/QuenderinKit/Sources/QuenderinKit/ConversationStore.swift:36`

**Symptom:** When a persisted transcript's role token is corrupted/unrecognized, Android silently removes
that one message from the restored conversation, while iOS silently reinterprets it as an assistant message
(keeping it, but with the wrong speaker) — same trigger, different data-loss/corruption shape between
platforms.

**Root cause:** Android's `ConversationStore.kt` uses `Role.valueOf(...)` wrapped in
`runCatching{}.getOrNull() ?: return@mapNotNull null`, so an unparseable role causes `mapNotNull` to drop that
line entirely. iOS's `ConversationStore.swift` used `ChatMessage.Role(rawValue: role) ?? .assistant`, silently
coercing any unrecognized role string to `.assistant` and keeping the message mislabeled. Downstream,
`ConversationContext.build()` uses `message.role` to choose the "User:"/"Assistant:" prefix when replaying
history to the model, so a message actually authored by the user but relabeled `.assistant` on decode gets fed
back under the wrong speaker tag.

**Failure scenario:** A transcript file is partially corrupted (disk bit-rot, manual edit, or a future format
migration bug) such that one row's role token no longer matches a recognized value. On iOS,
`ConversationManager.open()` returns that row as an assistant message and replays it to the model prefixed
"Assistant:" on the next turn even if the original author was the user, changing what the model conditions on.
On Android the same row is simply dropped, changing message count/order instead.

**Exactly what was changed:** Changed `StoredMessage.chatMessage` from a non-optional computed property that
coerced an unparseable role to `.assistant` into an optional
(`ChatMessage.Role(rawValue: role).map { ChatMessage(role: $0, text: text) }`), and changed `decode()` from
`.map(\.chatMessage)` to `.compactMap(\.chatMessage)` so a row with an unparseable role is dropped instead of
kept and mislabeled — mirroring Kotlin's `mapNotNull` drop-on-unparseable-role behavior. Added a comment
explaining that coercing would replay a spoofed "Assistant:" line into `ConversationContext.build()` on the
next turn.

**How it was verified:** `swift build` succeeds cleanly. Added regression test
`testUnparseableRoleRowIsDroppedNotCoerced` in `ConversationStoreTests.swift` that encodes a message, corrupts
its role field to an unrecognized string, decodes it, and asserts the result is empty. Confirmed the test
FAILS against the pre-fix code (corrupted row kept, coerced to `.assistant`) and PASSES against the fixed
code. Full conversation-subsystem test run: 43 tests, 0 failures, including all 5 `ConversationStoreTests`.
Apple-only change; Kotlin `ConversationStore.kt` already implements the drop behavior and was not modified.

---

## Uncertain

None — no findings were left in an uncertain state this run.

## Rejected

None — no candidate findings were rejected this run.

---

## Independent re-verification (post-workflow)

The workflow's own fix agents self-reported verification, but two gaps were only caught by re-checking
their work directly afterward rather than trusting those reports:

1. **Finding #1's fix had a bug of its own.** It read the expected hash via
   `ModelCatalog.entry(id: model.id)?.sha256` instead of the `model.sha256` parameter already in scope —
   silently skipping the sha256 check for any `ModelEntry` not in the static catalog. Corrected to use
   `model.sha256` directly. Also discovered the existing `testInstallSkipsDownloadWhenFileExists` test used
   an empty-file fixture that the NEW integrity check correctly rejects (that was a real fixture problem,
   not a fix problem) — rewrote it with a genuinely valid, self-consistent GGUF stub, and added a
   complementary `testInstallRejectsAndRefetchesAnInvalidExistingFile` regression test.

2. **Finding #2's fix was verified against code that was never actually compiled.** `LlamaEngine.swift`'s
   generation loop lives inside `#if canImport(llama)`, which is false by default (no llama.xcframework
   linked) — so every `swift build`/`swift test` run in this repo silently skips type-checking that block
   entirely. The fix agent's "Build complete!" was true but meaningless for this specific edit. Built the
   vendored `android/jni/llama.cpp` for macOS via `Package.swift`'s documented `QUENDERIN_LLAMA_DIR` route
   (`cmake -S . -B build -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON ...`, then `cmake --build build --target
   llama`), linked it, and re-ran `swift build`/`swift test` for real — 202/202 tests, and this time the
   compiler actually saw `LlamaEngine.swift`'s guarded block. That real compile caught a second bug: the
   "was anything produced yet" fatal-check used the per-token loop counter (`produced`), which increments
   regardless of whether the token's piece was non-empty text — diverging from the C++ twin's `out.empty()`
   (checked against actual accumulated text). Fixed by tracking a dedicated `yieldedAnyText` flag.

All 9 fixes (with the two corrections above folded in) were re-verified end-to-end after the workflow
completed: `kotlinc` + `CoreVerify.kt` (ALL PASSED), `./gradlew assembleDebug` (native `.so` rebuilt and
linked cleanly), `swift build` + `swift test` with the real llama.cpp linked (202/202, 0 failures).
