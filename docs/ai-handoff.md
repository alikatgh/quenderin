# OpenCode tasks: native MAX/Bonsai integration

Updated 25 October 2026. This is the task packet for OpenCode, not a claim that
mobile MAX is available. Work in small, reviewable increments and report exact
source revisions and verification results.

Delivery status: queued in the existing OpenCode CLI session
`ses_e8dcb49b2ffe1GbFAXwXqNGtBX` ("Mobile MAX/Bonsai integration and UI validation
unfinished"). The durable prompt receipt is
`msg_quenderin_handoff_8153c6b7697826f5`. Admission used `resume: false`, so this
handoff did not start model execution. Resume that existing terminal session to
begin task 1; do not create a duplicate session or repeat the old `fb1bcb7` work.
Earlier new-session attempts returned HTTP 500 during disk pressure; they are
superseded by this confirmed delivery to the existing CLI session.

## Goal and verified starting point

Make the existing portable model boundary usable from native Android and Apple
code, then connect a real backend only when its artifacts and model contract are
verified. Preserve existing local inference, Automatic selection and Remote
Harness behavior.

- Main: `abc2af0d9fd9c872861d2fadec14c7e35b384bb1`, merged through PR #188.
- Tested head: `fcbe80104b12584255d128948e5dfd8fd184146f`; main has the same tree.
- `fb1bcb7` is an older source increment, not the starting point.
- Portable C boundary: `native/max-runtime/include/quenderin_max_model.h` and
  `native/max-runtime/src/quenderin_max_model.c`.
- Preserve the fixes for terminal UTF-8 flushing, context-clamp reporting and
  the single atomic admission/cancellation state. Cancellation must survive a
  completed BUSY response followed by cancellation before initialization.
- Read `docs/max-mobile-integration.md` and
  `docs/modular-acceleration-plan.md` for the missing runtime/model inputs.

Verified on the tested head: 49 Python tests; actual C fixture under ASan/UBSan;
Android arm64 and iOS SDK compile probes; both complete native SDK/app jobs;
secret scans; all 18 CI jobs. Evidence:

- MAX fixture: https://github.com/alikatgh/quenderin/actions/runs/40188095339
- Native SDK/apps: https://github.com/alikatgh/quenderin/actions/runs/40188095354
- Full CI: https://github.com/alikatgh/quenderin/actions/runs/40188095342
- Review and exact validation record: https://github.com/alikatgh/quenderin/pull/188

These are source/fixture/compilation results. Phone MAX inference, performance,
rendered UI and store submission remain unverified or deferred.

## Execution order and ownership

### 1. Refresh only the missing backend inputs

Owner: artifact audit; `native/max-runtime/mobile-lock.json`, its gate/tests and
`docs/max-mobile-integration.md`. Do not change the shared model catalog.

- Check maintained official MAX releases and the demo author's public build
  sources for Android/Adreno and Apple iOS artifacts. Reuse the recorded 26.7
  audit; do not repeat it unless the source/artifact changed.
- Record immutable source/compiler/backend identities, licenses and notices,
  telemetry controls, build recipe and exact Bonsai MEF/tokenizer/cache inputs.
- Deliver an evidence matrix of supplied versus missing inputs. A filename
  search or social video does not prove an executable backend or impossibility.
- Do not download weights or vendor SDKs locally, contact authors, install a
  provider, or clear a support flag on the strength of documentation alone.
- If inputs are missing, retain blocked support flags and proceed with the
  independent bindings below. Do not wait indefinitely or fabricate artifacts.

### 2. Implement the Android binding without enabling MAX

Owner: Android only; `android/jni/CMakeLists.txt`, a new JNI bridge beside
`android/jni/llama_jni.cpp`, new Kotlin binding/tests in
`android/quenderin-core/src/main/kotlin/ai/quenderin/core/` and its test tree.
Reuse `android/jni/jni_utf8.h` and existing engine/lease patterns.

- Bridge verified receipts, open/generate/cancel/close, numeric reports and
  unavailable/busy/error results. Use the production C implementation once.
- Own native handles, callback references and thread attachment explicitly.
  Preserve supplementary Unicode and embedded NUL; do not assume JNI modified
  UTF-8 is ordinary UTF-8. Bind callbacks/cancellation to the current run ID.
- Use synthetic runner fixtures for hosted JNI/JVM interoperability tests.
  No runner compiled means unavailable; a fake runner must never ship in the app.
- Acceptance: receipt failure, UTF-8 boundaries, cancellation before admission,
  cancellation during a callback, late callbacks, close-while-busy and reuse are
  tested through the binding. Hosted arm64 compilation passes. Existing engine
  selection and chat behavior remain unchanged.

### 3. Implement the Apple binding without enabling MAX

Owner: Apple only; `apple/QuenderinKit/Package.swift`, a narrow new C import
target/build receipt if needed, a new Swift binding and focused tests under
`apple/QuenderinKit/`. Inspect existing C SDK packaging before choosing the seam.

- Reuse the canonical native C implementation; avoid a second maintained copy.
  If staging is required, verify the staged source/header receipt in CI.
- Wrap the opaque handle with explicit lifetime and generation ownership.
  Synchronous native generation must not prevent cancellation from reaching it.
  Close waits for the lease to drain; stale callbacks cannot mutate a new run.
- Match Android's fixture scenarios and decoded text/statuses. Use hosted
  Swift/C interoperability tests and iOS SDK compilation; no local native build.
- Acceptance: no fake production backend, no selectable MAX option, deterministic
  failure/recovery, and existing Swift engine/agent behavior preserved.

Tasks 2 and 3 may run independently after confirming the shared C contract.
Their owners must not edit the C implementation or each other's build files.
Serialize any justified shared-contract change and obtain fresh review.

### 4. Implement the real runner and Bonsai contract when inputs exist

Owner: native runner/model contract, after task 1 supplies verified inputs.

- Implement `QMaxModelRunner` with the actual runtime: tokenizer, prompt template,
  sampling, stops, weight mapping, context and multi-turn cache lifecycle.
- Verify Bonsai PTQ1_0/Hadamard semantics against the existing Prism baseline.
  Reuse published conversion/runtime interfaces rather than rewriting MAX.
- Start with tiny synthetic model/cache fixtures on the hosted CPU route, then
  the exact reviewed model artifact through an authorized validation route.
- Acceptance: real load/generate probes, deterministic logits/token checks,
  history/cache round trips, cancellation and resource cleanup. Mark unavailable
  inputs explicitly; wrappers and successful compilation do not complete this task.

### 5. Package and admit the backend only after real probes pass

Owner: integration/release coordinator, after tasks 2-4 and independent review.

- Package an optional Android arm64 runner with verified dependencies, API floor,
  16 KiB alignment and graceful fallback. Treat Apple iOS/AOT packaging as a
  separate artifact/license milestone.
- Bind admission to exact model, runtime, compiled backend and driver identities,
  verified installation, memory/context fit and real load/generate results.
- Use existing generation leases and performance reports. Never silently move
  local conversations to an API/Host or admit MAX from a label or benchmark.
- Keep Automatic's default, manual choices, existing backends and recovery intact.
- Phone performance/UI and store submission remain outside this assignment.

## Constraints and verification

You are not alone in the repository. Preserve dirty work and all source
worktrees. Start from current `origin/main` in an isolated task branch/worktree;
do not switch or clean the user's dirty root checkout. Check session-storage
headroom before allocations; the latest handoff attempt observed critically low
local disk space. Do not delete user files or existing caches to make room.

No local weights/SDK installation, local native builds, simulator or physical
device runs. Use existing bounded hosted workflows. No store upload/submission,
provider/relay activation, new paid exposure, secret reads/exports, billing or
credential changes. Respect AGENTS.md and the existing Varlock/release rules.

First commands are read-only; inspect actual status before changing anything:

```sh
git status --short
git log -1 --format='%H %s'
```

For an implementation increment, run only affected lightweight checks locally:

```sh
python3 -B -m unittest discover -s native/max-runtime/tests -p 'test_*.py'
python3 -B native/max-runtime/tools/check_source.py
python3 -B native/max-runtime/tools/check_mobile_lock.py
```

Use PR-triggered hosted C/SDK checks for native execution and compilation. Retain
the admission-race regression, SHA padding/tamper vectors, output/context limits
and cancellation/reuse tests. Scan exact staged blobs before pushing. Obtain
fresh independent review for lifecycle/security/build changes, then verify the
combined revision. Reuse valid evidence for unchanged code; do not rerun a full
suite merely to update a Markdown status line.

Return one coherent increment with: files changed, exact revision, checks marked
passed/failed/blocked/not run, remaining missing inputs and the exact next task.
Do not report phone MAX support, speed or store readiness from these fixtures.
