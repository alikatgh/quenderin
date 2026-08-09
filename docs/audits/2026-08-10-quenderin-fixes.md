# 2026-08-10 — Quenderin audit fixes applied

13 findings applied across android / offgrid / apple / core / tests. 0 deferred, 2 skipped
(both unreachable in this codebase). Verify clean. Journal entries appended to
`docs/BUG_JOURNAL.md` (chronological log + 7 new "Patterns to scan for FIRST" bullets).

## Applied

### High

| File:line | Unit | What changed |
|---|---|---|
| `android/jni/llama_jni.cpp:428` | android | F16 KV-cache fallback retry now scales `n_ctx` by `KVCacheType.Q8_0.relativeCostPerToken` (0.53, matching `KVCachePolicy.kt`) with a 512-token floor, and clamps `n_batch`/`n_ubatch` to the new `n_ctx`. Previously the retry swapped only `type_k`/`type_v`, inheriting an `n_ctx` sized for Q8_0's cheaper per-token cost and nearly doubling real KV memory on memory-tight devices. |
| `off-grid-mobile/src/services/llm.ts:57` | offgrid | Added a `loadingPromise` field; the old body became `loadModelInternal()` and `loadModel()` is now a serializer chaining each call onto the previous load. A `Promise.race` timeout abandons only the JS await — the loser's `initContextWithFallback()` kept running, so a retry with a different model started a second concurrent native init and leaked a `LlamaContext`. |
| `off-grid-mobile/src/screens/ChatScreen/useChatGenerationActions.ts:290` | offgrid | `executeDeleteConversationFn` now awaits `Promise.all([generationService.stopGeneration(), llmService.stopGeneration()])` (matching `handleStopFn`). The engine-only stop left `generationService.state.isGenerating` stuck true, silently dropping the next `generateResponse()`. |
| `off-grid-mobile/src/screens/ChatScreen/useChatModelActions.ts:217` | offgrid | Sibling of the above — `handleUnloadModelFn` had the identical engine-only stop before unloading the model. Imported `generationService` and applied the same `Promise.all` fix. |
| `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift:148` | apple | Added `expectedSHA256:` to the `ModelDownloader` protocol (default protocol-extension impl forwards to the 2-arg overload, so `BackgroundModelDownloader`/`MockModelDownloader` compile unchanged). `URLSessionModelDownloader` threads it into `ChunkedDownloadDelegate`, which now prefers the caller-supplied hash over the `ModelCatalog`-by-URL lookup. `OnboardingModel.install()` passes `model.sha256`, so HF-search/sideloaded installs get real SHA-256 verification instead of silently downgrading to a magic-header-only check. |
| `scripts/refresh_model_hashes.py:129` | tests | Rewrote `patch_line()`: the idempotent hash-removal regex now also matches a hash sitting before `, languagesLabel =`, and insertion anchors on that clause when present (falling back to "before the final `)`"). Previously entries with a trailing `languagesLabel` got a positional arg after a named one (invalid Kotlin) plus a duplicate hash on every re-run. |

### Medium

| File:line | Unit | What changed |
|---|---|---|
| `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt:51` | android | Added `contentRangeStartMatches(conn, offsetBytes)`; `resumed` is now `code == HTTP_PARTIAL && contentRangeStartMatches(...)`. A `206` with a missing/mismatched `Content-Range` start now falls through to the existing truncate-and-restart path (`ModelDownloadEngine.kt:136-139`) instead of appending misaligned bytes. |
| `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift:63` | apple | `persist()` no longer bails out entirely while `chat.isGenerating`; it trims the trailing in-flight assistant placeholder and saves the completed turns. Switching conversations mid-generation previously discarded the just-sent user message silently. `ConversationCoordinatorTests.testPersistIsNoOpWhileGenerating` had pinned the buggy behavior as intentional — renamed to `testPersistSavesUserTurnAndTrimsPartialAssistantWhileGenerating` and inverted. |
| `ui/src/hooks/useAgentSocket.ts:265` | core | `if (data.answer)` → `if (data.answer !== null)`. `data.answer` is `string | null` (task_done variant of the `AgentMessage` union, line 64), so a legitimate empty-string answer fell into the halt branch and rendered the literal unexplained text "answered". |
| `ui/src/components/PrivacyLock.tsx:13` | core | Added `readLockoutState()` reading a new `quenderin_lockout_state` localStorage key (JSON `{failedAttempts, lockoutUntil}`, best-effort try/catch per the codebase's existing pattern) as the `useState` initializers, plus an effect persisting both on change. Key is deliberately separate from passphrase/settings storage. The existing countdown effect already self-clears an expired lockout on mount. Previously a page reload reset the brute-force lockout entirely. |
| `scripts/merge_kja_zh_1.py:137` (+ `merge_kja_zh_2.py:151`, `merge_kja_zh_3.py:112`) | tests | `cols[2], cols[3], cols[4] = ko, ja, zh` → three independent `if not cols[N]: cols[N] = …` assignments. The guard is an OR across ko/ja/zh but the assignment overwrote all three, clobbering already-filled/hand-edited ja or zh whenever only ko was missing. Applied identically to the two sibling scripts. |
| `scripts/build_xcstrings.py:26` | tests | `specs()` now builds an ordered `{argument_position -> specifier_type}` map (unnumbered specifiers default to scan order, matching Swift/ObjC varargs semantics) instead of a sorted multiset of types, so the equality check at line 44 catches a translation that transposes which type occupies which argument slot. |

### Low

| File:line | Unit | What changed |
|---|---|---|
| `apple/QuenderinKit/Sources/QuenderinKit/ChatModel.swift:104` | apple | Added `model: ModelEntry? = nil` to `continueLast(options:model:)` and forwarded it to `send(...)`; the Continue chip in `ChatView.swift` now passes `model: activeModel`. Previously `ChatTier.of(model: nil)` always resolved `.small`, silently changing the reply's system-prompt/length policy for any larger model. |

## Deferred (needs an operator decision)

None. No finding in this round required an operator call.

## Skipped

- **`android/quenderin-core/src/main/kotlin/ai/quenderin/core/OnboardingModel.kt`** — claim: failed-model-switch
  restore skips reload when `previousId == model.id`, leaving the engine unloaded after a same-model retry failure.
  Skipped because the finding's own verdict is `real: false` and the scenario is structurally unreachable: every
  real call site of `acceptAndPrepare` prevents `model.id` from equaling the already-loaded model's id
  (`ModelPickerSheet` disables the current-model row; `ChatScreen`/`SettingsScreen` guard on `id != model.id`;
  the first-run onboarding path has no model loaded yet).
- **`android/quenderin-core/src/main/kotlin/ai/quenderin/core/LlamaEngine.kt`** — claim: `load()` leaves
  `loadedContextTokens` stale (non-null) after clearing `handle`/`loadedModelId` on a failed reload, violating the
  documented null-when-nothing-loaded contract. Skipped, verdict `real: false`: the only consumer
  (`ChatModel.kt:194`) is reached only while the UI renders `phase == Ready`, which is only true right after a
  `load()` that succeeded and set the value correctly; when `load()` + `restore()` both fail the UI unmounts
  before the stale value could be read. No other caller exists.

## Verify

**Result: clean — no failures, no bugs introduced by the diff.** Working tree matches the original
`git diff --stat` (15 files) with no stray changes left over from verification.

Commands run:

- `git diff --stat`
- `swift build`, `swift build --build-tests` (clean rebuild of QuenderinKit)
- `swift test --filter ConversationCoordinatorTests|ModelDownloaderTests|URLSessionModelDownloaderTests|OnboardingModelTests|ChatModelTests`
- `swift test` — full suite, **512 tests, 5 skipped, 0 failures**
- `npx tsc --noEmit -p ui` and `npx tsc --noEmit` (root) — both pass
- `npx eslint ui/src/components/PrivacyLock.tsx ui/src/hooks/useAgentSocket.ts --max-warnings=0` — pass
- `python3 scripts/build_xcstrings.py` against the live `scripts/translations.tsv` — output **byte-identical**
  to the committed `Localizable.xcstrings` (`git diff` empty), confirming no regression on existing translations
- `ast.parse()` syntax check on all 5 changed Python scripts
- Inline re-simulation of `refresh_model_hashes.patch_line()` against 4 synthetic Kotlin line shapes
  (hash × `languagesLabel`, all combinations) — all four yield a single correctly-placed hash, idempotent
- `python3 scripts/refresh_model_hashes.py` (real run) — correctly patched 3 catalog files carrying genuinely
  stale hashes (pre-existing state, unrelated to this diff); reverted via `git checkout --` since they were
  outside the original diff and only touched by this verification run

Cross-checks: `ChatView`'s `activeModel: ModelEntry?` lines up with the new `continueLast(model:)` parameter type;
`ModelDownloader`'s new `expectedSHA256` overload + default implementation compile and are wired correctly in
`OnboardingModel`; `useEffect` was already imported in `PrivacyLock.tsx`.

### Not runnable in this environment (reviewed manually instead, nothing installed)

- **`android/jni/llama_jni.cpp`** — `scripts/check-jni-syntax.sh` needs an NDK clang++ with the Android sysroot.
  The SDK's `ndk/27.1.12297006` here is a placeholder (only `.installer`, no toolchain). Manual review: the new
  fallback `n_ctx`/`n_batch`/`n_ubatch` resizing uses the same `std::max`/`std::min<uint32_t>` idiom already
  present a few lines above in the same function, and the 0.53 ratio traces to the `KVCachePolicy.kt` constant
  cited in the added comment.
- **`android/…/JvmDownloadIO.kt`** — no fast check available (would need a full Gradle+Android build); no existing
  unit test file for `JvmHttpRangeClient`. Manual review: the `Content-Range: bytes start-end/total` parse and the
  offset comparison are straightforward and correctly guard the existing `HTTP_PARTIAL` resume path.
- **`scripts/merge_kja_zh_{1,2,3}.py`** — syntax-checked only; not executed against the live `translations.tsv` to
  avoid repeating the out-of-scope mutation seen with `refresh_model_hashes.py`. The diff is a mechanical
  per-column conditional, structurally identical across all three files.
