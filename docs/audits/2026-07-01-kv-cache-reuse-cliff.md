# KV-cache reuse cliff → context-shifting — 2026-07-01

**Status (updated 2026-07-11):** **MERGED to `main`** (commit `0350f55` — both twins + JNI/Metal
executors + tests landed; the local branch is pruned). The on-device S23 throughput A/B (steps
at the bottom) remains OPEN as a post-merge measurement — the merge proceeded on the Metal
byte-identical correctness result; if the phone A/B ever shows a quality regression, the
SWA/`seq_rm`-false fallback (or a per-model flag) is the recorded escape hatch.

---

## The finding: KV-cache reuse silently dies exactly when it matters most

The purpose of KV-cache reuse (`KVCacheReuse` + the native `generateWithKVReuse` loop) is stated in its
own docstring: *"time-to-first-token stays flat instead of growing with conversation length."* It reused
the cache **only on a strict prefix match** — the cached tokens had to be a leading slice of the new prompt.

But the prompt is assembled by `ConversationContext.build()` as `system + history + primer`, and once the
token budget fills, `build()` drops the **oldest** turn first:

- **Short chat** → each turn *appends* → new prompt extends the cached one → reuse fires, TTFT flat. ✅
- **Budget full** → the oldest turn falls off the **front**, so everything after the system prompt shifts:
  - cache: `system + [t1, t2, … t_{n-1}]`
  - new:   `system + [t2, t3, … t_n]`
  - The tokens right after `system` now differ (`t2` ≠ `t1`) → common prefix collapses to just the system
    prompt → reuse returns 0 → **full re-prefill of the entire ~n_ctx window, on every message, for the rest
    of the conversation.** ❌

So the flat-TTFT promise **inverts precisely when conversations get long** — the case that matters most on a
phone, and the exact case a single-shot smoke test never exercises. This was the single biggest cache
inefficiency available, entirely in code we own.

## The fix: KV context-shifting (StreamingLLM-style)

Instead of all-or-nothing prefix reuse, the reuse decision is now a KV **eviction range + shift**, executed
natively with llama.cpp's `llama_memory_seq_rm` (drop the evicted tokens) + `llama_memory_seq_add` (shift the
survivors' positions down — RoPE-corrected). Four outcomes, one unified plan (`KVCacheReuse.Plan`):

| Case | When | Action |
|------|------|--------|
| **append** | cache is a strict prefix of `new` | keep all, decode the suffix (unchanged) |
| **shift** | oldest turn(s) dropped, a contiguous tail still aligns | evict `[evictFrom, evictTo)`, shift survivors down, decode only the truly-new tail |
| **prefix** | only the leading common prefix survives | keep it, drop the rest, decode `new[p:]` |
| **full** | nothing usable (first turn, system prompt changed) | clear + reprefill |

For a long chat dropping one ~200-token turn out of a ~3500-token window, this decodes **~200 tokens instead
of ~3500** on the front-drop turn — the reuse win is restored for the entire conversation, not just the
pre-budget prefix.

### Why it's safe

- The plan only ever proposes reusing a region that is **token-for-token identical** between cache and new
  prompt (verified by an in-test simulation that reconstructs `new` exactly from every plan — `simulateReuse`).
  A wrong guess can only cost a re-prefill, never a corrupted context.
- `llama_memory_seq_rm` **returns false** when a cache type can't do a partial removal (e.g. SWA / sliding-
  window caches). The native executor checks that and **falls back to a clean full reprefill** — so
  correctness never depends on the shift succeeding. This is a pure speedup layered on the existing fail-safe.
- The smallest-gap search is bounded (`MAX_EVICT_SCAN = 2048`), comparison-only, runs once per turn → sub-ms.

## Files changed

| File | Change |
|------|--------|
| `android/quenderin-core/.../KVCacheReuse.kt` | Unified append/shift/prefix/full plan (was strict-prefix-or-nothing). |
| `apple/QuenderinKit/.../KVCacheReuse.swift` | Twin of the above, in lockstep. |
| `android/jni/llama_generate.h` | `kvReuseCount` → `kvReusePlan`; executor does `seq_rm`+`seq_add` with SWA fallback. |
| `apple/QuenderinKit/.../LlamaEngine.swift` | Same context-shift execution in `runGeneration` (`#if canImport(llama)`). |
| `android/quenderin-core/src/verify/CoreVerify.kt` | 6 plan tests incl. a reconstruct-`new` invariant + `simulateReuse` helper. |
| `apple/QuenderinKit/Tests/.../KVCacheReuseTests.swift` | Twin test set. |
| `apple/QuenderinKit/Tests/.../LlamaEngineRealInferenceTests.swift` | NEW `testContextShiftOutputMatchesFullPrefill` — real-inference acid test. |

## What was verified (this session, on this Mac)

- **Kotlin core** — `kotlinc` + `CoreVerify.kt`: **ALL PASSED** (incl. the 6 new plan tests + reconstruct invariant).
- **Swift core** — `swift test`: **207 tests, 0 failures** (default, real-inference skipped).
- **Android native** — `./gradlew assembleDebug`: `libquenderin_llama.so` rebuilt clean for arm64 (C++ compiles under the NDK).
- **Swift native** — `swift build` with real llama.cpp linked (`QUENDERIN_LLAMA_DIR`): the `#if canImport(llama)`
  context-shift block actually type-checks and compiles.
- **★ Correctness on real llama.cpp (Metal, qwen3-4B Q4_K_M)** — `testContextShiftOutputMatchesFullPrefill`
  **PASSED**: a front-drop prompt run through `seq_rm`+`seq_add` produces output **byte-identical** to a
  from-scratch full prefill under greedy decoding. This directly validates the **RoPE-shift correctness** — the
  risky part of the change — on real inference. The append-path test and multi-turn coherence test also pass;
  multi-turn TTFT stayed flat (647–743 ms across a growing prompt).

> The Mac/Metal result validates the *mechanism* (the KV memory API is backend-agnostic in llama.cpp, so a
> correct shift on Metal is a correct shift on Vulkan/CPU). It does **not** measure the phone's actual
> throughput win or its thermal behavior — that's what the S23 A/B below is for.

## Remaining gate before merge — on-device A/B on the Galaxy S23

The correctness mechanism is validated; what's owed is the **throughput win + no-regression on the real device**.

1. **Install the branch build** (already builds): `cd android && JAVA_HOME=<jdk-21> ./gradlew installDebug`.
2. **TTFT A/B on a long chat that crosses the context budget.** Have a conversation long enough that
   `ConversationContext` starts dropping the oldest turn (watch for the front-drop). Compare per-turn
   time-to-first-token on this branch vs. `main`:
   - **Expected:** on `main`, TTFT climbs steeply once the budget fills (full reprefill every turn); on this
     branch it stays roughly flat (context-shift decodes only the new turn).
   - Log TTFT per turn (the iOS `testMultiTurnChatStaysCoherentAndPrintsTiming` pattern, or add a Logcat
     timestamp around `nativeCompleteStreaming`).
3. **Quality spot-check** on the front-drop turns: replies must stay coherent — no repetition loops, garbled
   tokens, or topic drift that `main` didn't have. (The Metal test already showed byte-identical output, but
   confirm on the device's model/quant.)
4. **Thermal sanity:** a sustained long chat should not run hotter than `main` — it does strictly *less* work,
   so this should improve, but confirm the governor still behaves.

If TTFT is flat + quality unchanged → merge to `main` and add the chronological bug-journal entry in the same
commit. If quality regresses on any model, the SWA/`seq_rm`-false fallback path is the safe escape — or gate
the shift behind a per-model flag.

## Raw evidence (this session)

```
testContextShiftOutputMatchesFullPrefill   passed (7.328s)   # front-drop == full prefill, byte-identical
testKVCacheReuseOutputMatchesFullPrefill   passed (3.115s)   # append path, unchanged
testMultiTurnChatStaysCoherentAndPrintsTiming passed         # TTFT 670/659/647/743 ms across growing prompt
CoreVerify.kt                              ALL PASSED         # 6 new plan tests + reconstruct invariant
swift test                                 207 tests, 0 failures
./gradlew assembleDebug                    BUILD SUCCESSFUL   # libquenderin_llama.so rebuilt (arm64)
```
