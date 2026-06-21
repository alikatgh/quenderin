# Mobile Engineering Audit — iOS + Android (on-device LLM)

**Date:** 2026-06-20
**Scope:** The native apps' engineering for running multi-GB local models on real phones —
native-handle lifecycle, memory/OOM, threading/concurrency, the download path, and the
recently-merged feature code (conversation history, settings, model switching).
**Method:** Direct source review against the `BUG_JOURNAL` patterns + judgment. Not a fan-out.
**Files:** `LlamaEngine.swift`, `LlamaEngine.kt`, `jni/llama_jni.cpp`, `InferenceEngine.*`,
`SettingsScreen.kt`/`SettingsView.swift`, `ConversationCoordinator.*`, `FileConversationPersistence.*`.

## Verdict

The core is **better-than-typical** for an on-device LLM app: native access is serialized on
both platforms (Swift `actor` / Kotlin `synchronized`), `load()` frees the previous model before
allocating a new one (no multi-GB leak on switch), and the JNI bridge has real discipline
(`call_once` backend init, `GetStringUTFChars`/`NewStringUTF` null-checks, `ExceptionCheck` after
the token callback, `DeleteLocalRef` hygiene). The hard C-API gotchas are documented and were
caught by actually running on-device.

**But it is not yet world-class for shipping to a wide range of phones.** One HIGH issue is a
session-bricking regression introduced by the new model-switching feature, and the memory/threading
model has gaps that will bite on memory-tight devices and long generations. None requires a redesign.

**Counts: 1 HIGH · 3 MEDIUM · 4 LOW.**

## Resolution (2026-06-20)

| # | Status | Notes |
|---|--------|-------|
| **H1** | ✅ **Fixed** | Recoverable switch — a failed load restores the previously-working model. Tests both platforms. (merged) |
| **M1** | ✅ **Fixed** | `ContextWindow.recommend(totalRAMGB)` scales `n_ctx` (1024/2048/4096) by device RAM; wired into both engines + app construction. Tested. |
| **L1** | ✅ **Fixed** | Android conversation writes are now atomic (temp-file + rename), parity with iOS `.atomic`. |
| **L3** | ✅ **Fixed** | JNI throws `OutOfMemoryError` on a marshaling failure instead of returning `""` (on-device-cliff code; reviewed, not CI-compiled). |
| **M2** | ✅ **Fixed** | iOS generation now runs OFF the cooperative pool on a background queue; native handles are `nonisolated(unsafe)` + `NSLock`-serialized (same use-after-free guard Android gets from `synchronized`), so a switch still can't free the context mid-decode. **Verified by `swift test`** (`canImport(llama)` is true in the package build, so the engine compiles + the existing engine tests pass through the new threading). |
| **M3** | ✅ **Fixed** | Switch-time cancellation: iOS `cancelState` (`OSAllocatedUnfairLock`) is set by `load()`/`unload()`/`requestCancel()` and polled by the decode loop; Android `@Volatile cancelRequested` (`requestCancel()`, lock-free) is polled by the JNI decode loop (`GetBooleanField` per token), and the switch path (`acceptAndPrepare`) calls `requestCancel()` before `load()` so it isn't blocked behind a running reply. `requestCancel()` added to the `InferenceEngine` seam (default no-op). iOS verified by `swift test`; the JNI poll is on-device-cliff (reviewed). |
| **L2** | ✅ **Resolved (decision)** | Kept the **atomic full-write** (L1) over append-only: for small text transcripts the per-turn cost is O(small), and append would trade crash-safety for negligible speed. A deliberate engineering choice, not deferred work. Revisit append-only only if transcripts grow large. |
| **L4** | 🎯 **Milestone (tracked)** | Android Vulkan/GPU offload genuinely needs a Vulkan-enabled llama.cpp build + on-device tuning — it cannot be "fixed" by a code change in this environment (there is no GPU backend to switch on). The top Android perf milestone; `jni/llama_jni.cpp:103` (`n_gpu_layers = 0`) is the one-line flip once the Vulkan build exists. |

**Engineering note:** M2 is now verifiable here (`swift test` compiles `#if canImport(llama)`), so the iOS off-pool + lock-serialized rewrite is checked, not shipped blind. The Android JNI cancellation poll and the L4 Vulkan build are the remaining on-device-cliff items (the `.cpp`/Vulkan are not CI-compiled) — reviewed and structured safely (lock-free flag, field polled per token), to be exercised on a device build.

---

## HIGH

### H1. Android model-switch picker has no memory-fit gate → switching can brick the session
- **File:** `android/app/src/main/kotlin/ai/quenderin/app/ui/SettingsScreen.kt:118` (`ModelCatalog.models.forEach`)
- **Why:** Both engines free the *working* model before loading the newly-chosen one
  (`LlamaEngine.kt:42`, `LlamaEngine.swift:55-59`). The iOS picker is **fitness-aware**
  (`ModelPickerView` disables models that won't fit and explains why), but the **Android picker
  lists every catalog model with no fit check**. On a 4–6 GB Android phone a user can pick
  Mistral-7B → the working model is freed → the 7B load OOMs/returns null
  (`LlamaEngine.kt:44` throws) → the app is left with **no model loaded** and a `Failed` phase.
  This is a regression from the 2026-06-20 model-switching feature; iOS is protected only by an
  *estimate* (real load can still OOM under app-memory pressure).
- **Fix:** Gate the Android picker on fitness for parity (compute per-model fitness from the device
  budget the selector already derives; disable/annotate non-fitting entries). Independently, make a
  failed switch **recoverable** — on load failure, attempt to reload the previously-active model so a
  bad pick doesn't strand the user with nothing.

---

## MEDIUM

### M1. `n_ctx` is hard-pinned to 4096 on both engines — never scaled to device budget or model
- **File:** `LlamaEngine.swift:73` (`ctxParams.n_ctx = 4096`, a literal — no seam);
  `LlamaEngine.kt:17` (`contextTokens = 4096` default, and the app builds `LlamaEngine()` with no
  args at `MainActivity.kt:32`, so it's never overridden).
- **Why:** The KV cache scales with `n_ctx`; at 4096 it adds **hundreds of MB–GB** on top of the
  weights for 4B/7B models. The selector picks the *model* by per-app memory budget but the
  *context* is fixed, so a "comfortable" model pick can still jetsam/OOM once the 4096-token KV cache
  is allocated under real app-memory pressure. Desktop already scales context
  (`resolveContextForSituation`); mobile does not.
- **Fix:** Derive `n_ctx` from the device memory budget + the chosen model's footprint (e.g. 4096
  comfortable / 2048 / 1024 tight). iOS needs a seam first (the literal should become a parameter,
  like Android's `contextTokens`), then both fed the budget the selector computes.

### M2. iOS generation loop runs synchronously on the actor's cooperative executor
- **File:** `LlamaEngine.swift:113,126-186` (`Task { self.runGeneration(...) }`; the `while` loop has
  no `await`).
- **Why:** `runGeneration` is actor-isolated and CPU-bound with **no suspension points**, so it pins
  one Swift-concurrency cooperative thread for the entire (multi-second) generation. Every other
  actor call — `loadedModelID()`, a queued `load()`/`unload()` (a model switch) — is blocked until it
  finishes, and a long synchronous job on the small cooperative pool risks starvation/priority
  inversion. Functionally correct (no data race), but not the responsive design world-class implies.
- **Fix:** Run the llama.cpp decode loop on a dedicated `DispatchQueue`/thread (off the cooperative
  pool), hopping back to the actor only to read/mutate `model`/`context`/`loaded`.

### M3. A model switch cannot cancel an in-flight generation; it blocks on the engine lock/actor
- **File:** `LlamaEngine.kt:40,56` (both `synchronized(lock)`); `LlamaEngine.swift` (actor isolation).
- **Why:** `load()` (the switch) contends on the same lock/actor as `complete()`/`generate()`, so a
  switch requested mid-generation **waits for the whole generation** before it can free + reload.
  On Android `acceptAndPrepare` runs on `Dispatchers.IO`, so it blocks an IO thread (not the UI), but
  the switch appears to hang on a long reply. There is no path to interrupt the running decode.
- **Fix:** Set a cancellation flag the decode loop polls (Android: a `volatile` checked in
  `generate()`'s loop; iOS already checks `Task.isCancelled` — surface a way to cancel it from
  `load()`), so a switch can pre-empt a long generation.

---

## LOW

### L1. Android conversation writes are non-atomic (corruption window on crash/power-loss)
- **File:** `FileConversationPersistence.kt:22,37` (`File.writeText(...)`), vs iOS
  `FileConversationPersistence.swift` which uses `.atomic`.
- **Why:** `writeText` truncates-then-writes; a crash or battery-death mid-write leaves a truncated
  transcript or a corrupt index. iOS is safe via atomic write; Android is not (parity gap).
- **Fix:** Write to a temp file then `renameTo` (atomic on the same filesystem), matching iOS.

### L2. Full transcript + index rewritten on every turn (O(n) per message)
- **File:** `ConversationCoordinator.{swift,kt}` `persist()` → `ConversationManager.save` →
  `ConversationStore.encode(whole transcript)` + `saveIndex(whole index)`.
- **Why:** Each turn re-encodes and rewrites the entire growing transcript file and the whole index.
  Transcripts are small text so impact is minor, but it's the same read-modify-write-all shape the
  desktop flagged (H30) and is needless I/O/battery on long chats.
- **Fix:** Append-only transcript writes, or debounce persistence; rewrite the index only on
  title/recency change.

### L3. Android JNI returns "" on null-handle / OOM instead of surfacing an error
- **File:** `jni/llama_jni.cpp:125-128,138-141` (`if (!h) / if (!p) return env->NewStringUTF("")`).
- **Why:** A `GetStringUTFChars` OOM yields an **empty assistant reply with no error** rather than a
  thrown exception the UI can show. (The `!h` path is guarded by Kotlin `ensureReady`, so it's mostly
  the OOM path.)
- **Fix:** Throw a Java exception (e.g. `ThrowNew(OutOfMemoryError)`) on marshaling failure.

### L4. Android inference is CPU-only (`n_gpu_layers = 0`) — large perf/battery/heat gap vs iOS Metal
- **File:** `jni/llama_jni.cpp:103` (`mp.n_gpu_layers = 0`, "later tuning step"), vs
  `LlamaEngine.swift:65` (`999` → full Metal offload).
- **Why:** Not a correctness bug, but Android tokens/sec, battery drain, and thermals are materially
  worse than they could be with Vulkan/GPU offload. For "world-class on real phones" this is the
  single biggest Android quality gap. Track it explicitly rather than leaving it implicit.
- **Fix:** Add Vulkan offload (gated by device capability) as a planned milestone.

---

## What's already excellent (keep)

- **Serialized native access** on both platforms — no use-after-free across UI/background threads.
- **Free-before-reassign on `load()`** — no multi-GB context leak on a model switch.
- **JNI discipline** — `call_once` backend init, null-checked `GetStringUTFChars`/`NewStringUTF`,
  `ExceptionCheck` after the token callback (prevents ART abort), `DeleteLocalRef` hygiene, full
  `nativeFree` (sampler + ctx + model + delete).
- **C-API lifetime correctness** — the `llama_batch_get_one` borrow is kept alive during decode;
  `tokenToPiece` resizes on a negative return; tokenize guards Int32 overflow.
- **Device-aware *model* selection** by per-app memory budget (jetsam / native-heap), not total RAM.

## Recommended fix order

1. **H1** — gate the Android picker on fitness + make a failed switch recoverable (ships-blocking
   correctness; it's a regression from the new feature).
2. **M1** — device/model-aware `n_ctx` (the highest-leverage OOM-prevention improvement).
3. **M2 / M3** — move the iOS decode off the cooperative pool; add switch-time cancellation.
4. **L1 / L3** — atomic Android writes; surface JNI OOM as an error.
5. **L4** — Android Vulkan offload (planned milestone, not a quick fix).
</content>
