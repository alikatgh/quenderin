# Review: dynamic planning + open HF catalog

**Date:** 2026-07-08
**Reviewed range:** `e4a0d63..7a0d11a` (4 commits, 2026-07-08)
**Status:** 2 CONFIRMED, 3 PLAUSIBLE, 5 REFUTED — drives an immediate fix pass on the 2 CONFIRMED items.
**Verification:** static trace only — **not rendered/run on this box** (machine is disk-limited, see memory `quenderin-machine-disk-limited`; llama.cpp / full Swift build not exercised here). All line refs verified against the current tree.

Commits in range:

| SHA | Subject |
|---|---|
| `e4a0d63` | feat(agent): dynamic planning — let the model author its own plan for the long tail (honest, flag-gated) |
| `34f60e4` | feat(models): searchable open Hugging Face catalog — download any GGUF your hardware runs, integrity-gated |
| `ef2e740` | fix(models): search superseding must bump the token on the idle reset too |
| `7a0d11a` | feat(models): surface downloaded open-catalog models in the library's "On this Mac" |

## 1. What was reviewed

Two features shipped together on 2026-07-08:

- **Dynamic planning** (`AgentLoop.swift`, `AgentRecipe.swift`) — for goals outside the 3 hardcoded regex recipes, one grammar-constrained decode lets the model author its own `[{tool,label}]` plan, wrapped as a dynamic `AgentRecipe`, flag-gated off by default. Prior design doc: `docs/audits/2026-07-08-dynamic-planning.md`.
- **Open Hugging Face catalog** (`HuggingFaceModelSearch.swift`, `OnboardingModel.swift`, `ModelSearchController.swift`, `ModelSearchView.swift`, `ModelsLibraryView.swift`) — searchable HF catalog, download any GGUF, namespaced local filenames, integrity-gated, resolved alongside the compiled `ModelCatalog` at both boot and mid-session model switch.

macOS-only, no Android/iOS/TS twin for either feature (per memory `macos-product-is-swift-app` — this is the intended shape, not a parity gap).

## 2. Dimensions covered

- **hf-integration** — boot/switch resolution of `hf:`-prefixed ids against `SideloadedModels` vs. the compiled `ModelCatalog`; download URL construction; local filename safety/collision avoidance.
- **dynamic-planning** — step-budget accounting (`stepCap`) for model-authored plans; cursor-advance honesty under `.plan` batch execution; the H1/H2 guarantees the design doc commits to (failed-switch restore; stall-triggered self-abandon).

## 3. CONFIRMED findings

### 3.1 [HIGH -> re-scored MEDIUM in review] Failed-switch restore omits the `SideloadedModels` fallback — H1 breaks for HF models

- **File:** `apple/QuenderinKit/Sources/QuenderinKit/OnboardingModel.swift:280-287`
- **Failure scenario:** An HF-searched model (`hf:`-prefixed id) is currently loaded. User switches to a different model and the new load throws (corrupt file, engine incompatibility, OOM). The catch block's restore guard —
  ```swift
  if let previousID, previousID != model.id,
     let previous = ModelCatalog.entry(id: previousID),
     await restore(previous) {
  ```
  — queries only `ModelCatalog`. An `hf:` id is never in the compiled catalog (that's the whole point of `SideloadedModels`), so the `if let previous` binding fails even though the previous model's file is still on disk and would reload fine. Control falls to `phase = .failed(...)` with the engine left unloaded, contradicting the method's own doc comment ("the previously-working model is restored (H1)").
- **Why confirmed:** the exact same class of lookup was already patched at the boot fast-path, `OnboardingModel.swift:115`: `ModelCatalog.entry(id: id) ?? SideloadedModels.shared.entry(id: id)`. This sibling call site at line 281 was never given the matching `?? SideloadedModels.shared.entry(id:)` fallback. `previousID` is guaranteed non-nil and `!= model.id` on any real switch away from a loaded HF model, so the bug fires deterministically, not conditionally.
- **Fix:** mirror line 115 at line 281:
  ```swift
  let previous = ModelCatalog.entry(id: previousID) ?? SideloadedModels.shared.entry(id: previousID),
  ```

### 3.2 [re-scored MEDIUM in review] Zero-slack `stepCap` lets a fully-successful maximal-length dynamic plan return a false `.maxSteps`

- **File:** `apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift:113` (interacts with `AgentRecipe.swift:98` and the loop body at `AgentLoop.swift:136,306-313`)
- **Failure scenario:** default `maxSteps = 6`. The dynamic-planning prompt (`AgentLoop.swift:343`) invites "2 to maxSteps steps", and `AgentRecipe.parsePlan` (`AgentRecipe.swift:98`) accepts a plan with `steps.count == maxSteps`. For a dynamic recipe, `stepCap = maxSteps` — no `+2` slack, unlike curated recipes (`max(maxSteps, steps.count + 2)`). If the model then executes all 6 planned calls correctly, one per turn, `for _ in 0..<stepCap` (line 136) is exhausted exactly when the cursor completes; there is no iteration left to decode `{"answer":...}`. The loop falls through to the bottom fallback (lines 306-313) and reports `.maxSteps` ("reached its step limit before reaching an answer") even though every planned step genuinely succeeded.
- **Why confirmed:** the precondition (`steps.count == maxSteps` for a dynamic recipe) is explicitly permitted by `parsePlan`'s own clamp, not a freak input; curated recipes structurally always get `steps.count + 2` turns and are unaffected, which is the exact asymmetry that exposes the gap.
- **Severity note:** downgraded from the raw finding's "high" to medium in review — the feature is flag-gated OFF by default, the false positive requires a *perfect* maximal-length run (any stall makes `.maxSteps` an honest result), and the 6 tool side-effects did execute; the harm is a misleading "try a simpler goal" banner plus possible re-execution of side-effectful tools on retry.
- **Fix:** give dynamic plans one extra iteration for the answer turn without restoring full curated slack:
  ```swift
  let stepCap = recipe.map { $0.isDynamic ? max(maxSteps, $0.steps.count + 1) : max(maxSteps, $0.steps.count + 2) } ?? maxSteps
  ```
  Using `max(maxSteps, steps.count + 1)` (not a bare `steps.count + 1`) matters so a *short* dynamic plan is never starved below the plain nil-recipe budget — it only adds a turn in the maximal case, exactly where the answer turn is missing.

## 4. PLAUSIBLE findings (real but narrower/lower-severity than first claimed)

### 4.1 [LOW] HF download URL built without percent-encoding the filename

- **File:** `apple/QuenderinKit/Sources/QuenderinKit/HuggingFaceModelSearch.swift:31-33`
- **Failure scenario:** a community GGUF quant whose real filename contains a space or other URL-reserved character (uncommon but not impossible on an open catalog) is spliced unencoded into `URL(string: "https://huggingface.co/\(repo)/resolve/main/\(filename)?download=true")`. If URL parsing fails, `downloadURL` is nil, `candidate(from:)` falls back to `urlString: ""`, and the quant becomes permanently undownloadable ("no valid download URL").
- **Review narrowing:** the reviewer's stated mechanism (`URL(string:)` returns nil for a literal space) is **false on this host** — since iOS 17/macOS 14, `URL(string:)` defaults to `encodingInvalidCharacters: true` and auto-percent-encodes the space; confirmed empirically on this macOS 15 box. The bug is real only on the package's lower deployment targets (`Package.swift:66-68` declares `.macOS(.v13)`/`.iOS(.v16)`), where the legacy parser does return nil. So it's conditional on OS version, not universally live.
- **Fix:** percent-encode before interpolating, which is also correct on every OS version:
  ```swift
  public var downloadURL: URL? {
      let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
      return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)?download=true")
  }
  ```

### 4.2 [LOW] `safeLocalFilename` bounds only the repo slug, not the appended filename

- **File:** `apple/QuenderinKit/Sources/QuenderinKit/HuggingFaceModelSearch.swift:89-93`
- **Failure scenario:** the doc comment claims the 100-char repo cap prevents overrunning the 255-byte filename limit, but only `repo` is capped — `filename` is appended verbatim with no bound. A sufficiently long real HF filename (independent of repo length) can push the combined local filename past the OS 255-byte-per-component limit, causing the download's `FileManager` write/rename to fail with ENAMETOOLONG (`DownloadError.writeFailed`), surfacing as an opaque "Couldn't save the model" for an otherwise legitimate quant.
- **Review narrowing:** requires a real HF filename ≥ ~154 bytes (typical GGUF names run 40-110 chars); the failure is graceful (one download fails with a message), not corruption — hence low, not medium, practical severity.
- **Fix:** bound the combined component, not just the repo prefix, trimming from the filename head while preserving the `.gguf` suffix (see full snippet in the raw findings JSON).

### 4.3 [LOW] `.plan` batch cursor credit gated on the aggregate observation string

- **File:** `apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift:286-290`
- **Failure scenario:** a `.plan` decision batches several tool calls; `runner.executePlan` returns ONE combined observation string, and `advanceRecipe` runs for ANY call in the batch only if the WHOLE string passes `!isFailureObservation`. If one call among several genuinely-succeeding calls fails and its failure text lands in the aggregate, none of the batch's calls get cursor credit — including the ones that truly ran — which can falsely count toward the `dynamicStalls >= 2` self-abandon threshold.
- **Review narrowing:** `CapabilityRunner.executePlan` executes sequentially and **breaks on first failure**, and its own failure text ("N. Failed: …", "Stopped after step N of M") is not itself in the `isFailureObservation` marker set — so a partial-fail batch doesn't reliably trip this path in the first place. Reaching `dynamicStalls >= 2` requires the *same* step to fail on two consecutive turns, which is the designed self-abandon behavior for a genuinely stuck plan, not a false positive on a working one. Outcome is also soft/reversible (steering-line demotion only; `stepCap` and guard-skip behavior unaffected; any clean batch resets `dynamicStalls` to 0).
- **Fix (optional hardening, not required for correctness):** have `executePlan` return a per-call outcome so `advanceRecipe` can credit the leading successes before the first failure, rather than gating on one aggregate string.

## 5. Clean bill on the rest

No other issues were confirmed in the reviewed range. In particular, the mechanisms below were traced and are **not bugs** — see §6 for the one-line refutation of each.

## 6. Refuted claims (for audit trail)

1. **`loadQuants()` has no cancellation/token guard, so `clear()` doesn't invalidate an in-flight quant fetch** → the resurrected entry is never read by any consumer after `clear()` (view state and `quants` dict both reset together), and the "stale" data is identical, immutable HF file-list content — no observable wrong state.
2. **`SideloadedModels`' `@unchecked Sendable` is unsound because `record()` is a non-atomic read-modify-write** → every shipped call site (`ModelSearchView` button actions, `ModelLibraryController.delete`) is MainActor-isolated, so calls are serialized in practice; no concurrent caller exists in the shipped code.
3. **`safeLocalFilename` doesn't normalize case, causing collisions on case-insensitive filesystems** → HF owner handles and repo names are already case-insensitively unique upstream; the precondition (two distinct repos differing only by case) cannot occur.
4. **`QuantRow.state` runs a synchronous disk stat on every render, amplified across expanded repos** → `expanded` is single-valued (only one repo open at a time) and download progress is throttled to 1%-delta events (~100 total per download), so the claimed stutter amplification doesn't materialize.
5. **Fallback file-existence check can report a truncated/unverified partial download as "installed"** → the production downloader streams to a `.partial` file and only atomically moves it to the final filename inside `didCompleteWithError` on success; a truncated file never lands at the path the existence check inspects.

## 7. Priority for the fix pass

1. `OnboardingModel.swift:281` — add the `SideloadedModels` fallback (§3.1). One-line fix, restores a stated guarantee (H1).
2. `AgentLoop.swift:113` — add answer-turn slack for maximal-length dynamic plans (§3.2). One-line fix, flag-gated feature so low urgency but cheap to close now.
3. `HuggingFaceModelSearch.swift:31` and `:89` — percent-encode + bound filename length (§4.1, §4.2). Cheap, defensive, no behavior change for the common case.
4. §4.3 — optional; leave as-is unless per-call plan telemetry is wanted anyway.
