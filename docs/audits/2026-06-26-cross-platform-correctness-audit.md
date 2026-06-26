---
title: "Cross-Platform Correctness Audit (Verified) — Quenderin"
repo: quenderin
lens: correctness / cross-platform parity
date: 2026-06-26
method: twin-diff + journal-pattern sweep, every finding fixed + regression-tested in the same session
---

## Scope & method

A full correctness pass over the **shared logic on all three platforms** — iOS (`apple/QuenderinKit`),
Android (`android/quenderin-core` + `:app`), and the desktop TS (`src/`) — plus the native engine
bindings. Two techniques, both proven repeatedly here:

1. **Twin-diff.** The iOS/Android cores are hand-ported twins (and the desktop TS is the reference they
   were ported from). Diffing a twin against its sibling surfaces stdlib-semantics drift that happy-path
   tests miss.
2. **Pattern sweep.** `grep` the `docs/BUG_JOURNAL.md` "scan FIRST" patterns across each platform
   (unbounded collections, off-by-N caps, first-`{`..last-`}` JSON extraction, unguarded `JSON.parse`,
   falsy-zero guards, in-place mutation of parsed arrays).

Every finding below was fixed **and** pinned with a regression test in the same session; counts and PRs
are listed. The sweep is now **clean** — that's the signal the systematic method is exhausted.

## Findings — 11 real bugs, all fixed + tested

| # | Bug | Platform | Severity | PR |
|---|-----|----------|----------|----|
| 1 | KV-cache mirror ran one token ahead of the real KV → **silently corrupted every multi-turn chat** | Android (JNI) | High | #55 |
| 2 | Hand-rolled JSON unescaper ignored `\uXXXX` → `café` rendered as `cafu00e9` in agent answers | Android | Medium | #59 |
| 3 | `SafetyBlocklist` Java `\b` is ASCII-only → `pin` blocked `piné`; iOS ICU `\b` didn't (safety-gate divergence) | Android | Medium | #60 |
| 4 | `DateFormatter` silently **rolled over** invalid dates (`2026-02-30`→Mar 2); `LocalDate` rejected them | iOS | Medium | #61 |
| 5 | Streaming chat indexed a message removed by Clear/History mid-reply → **crash** | iOS | High | #62 |
| 6 | `install()` had no concurrency guard → a double-tap could load the **wrong model** | iOS | High | #63 |
| 7 | Background download returned `Result.failure` on a constraint drop → **never auto-resumed** | Android (`:app`) | Medium | #64 |
| 8 | History title truncated by graphemes (Swift) vs UTF-16 (Kotlin) → different cut on emoji/CJK | iOS+Android | Low | #74 |
| 9 | Calculator `-2^2 = 4` (Excel convention) vs mobile + standard math `-4` (3-platform inconsistency) | Desktop | Low | #77 |
| 10 | Agent action parser used first-`{`..last-`}` (H13) → a trailing `}` dropped a valid JSON action | Desktop | Medium | #81 |
| 11 | Intent-classifier cache leaked **unbounded** via the LLM-fallback write path (bare `cache.set`, no eviction) | Desktop | Low | #82 |

**Root-cause theme:** 8 of 11 are **platform-stdlib divergence** — the same logical intent compiled
against Swift vs Kotlin vs JS standard libraries that disagree on an edge (regex `\b`, JSON escapes, date
leniency, grapheme-vs-UTF16 length, `@MainActor` reentrancy, WorkManager `failure` vs `retry`). The cores
have no automated cross-language parity check (unlike the catalog's `check:catalog-parity`); the only guard
is the ad-hoc `parity:` tests, which this pass extended.

## Surfaces verified CLEAN (no bug)

- **Engine:** iOS `LlamaEngine` KV-reuse path, `KVCacheReuse` plan logic.
- **Memory planning:** `ContextWindow` / `KVCachePolicy` (q8_0 scale preserves the f16 budget), full iOS↔Android parity.
- **Agent:** `AgentLoop` (halt reasons, safety-gate-before-execute, bounded by `maxSteps`), `ArithmeticParser`, `UnitConverter`, `DateCalc` (post-fix).
- **Download/persistence:** C3 integrity gate on all three downloaders (magic + SHA-256, discard-on-fail, self-heal); HTTPS-only; atomic conversation writes; path-traversal guards. The H9 "verify 206 Content-Range start" gap is made non-critical by the SHA-256 gate.
- **Model selection:** `ModelRecommender` RAM bands identical across all three platforms; catalog parity holds (11 models).
- **Desktop security surface:** WS auth (per-launch token, **fail-closed** on empty, constant-time compare), the action-executor safety gate (substring → over-blocks, never under-blocks, incl. raw-coordinate re-check), voice audio buffer (bounds-checked), `memory.service` (corrections capped at 500, trajectories at 50, `.reverse()` copy-fixed, cosine guards zero-norm), `readiness` history (bounded), all `JSON.parse` sites `try`-guarded, timers cleared.

## Generalizable patterns added to the bug journal

- String length/truncation: Swift graphemes vs Kotlin UTF-16 — truncate by **code points** for parity.
- ICU vs Java/JS regex `\b`: ASCII-only on Java/JS; add `(?U)` on Java, or avoid `\b` where Unicode matters.
- Hand-rolled JSON unescaper vs a real parser drifts on `\uXXXX`.
- Lenient date parsers silently roll over — validate by round-trip.
- A bounded cache/collection with **two write paths** must funnel both through one bounded setter.
- The H13 first-`{`..last-`}` JSON extraction lived in **three** platforms — re-grep a fixed pattern everywhere.

## Deliberate non-goals (recorded so they aren't re-litigated)

- **Calculator `round` / `log` / `ln` / trig on mobile.** The desktop reference has them, but their
  half-rounding and domain/precision behavior **differs across Swift/Kotlin/JS** — adding them would
  re-introduce exactly the divergences above. Only the parity-safe subset (`sqrt/abs/floor/ceil`, `pi/e`)
  was ported.

## What remains (not agent-doable — accounts / hardware)

- **Physical-device numbers:** run `QUENDERIN_VULKAN=1 android/verify-llama-link.sh` on the S23 for real
  prefill/decode tok/s (the harness now reports them separately); update `apple/REALITY.md` / `AndroidSoc`.
- **Store submission:** keystore → `:app:bundleRelease` → Play; iOS xcframework → archive → App Store.
  Full playbook in `docs/RELEASE.md`; the signing scaffold is in place.

The shared-logic surface is, as of this report, audited end-to-end and pristine-green
(iOS 195 tests / Android 177 core checks / desktop suite + lint + typecheck; catalog parity across all three).

## Addendum (2026-06-27) — deeper read of the desktop resource/error paths

The "Desktop surface verified clean" claim above rested on a **pattern sweep** (Maps/Sets, timers,
off-by-N, `JSON.parse`). A subsequent line-by-line read of the resource-heavy services — which the sweep
did NOT do — found **4 more real bugs**, all now fixed + tested + merged. The pattern was uniform:
**an async resource (native handle / child process / stream) dropped or errored without cleanup.**

| Bug | File | Why it bit | PR |
|-----|------|-----------|----|
| `unloadModel()` nulled `modelInstance`/`contextInstance` without `.dispose()` — the "free RAM" path (idle + memory-pressure auto-unload) freed nothing (native mem isn't GC-reclaimed); init OOM-fail leaked the loaded model too | `llm.service.ts` | High | #86 |
| `spawnAdb` had no `proc.on('error')` → adb-not-installed (ENOENT) threw an uncaught exception + hung until a misleading `ADB_TIMEOUT` | `android.provider.ts` | High | #87 |
| download + voice-extract write streams had no `'error'` handler → an `ENOSPC` mid-write (realistic on a ~2-5GB-free disk) crashed the process; the download loop could also hang/leak the handle | `llm.service.ts`, `app.ts` | Medium | #88 |

Verified clean on the same read (no fix needed): `modelIntegrity.sha256File` (read stream has `on('error')`),
`ocr.service` (cached worker, idle-terminate, explicit `terminate()`), `backgroundDaemon.pollLoop`
(stoppable, per-iteration try/catch, temp cleanup, ADB_MISSING noise suppression — which #87 makes
reachable), websocket heartbeat (`unref`'d), `memory`/`session`/`readiness` services.

**Lesson generalized into the journal:** every `spawn()`/stream/native-handle needs an `'error'`/dispose
path, and an "unload to free RAM" that only nulls frees nothing. The pattern sweep is necessary but not
sufficient for resource-lifecycle bugs — those need a read of the create→use→error→cleanup arc.
