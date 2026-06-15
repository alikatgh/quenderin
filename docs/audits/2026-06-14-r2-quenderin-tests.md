---
title: Tests Audit — Quenderin (Round 2, Verified)
repo: quenderin
lens: tests
date: 2026-06-14
round: 2
---

I have verified all the load-bearing claims. The H3 "prefix match bug" sub-claim is overstated — in practice the double-resolve doesn't disagree (the handler passes an already-absolute path, so the re-resolve and `~`-replace are no-ops). The `startsWith(home + path.sep) || resolved === home` check is actually correct against sibling-prefix attacks. I'll downgrade that sub-point: the gap is genuinely "untested," not "has a bug." The H3 finding stands on the "untested security boundary" merit.

I have everything needed. Let me compile the final verified report.

# Tests Audit — Quenderin (verified)

Repo: `/Users/svetlana/Documents/projects/quenderin`. Read-only audit, every finding re-checked against source.

## Scope verified
- **6 TS test files** in `tests/` (constants, recommended-model, manifest, intent-classifier, sanitize-attachments, session.service). 42 `.ts` source files in `src/` — the vast majority untested.
- **28 Swift test files** (the draft said 25 — corrected) in `apple/QuenderinKit/Tests/QuenderinKitTests/`. Broad and high quality.
- **1 Kotlin JUnit test** (`android/quenderin-core/src/test/kotlin/ai/quenderin/core/CoreTest.kt`) for **29** `core/src/main` source files, plus two dependency-free `src/verify/` harnesses.
- **0 UI tests** (`ui/package.json` has no `test` script; no `*.test.tsx`/`*.spec.tsx` exist).
- CI (`.github/workflows/ci.yml`) runs **only** the Node/TS suite. Confirmed `ci.yml` is the only relevant workflow (`website/deploy/github-pages.yml` is unrelated). No `docs/BUG_JOURNAL.md` exists.

---

## CRITICAL

### C1. CI runs only the Node/TS suite — the entire Swift and Kotlin suites are never executed [CONFIRMED]
`.github/workflows/ci.yml:30-40` runs `npm run lint`, `npm run check:recommendation`, `npm test`, `npm run build` on `ubuntu-latest` only. There is no `swift test`/`xcodebuild test` job and no `./gradlew test` job.

Impact: The 28 Swift tests and `CoreTest.kt` — which encode the cross-platform invariants (recommender thresholds, memory fitness, safety blocklist, agent loop, onboarding, conversation persistence) — can break and CI stays green. Recent history is dominated by iOS/Android work (`feat(ios)`, `feat(android)`, `feat(chat)`, `test(android)` — verified in `git log`), i.e. the highest-churn, least-protected surface. The Swift golden-path and Kotlin golden-path tests are explicit "M1→M2→M4 compose" regression guards that nothing enforces.

Fix: Add a `macos-latest` job running `cd apple/QuenderinKit && swift test` and an Android job running `cd android && ./gradlew :quenderin-core:test` (or at minimum compile+run the dependency-free `src/verify/CoreVerify.kt` / `GoldenPathVerify.kt`, which need only `kotlinc + java`). Make both required checks.

### C2. The cross-language catalog-parity guardrail is never run in CI [CONFIRMED]
`scripts/check_catalog_parity.py` documents itself ("Run it in CI / before a release") as the guardrail preventing iOS/Android catalogs from drifting from desktop. The npm script `check:catalog-parity` exists (`package.json:29`) but is **not** invoked by `ci.yml` and **not** part of the `check` script (`package.json:16` = `typecheck && lint && test:recommendation` only). `tests/manifest.test.ts:6-11` explicitly states it only guards desktop↔JSON (the JS-native half), not Swift/Kotlin↔JSON.

Impact: Editing `ModelCatalog.swift` or `ModelCatalog.kt` (id/params/quant) without updating `src/constants.ts` + regenerating `shared/model-catalog.json` silently makes platforms recommend different models for the same hardware — exactly what the script exists to prevent. (Note: the script intentionally does NOT catch ramGb/label/url drift — see M2, which is a separate exposure.)

Fix: Add a CI step `python3 scripts/check_catalog_parity.py` (exits 1 on drift; pure Python, no deps) and add it to the `check` npm script.

---

## HIGH

### H1. `session.service` tests assert almost nothing about the behavior they name [CONFIRMED]
`tests/session.service.test.ts`:
- `'addMessage sets session title from first user message'` (lines 25-34): comment admits "we verify the message count instead"; the only assertion is `messageCount ?? 0 >= 0` — **always true**. Never checks the title-derivation logic at `session.service.ts:95-97` (`.slice(0,80)` + `\n`→space).
- `'addMessage increments message count'` (lines 36-46): asserts only `id).toBeTruthy()` — never checks the count.
- `'destroy cancels pending flush timer'` (lines 65-70): comment "Should not throw"; no assertion.

Untested as a result: title derivation, the `MAX_MESSAGES_PER_SESSION` cap (`:103-105`), `pruneOldSessions`/`MAX_SESSIONS` (`:217-228`), the `loadSession` round-trip, the `sessionPath` path-traversal sanitizer (`:48-52`, `replace(/[^a-zA-Z0-9\-_]/g,'').slice(0,64)`), and `exportMarkdown` content. The passing tests give false confidence.

Fix: Point the service at a temp dir (`SESSIONS_DIR` is module-level at `:40` — inject via a HOME fixture), call `destroy()` to force the flush, then assert: title = first user message truncated to 80 chars with newlines stripped; over-cap messages dropped from the front; >`MAX_SESSIONS` files pruned; `loadSession` round-trips; `sessionPath('../../etc/passwd')` stays inside the dir; `exportMarkdown` contains the message text.

### H2. The safe calculator — the headline "NO eval()" parser — has zero TS tests [CONFIRMED]
`src/services/tools/calculator.ts` (227 lines: tokenizer + recursive-descent parser + 10 functions + 2 constants). Grep confirms **no** `tests/` file references `calculator`/`safeCalculate`.

Untested edge cases that need regression coverage: division by zero (`:117`), modulo (`%`, `:120` — `x % 0` → `NaN`, then `safeCalculate` throws "Result is not finite" at `:223-225`, a distinct untested path), right-associative `^` (`:126-133`), unary-minus vs `^` precedence (`-2^2`), unknown identifiers (`:67`), unexpected characters (`:72`), the 500-char cap (`:214-216`), empty/whitespace input (`:218-220`), trailing/leftover tokens (note: `parseExpression` does **not** assert all tokens consumed, so `"2 3"` evaluates to `2` silently — worth a test), mismatched parens (`:186-188`), `log`=base-10 vs `ln`=natural (`:202-203`).

Fix: `tests/calculator.test.ts` driving `safeCalculate`: precedence/associativity, every function + constant, every `CalculatorError` branch, plus a fuzz batch asserting no non-`CalculatorError` throw and finite results.

### H3. Path-traversal protection in `read_file` (and `note_save` filename sanitization) is untested [CONFIRMED — but the "prefix-match bug" sub-claim is a FALSE POSITIVE]
`src/services/tools/handlers.ts:25-29` (`isInsideHome`), used by `read_file` (`:74-111`) and `note_save` (`:119`). No TS test exercises any tool handler.

This is the security boundary that stops the LLM-driven `read_file` tool from reading arbitrary files, and it is entirely untested.

**Correction to the draft:** the draft flagged a possible "double-resolve disagreement / naive `startsWith(home)`" bug. Verified there is **no live bug**: the handler resolves to an absolute path at `:82` and passes that into `isInsideHome`, where the `replace(/^~/, home)` and second `path.resolve` are both no-ops on an already-absolute path. The check `resolved.startsWith(home + path.sep) || resolved === home` (`:28`) is **correct** against sibling-prefix attacks (e.g. `${home}-evil` is rejected because of the trailing `path.sep`). The real risk is regression-under-refactor, not a current defect. Treat this as a coverage gap, not a bug.

Fix: `tests/tool-handlers.test.ts` (temp HOME) asserting `read_file` denies `../../etc/passwd`, absolute paths outside home, and `${home}-evil/secret`; allows a real file under home; rejects directories/missing files; and truncates at `MAX_FILE_READ_BYTES` (8000) with `truncated:true`. Assert `note_save` strips `../` and special chars from the filename (`:119`).

### H4. The tool-call parse/strip/loop layer is untested in TS [CONFIRMED]
`src/services/tools/toolLoop.ts` (`parseToolCalls`, `hasToolCalls`, `stripToolCalls`, `formatToolResults`, `runToolLoop`) and `executeToolCalls` (`handlers.ts:159-164`) — no tests. This bridges raw LLM output to tool execution, used by `llm.service.generalChat` (`:979`).

Untested behaviors with real failure modes: malformed JSON args silently fall back to `{}` (`toolLoop.ts:23-30`, dropping arguments); the 3-iteration cap (`MAX_ITERATIONS`, `:11,74`); `MAX_CALLS = 5` truncation (`handlers.ts:161`); the regex's handling of multiple/whitespace-laden `<tool_call>` blocks (`:16`); `stripToolCalls` collapsing `\n{3,}` (`:44-45`).

Fix: Unit-test `parseToolCalls` on well-formed / malformed-JSON (→`{}`) / multiple / zero blocks; `stripToolCalls` on interleaved text; `executeToolCalls` truncation at 5; `runToolLoop` with a stubbed `promptWithResults` proving it stops at 3 iterations and breaks on a thrown re-prompt.

### H5. WebSocket streaming tool-call suppression is complex, untested, and the suppressor cannot be unit-tested in isolation [CONFIRMED]
`src/websocket/index.ts:230-268` hand-rolls a streaming `<tool_call>` suppressor inside the `ws.on('message')` closure: complete blocks (`:239-245`), an open-without-close block (`:248-254`), and a partial `<tool_call` tail prefix split across tokens (`:257-264`). It is the trickiest stateful code in the WS layer and has no test. The entire `message` handler — origin validation (`:96-102`), goal/chat length caps (`:168, :213`), `settings_update` allow-listing (`:303`), heartbeat termination (`:71-83`), listener cleanup on reconnect (`:108-115`) — is also untested.

Impact: A token boundary inside `<tool_call` or an unbalanced block could leak raw tool XML to the user or drop legitimate text. Because the logic is embedded in a closure, it can't be exercised without booting the server.

Fix: Extract the suppressor into a pure function (`makeToolCallStreamFilter()` returning `feed(token) → emittedText`); unit-test by feeding the same text in 1-char, 2-char, and whole-message chunkings and asserting concatenated output == input minus tool blocks. Add a WS integration test — the pattern already exists (`tests/recommended-model.test.ts` boots a real server) — driving a `ws` client through valid/invalid `start`/`chat` and a disallowed `Origin`.

### H6. `sanitizeAttachments` is tested via a copy-paste re-implementation, not the shipped function [CONFIRMED]
`tests/sanitize-attachments.test.ts:1-21` re-implements the function ("We test it indirectly by re-implementing the same logic since it's private"). The real one is `src/websocket/index.ts:14-26`. Verified byte-for-byte identical **today** — but the test asserts nothing about shipped code. Any future change to the real `sanitizeAttachments` (or `MAX_ATTACHMENTS`/`MAX_ATTACHMENT_SIZE` semantics) passes silently. Textbook "tested behavior ≠ shipped behavior."

Fix: `export` `sanitizeAttachments` from `websocket/index.ts` (or move to a `utils/` module) and import the real function. Delete the copy.

---

## MEDIUM

### M1. Intent-classifier tests skip the discriminating cases and the cache [CONFIRMED]
`tests/intent-classifier.test.ts`: the `math` and `image` intents (`intentClassifier.ts:32-42, 76-77, 91-93`) are never asserted. The `code` test (`:27-31`) accepts `['code','chat']`, so it passes even if code detection breaks entirely. Edge tests assert only `toBeDefined()` (`:36-37, 43`). The cache eviction at `MAX_CACHE_SIZE=200` (`intentClassifier.ts:64-68`), the `classifyWithLlmFallback` `intentMap`/error path (`:103-149`), and `clearIntentCache` (`:152-154`) are all untested.

Fix: Add explicit `math` (`"calculate 2+3*4"`, `"sqrt(16)"`, pure expression) and `image` (`"draw a picture of a cat"`) assertions; tighten the `code` test to `toBe('code')`; test `classifyWithLlmFallback` with a stub returning `"MATH"` and a garbage string; test eviction by inserting 201 distinct inputs.

### M2. The 10 GB→14B boundary recommends a model whose own footprint exceeds the device RAM — and tests pin it [CONFIRMED, real consistency concern]
`getRecommendedModelIdForTotalRam` (`constants.ts:180-186`) returns `'qwen3-14b'` for `totalRamGb >= 10`. But `qwen3-14b` has `ramGb: 11.0` (`constants.ts:67-74`). So a 10 GB device is told to download a model whose estimated peak footprint (11 GB) exceeds its total RAM. Both `tests/constants.test.ts:75` and `tests/recommended-model.test.ts:30` assert `getRecommendedModelIdForTotalRam(10) === 'qwen3-14b'`, locking the threshold in without validating it. No test cross-checks "recommended model's `ramGb` ≤ device RAM." `MODEL_RECOMMENDATIONS` (`:53-54`) even disagrees with the function: it caps an 8–12 GB device at `maxParams: 8`, not 14 — an internal inconsistency the tests don't catch. The Kotlin/Swift recommenders pin the same boundary (catalog-parity by design does NOT cover `ramGb`, so this can't be caught cross-platform either).

Note on severity: this is a recommendation/UX bug, not a crash — `checkMemoryForModel` (`constants.ts:196`) still runs at load time as a backstop, so the user is warned/blocked before OOM. But the recommender actively steers 10 GB devices to an over-budget model, and the tests entrench it.

Fix: Add a property test over a RAM sweep: `MODEL_CATALOG.find(recommended).ramGb <= ram` (or `<= ram * MEMORY_BUDGET_HARD`). Decide whether 10→14B is intentional; if not, raise the threshold (likely to 12) and update the pinned tests in all three languages together.

### M3. No regression tests tied to the recent `fix(...)` commits; no bug journal [CONFIRMED]
`git log` shows `fix(ci): drop EOL Node 18`, `fix(android): wrapper/useAndroidX/missing imports`, `fix(desktop): correct stale recommendation test` (`46b3165`), `fix(ios): default to real LlamaEngine`. The project's own `CLAUDE.md` ("Do not delete failing tests. Fix them") and the global bug-journal protocol imply fixes ship with a regression guard. `docs/BUG_JOURNAL.md` is **confirmed absent**. The "stale recommendation test" fix is exactly the kind of test-rot that recurs without a guard — and given C1/C2, the mobile suites aren't even in CI to catch a recurrence.

Fix: Create `docs/BUG_JOURNAL.md` (the global rule provides a bootstrap). For each fix, add the one assertion that would have caught it (the stale-recommendation fix → the M2 property test; the android missing-import → a `gradle`/`CoreVerify` compile step in CI).

### M4. The one TS integration test binds a real OS port (flake risk); the suite shares module-level singletons [CONFIRMED]
`tests/recommended-model.test.ts:45-49` does `app.listen(0)` + `fetch('http://127.0.0.1:…')` with no timeout/retry — a classic CI-flake source (port races, IPv4/IPv6, slow-CI). Separately, `intentClassifier`'s module-level `cache` (`intentClassifier.ts:46`) and `registry.ts:9`'s module-level `const HW = getHardwareProfile()` are process-global state shared across test files with no reset, which can produce ordering-dependent failures under `vitest` parallelism.

Fix: Use supertest (`request(app)`) instead of `listen(0)`+`fetch`, or add `afterEach(server.close)` with a connection timeout. Call `clearIntentCache()` in a `beforeEach` for classifier tests.

### M5. Android has effectively one test file for 29 core modules; download/persistence/JNI paths are untested [CONFIRMED — with file-name corrections]
`CoreTest.kt` is the only JUnit test (verified 29 `.kt` files in `core/src/main`). Grep confirms **zero** references in `CoreTest.kt` to `ConversationStore`, `ConversationLibrary`, `ConversationManager`, `JvmDownloadIO`, `DownloadStore`, or any WorkManager symbol.

**Correction to the draft:** the files `WorkManagerModelDownloader.kt` and `ModelDownloadWorker.kt` named in the draft **do not exist**. The actual download-layer modules are `ModelDownloader.kt`, `ModelDownloadEngine.kt`, `JvmDownloadIO.kt`, and `DownloadStore.kt` — these (plus `ConversationStore/Library/Manager` and the real `LlamaEngine` JNI path) are the untested ones. On the Swift side, verified to have no dedicated `*Tests.swift`: `AgentSession`, `BackgroundModelDownloader`, `DefaultInferenceEngine`, `ScriptedInferenceEngine`.

Impact: The download/persistence/resume layer — most likely to corrupt user data or hang on flaky networks — is the least tested on mobile.

Fix: Add Kotlin tests for `ConversationStore` encode/decode round-trip (parity with the Swift `ConversationStoreTests`), `JvmDownloadIO` partial-download/resume, and `DownloadPolicy`. Add Swift coverage for `BackgroundModelDownloader` resume semantics.

### M6. Zero tests for the React UI [CONFIRMED]
`ui/package.json` has no `test` script (verified); no `*.test.tsx`/`*.spec.tsx` files exist. Components with real logic — `useAgentSocket` (WS reconnect/state, the client counterpart to H5), `ErrorBoundary`, `CodeBlock`, tool-call stream rendering — are entirely unverified.

Fix: Add Vitest + React Testing Library to `ui/`. Prioritize `useAgentSocket` (mock `WebSocket`, assert reconnect/backoff and message dispatch) and `ErrorBoundary`.

---

## LOW

### L1. `stripControlTokens` and `generateId` are untested [CONFIRMED]
`src/utils/stripControlTokens.ts` has 9 regex patterns (incl. the tool-call-block strip at `:18`, which **overlaps** `toolLoop.stripToolCalls` — two implementations of the same strip, neither tested). It is on the hot path of every chat token (`llm.service.ts:909, 951, 970, 979` — verified); a regex regression garbles all output. `src/utils/generateId.ts` is also untested. Fix: snapshot tests per control-token pattern (ChatML, Llama-3 headers, `</s>`, BOS) + an idempotency check.

### L2. `memory.ts`, `hardware.ts`, `uiParser.service.ts`, `metrics.service.ts`, `readiness.service.ts` untested [CONFIRMED]
All exist, none referenced by any `tests/` file. `memory.ts`/`hardware.ts` feed model-fitness decisions (`checkMemoryForModel`, `getHardwareRecommendation` at `constants.ts:196-246`). `uiParser.service.ts` (122 lines, verified) is parser-shaped like the calculator and equally deserves edge-case tests (malformed XML, empty trees, deep nesting). Fix: table-driven tests for the recommender's consumers and `uiParser` on malformed input.

### L3. `coverage` job uploads but enforces no threshold [CONFIRMED]
`ci.yml:59-65` runs `test:coverage` and uploads to Codecov with `fail_ci_if_error: false`; `vitest.config.ts` sets `coverage` (provider v8, reporters, excludes) but **no `thresholds`** (verified). Coverage is reported but can never fail the build, so it can silently trend toward zero on the already-thin TS suite. Fix: add `coverage.thresholds` in `vitest.config.ts` once H2–H4 land, and/or a Codecov status check.

### L4. Manifest test doesn't force a `MANIFEST_VERSION` bump on schema change [CONFIRMED]
`tests/manifest.test.ts:18-21` checks `committed.version === MANIFEST_VERSION` (`=1`, hand-maintained at `manifest.ts:4`) and equal model counts, and the field-by-field check (`:23-36`) covers a fixed `FIELDS` list — but nothing forces `MANIFEST_VERSION` to bump when a breaking field is added/removed. Low impact. Fix: snapshot the frozen field-set and require an explicit update when it changes.

---

## Strengths (for balance)
- The Swift suite is genuinely thorough: 28 per-module tests plus an end-to-end `GoldenPathTests` proving the probe→recommend→download→load→chat→agent pipeline composes on one engine, and `LlamaEngineRealInferenceTests` gated behind `XCTSkip` (verified) so it stays green without a model.
- `CoreTest.kt` mirrors the same invariants (recommender, memory fitness, safety blocklist, agent loop with safety gating, arithmetic parser), and `GoldenPathVerify.kt` mirrors the Swift golden path.
- `tests/recommended-model.test.ts:34-71` is a real cross-route consistency guard (`/health` recommendation == `/api/models/download` default).
- The catalog-parity design (canonical JSON + per-language parsers) is sound — it just isn't wired into CI (C2).

---

## Recommended next steps (in order)
1. **C1** — add Swift + Kotlin test jobs to CI. Single biggest exposure: the highest-churn code has zero CI protection.
2. **C2** — run `python3 scripts/check_catalog_parity.py` in CI and add it to the `check` npm script. Cheap, closes a silent cross-platform divergence.
3. **H2 / H4 / H3** — test the calculator, the tool-call loop, and the `read_file`/`note_save` path-traversal guard. All security/correctness-relevant, all currently zero-coverage. (H3 is a coverage gap, not a live bug — the "prefix-match bug" sub-claim was a false positive and is removed.)
4. **H1 / H6** — make the session tests assert real behavior; test the real `sanitizeAttachments`, not a re-implemented copy.
5. **H5** — extract the streaming tool-call suppressor into a pure, unit-testable function and add a WS integration test.
6. **M2** — convert the recommender threshold tests into a catalog-consistency property test (`recommended.ramGb <= ram`), and decide whether the 10 GB→14B (11 GB-footprint) boundary is intended; if not, fix it across all three languages together.
7. **M3** — create `docs/BUG_JOURNAL.md` and back-fill a regression assertion per recent `fix(...)` commit.

Corrections applied vs the draft: Swift test count is **28** (not 25); the Android files `WorkManagerModelDownloader.kt`/`ModelDownloadWorker.kt` in M5 **do not exist** (real files named); the H3 "prefix-match bug" is a **false positive** (downgraded to a coverage gap). Added: the `parseExpression` "leftover tokens not rejected" case (H2), the `MODEL_RECOMMENDATIONS` vs `getRecommendedModelIdForTotalRam` internal inconsistency (M2), and the duplicate tool-call-strip logic across `stripControlTokens.ts:18` and `toolLoop.stripToolCalls` (L1).
