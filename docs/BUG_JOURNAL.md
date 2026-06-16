# Bug Journal

Cheap-to-write, cheap-to-read, expensive-to-skip. `grep -i <symptom>` this before debugging.

## Patterns to scan for FIRST

- **Falsy-zero / falsy-empty guards.** `if (!id)` / `if (!title)` wrongly fire on the valid
  value `0` or on a string that sanitizes to `""`. Use explicit `=== undefined || === null`,
  and validate the *sanitized* value, not the raw one. (H8, M14)
- **Off-by-N "caps".** `if (len > N) arr.slice(1)` only ever drops ONE element and pins the
  array at N+1 forever. Use `arr.slice(-(N-1))` before pushing. (M7)
- **In-place array mutation on a parsed/shared array.** `records.reverse()` mutates; copy
  first (`[...records].reverse()`) — becomes a real bug the moment the parse is cached. (M15)
- **Advertised-but-unimplemented surface.** A prompt/doc/interface lists capabilities the
  executor/provider doesn't implement (dead `pressKey`, advertised `swipe`). Keep the prompt,
  the type union, and the executor in lockstep. (C8, C9)
- **Device/host shell re-tokenization.** `adb shell input text "$x"` is re-parsed by the
  DEVICE shell — single-argv is NOT enough; escape metacharacters + encode spaces. (H1, M9)
- **Resume/Range trust.** A `Range:` request can be answered `200` (server ignores it) — reset
  byte counters; verify a `206`'s `Content-Range` start before appending. (H9)
- **Untrusted XML/entities.** Device/network-sourced XML needs `processEntities:false`. (H34)
- **Bind address + "localhost" logs.** `server.listen(port)` binds all interfaces; the log
  saying `localhost` lies. Bind `127.0.0.1` explicitly. (C1)
- **Docs describing a different product.** Security/feature docs that claim ports, rate limits,
  config files, or providers that don't exist are worse than none — verify against source. (H5)
- **`vitest run` with no `include`** walks vendored/symlinked trees (e.g. a llama.cpp checkout
  under `jni/`). Scope `include` to `tests/`.
- **Test ≠ shipped code.** Tests that re-implement the function under test, or assert
  `>= 0` / `toBeDefined()`, verify nothing. Import the real export; assert the real value.
- **Unverified download → parser.** Bytes streamed from the network to a native parser MUST be
  checked first (magic header always; pinned SHA-256 when known). Verify in the REAL downloader,
  not the orchestrator — the mock writes a placeholder and would fail an orchestrator-level gate.
  Delete a failed file; never resume onto a poisoned partial. (C3)
- **Regex that stops at a delimiter the data also contains.** `ModelEntry\([^)]*\)` truncated at
  the `)` inside a label ("Qwen3 14B (Best Quality)"). Anchor on stable boundaries (`id…urlString`,
  line-end `$`), never on a delimiter that appears inside a field.
- **Hand-synced catalog = one field in 5 places.** A new model field lives in TS + Swift + Kotlin
  source, the generated `shared/model-catalog.json`, AND the generator + parity checker. Use
  `scripts/refresh_model_hashes.py` + `npm run gen:catalog`; `check_catalog_parity.py` guards drift.
- **Pinned mirror URLs rot.** A catalog HF URL can 404 (lmstudio-community ships no Q2_K). Verify
  download URLs actually resolve; prefer a mirror that hosts the exact quant.
- **Cached/pre-existing files are still untrusted.** An "already downloaded, skip" fast-path that
  returns without re-verifying re-opens the integrity hole on every launch. Verify the cached
  artifact too; delete + re-fetch on failure. (C3-1)
- **Wrong lookup key silently downgrades a security check.** Resolving a security value (sha256) by
  the wrong identifier (filename vs catalog id) returns nil → silent fallback to the weaker check,
  no error. Resolve by the SAME key the catalog uses; add a regression test. (C3-2)
- **PEP 604 `X | None` is eager in a runtime assignment.** Fine in annotations under
  `from __future__ import annotations`, but `Alias = dict[..., X | None]` evaluates `|` now and dies
  on Python <3.10. Use `Optional[X]`.
- **WorkManager foreground service needs an explicit manifest `<service>`.** WorkManager does NOT
  merge `android:foregroundServiceType` into the merged manifest, so a runtime `setForeground(…DATA_SYNC)`
  throws `MissingForegroundServiceTypeException` on API 34+. Declare `<service
  android:name="androidx.work.impl.foreground.SystemForegroundService" android:foregroundServiceType=…
  tools:node="merge"/>` even though you never author the service class yourself.

## Chronological log (newest first, 5 lines max)

- 2026-06-16 — Generative-AI content policy (App Store 1.2 / Play): integrated `SupportContact`
  (disclaimer + report-mailto) on both platforms. iOS views + test were wired; Android twin
  (`SupportContact.kt`) existed but was untested by CI and unwired in the UI. Added 6 checks to
  `CoreVerify.kt` (the kotlinc CI gate) + wired `ChatScreen`/`AgentScreen` (long-press report,
  disclaimer). Lesson: a "twin" file isn't done until its CI harness AND its UI consumer reference
  it — grep the verify harness + the screens, not just the source file. (iOS 134 / core green)
- 2026-06-16 — Store-compliance audit (workflow): native apps are clean (offline, no automation,
  minimal perms) but had 4 submission blockers. Fixed code-side: iOS `PrivacyInfo.xcprivacy`
  (E174.1 + 3B52.1), Android WorkManager `<service> foregroundServiceType=dataSync` (a latent
  `MissingForegroundServiceTypeException` crash on API 34+ mid-download), encryption-exempt key,
  `models/` backup-exclusion. Report: `docs/audits/2026-06-16-store-compliance-audit.md`.
- 2026-06-16 — Adversarial review of the C3 fix found 2 CRITICAL self-introduced bypasses: the
  desktop "already downloaded" early-return skipped verification (`llm.service.ts:667`), and the iOS
  background downloader looked up sha256 by FILENAME not catalog id (`BackgroundModelDownloader.swift:41`)
  → silently magic-only. +6 lower (sha256 OOM trap, finalize cleanup, optional-sha256 export/parity,
  fd leak). All fixed (desktop 57 / iOS 131 / Android green). Report:
  `docs/audits/2026-06-16-c3-ship-readiness-review.md`. Lesson: adversarially review your own security fix.
- 2026-06-16 — C3: model downloads had no integrity check — multi-GB GGUFs streamed to disk and
  handed to llama.cpp's parser unverified (MITM / poisoned-mirror / truncation → RCE surface).
  Fix: real HF-LFS `sha256` pinned per catalog entry + a `ModelIntegrity` verifier (GGUF magic +
  full-file SHA-256) wired into desktop `llm.service.ts`, iOS `URLSession`/`BackgroundModelDownloader`,
  Android `ModelDownloadEngine`; bad file deleted, not resumed. Lesson: verify in the real downloader.
- 2026-06-16 — Catalog `llama32-1b-q2` URL 404'd (`lmstudio-community` has no Q2_K for 1B). Fix:
  repointed to `unsloth` via `scripts/refresh_model_hashes.py`. Lesson: pinned mirror URLs rot —
  verify they resolve (the new sha256 fetch surfaced it).

- 2026-06-15 — Desktop audit batch (C1,C8,C9,H1,H8,H9,H10,H19,H34,M2,M3,M6,M7,M9,M14,M15).
  Symptom: 47-finding consolidated audit. Cause: see patterns above. Fix: PR #7 commits
  06bad21→b62a0da. Lesson: the patterns above. Backlog: `docs/audits/2026-06-14-CONSOLIDATED-open-findings.md`.
- 2026-06-15 — Android app wouldn't build. `MainTabs.kt:50` used `UnitConverterTool`/`DateCalcTool`
  without importing them; no `gradle.properties` (`useAndroidX`); no Gradle wrapper. Fix:
  a5f39bc. Lesson: the headless `kotlinc` core check never compiles `:app` — only a real
  `./gradlew :app:assembleDebug` catches app-module breakage.
- 2026-06-14 — Stale `constants.test.ts` asserted `llama3-8b` at 6GB; logic returns `qwen3-4b`.
  Fix: 46b3165. Lesson: a duplicate test that drifts from the authoritative one is test-rot;
  fix it against the authoritative spec, don't rewrite to match code blindly.
