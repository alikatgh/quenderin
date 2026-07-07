# Platform audit — macOS, iOS, Android, Windows/Linux (2026-07-07)

**Scope:** cross-platform read of the local-inference engine, chat/agent driver, and
device-perception layer on all five targets, focused on the code that changed since the
last twin-drift audit (2026-07-06) plus this session's desktop engine overhaul.
**Method:** inline read + twin-diff (iOS ⇄ Android), plus the real verification gates.
**Not re-audited:** backend `src/` and React `ui/src` (full adversarial deep-hunts on
2026-06-27, then the engine reworked + re-tested this session); native JNI/Metal *runtime*
semantics (needs on-device token dumps — disk-blocked here, owner's gate).

## Verification gates run (all green)

| Target | Gate | Result |
|--------|------|--------|
| macOS + iOS logic | `swift test` (QuenderinKit) | **321 tests, 0 failures** (5 skipped) |
| Android core | `kotlinc` + `CoreVerify` | **139 checks, ALL PASSED** |
| Backend + Electron | `npm test` | **515 tests pass** |
| Agent parity | `check_agent_parity.py` | **19 vectors, iOS+Android in sync** |
| Desktop engine (live) | `smoke_llm_engine.ts` ×3 | **grammar/KV/functions all green** |

## Findings

### F1 — Android `device.status` renders numbers in the default locale (LOW, **fixed**)
`android/app/.../DevicePerception.kt:59` used `"%.1f".format(free/1e9)`, which formats in
`Locale.getDefault()` → "1,5 GB" in de/fr, Eastern-Arabic digits in ar. The iOS twin
(`DeviceCapabilities.swift:183`) uses `String(format:)`, which renders in the POSIX/C locale
("1.5"). Because `device.status` output is **model-facing** (an agent tool result), the two
platforms fed the model different number strings for the same capability — the exact
cross-platform number drift the 2026-07-07 seam-normalization series (618ce3c/d006093/e64e1ae)
had just eliminated in `quenderin-core`, reintroduced in the freshly-landed T1 code.
**Fix applied:** `String.format(Locale.ROOT, "%.1f", …)` to match the iOS twin.
**Not a bug, left as-is:** the UI-only `%.1f` sites (`ModelPickerSheet.kt:269`,
`OnboardingScreen.kt:454`) — those are human-facing and locale-correct on each device; only
the model-facing string needed pinning.

### F2 — Electron loads `localhost` while the server binds IPv4 `127.0.0.1` (INFORMATIONAL)
`src/electron/main.ts:48` does `loadURL('http://localhost:${PORT}')`; the backend binds
`127.0.0.1` only (`server.ts:42`). On dual-stack hosts `localhost` can resolve to `::1` first,
so the very first paint depends on Chromium's localhost IPv4 fallback. Chromium does retry
IPv4 for `localhost` specifically, so this works in practice — but binding and loading the
**same literal** (either both `127.0.0.1` or add a `::1` listener) removes a latent
first-load stall on unusual resolver configs. No change made; flagging only.

## What was checked and found SOUND (no action)

- **iOS `LlamaEngine`** — the native lifecycle is careful: `nativeLock` serializes
  load/unload/generate so a switch can't free the context mid-decode; the decode runs OFF
  the cooperative pool (M2); `cancelState` interrupts prefill AND the token loop (Q-005/Q-217);
  `token_to_piece` grows its buffer on the negative-length signal (H1); tokenizer guards the
  >2 GB Int32 overflow (M2). The KV reuse plan (append / shift / prefix / full) with
  `seq_rm`+`seq_add` and a full-reprefill fail-safe matches `KVCacheReuse` and the Android twin.
- **iOS ⇄ Android `ChatModel`** — the two concurrency models are correctly *different*:
  iOS relies on `@MainActor`+id-relookup (safe because every await is a cooperative yield);
  Android adds a monotonic `activeGeneration` id + `synchronized(lock)` + `requestCancel()`
  because `send` runs on a real background thread. Both drop superseded-generation writes, so
  conversation-switch bleed (Q-004/Q-168) and empty-bubble (Q-588) are closed on both.
- **Android JNI** (`llama_jni.cpp`) — UTF-8 jstrings built via the byte[]+Charset path (not
  `NewStringUTF`, which mangles 4-byte emoji/CJK — M2); `llama_backend_init` under
  `std::call_once` (H6); `GetStringUTFChars` OOM-checked (H4); pending-JNI-exception guard
  before the next call in the token loop. Cancel field polled lock-free each token (M3),
  matching the Kotlin `@Volatile cancelRequested`.
- **T1 device perception** (both platforms) — read-only by declaration, consent-gated through
  the same spine, size-capped (4000-char clipboard), OS-permission-prompted (EventKit on Apple).
  Nothing writes; T2+ automation stays desktop-only. Names shared across platforms
  (`device.clipboard.read`, `device.status`) so the model's learning transfers.
- **Electron shell** — `sandbox:true`, `contextIsolation:true`, `nodeIntegration:false`;
  `setWindowOpenHandler → deny` + `will-navigate` pinned to the local origin; per-launch token
  delivered via `additionalArguments` (unreadable cross-process); fatal-boot path exits cleanly;
  tray icon path corrected for the asar layout (Q-534). Platform-aware menus for Win/Linux/mac.
- **Android attachment copy** (`AgentWiring.kt`) — copy-at-pick-time (SAF perm needn't outlive
  the pick), size-capped, name-collision suffixing mirrors the iOS `AttachedFilesStore`.

## Conclusion
The mobile and desktop-shell surfaces are in strong shape — the prior deep-hunts left dense,
cited defenses and the twins are genuinely kept in lockstep. One real (low-severity) parity
regression in this-week's new T1 code was found and fixed; one informational networking nit
noted. No high- or medium-severity defects surfaced in the audited surface. Native runtime
semantics (Metal/JNI decode correctness) remain the owner's on-device gate, as before.
