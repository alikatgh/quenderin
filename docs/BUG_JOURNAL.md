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

## Chronological log (newest first, 5 lines max)

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
