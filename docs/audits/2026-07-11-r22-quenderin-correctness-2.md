# r22 — Quenderin correctness re-pass (2026-07-11)

**Lens:** Second correctness pass over the June consolidated criticals/highs. **One item
STILL-PRESENT-BY-DESIGN (documented), the rest fixed.**

| June finding | Status on main |
|---|---|
| C5 daemon/interactive contention; dead throttle | ✅ Fixed by redesign — the background daemon no longer takes an LLM provider at all (BUG_JOURNAL 2026-07-07); `maxConcurrentHeavyOps` survives only as /health telemetry |
| C8/C9 advertised-but-unimplemented actions (swipe/pressKey) | ✅ Fixed — prompt/type-union/executor in lockstep (journal pattern) |
| C10 two owners of one store, mutex bypass | ✅ Fixed — all memory mutators behind `withWriteLock` (×7), notes single-owner |
| C12 model picker can't pin | ✅ Fixed — `switchModel` pins `activeModelId`; startup honors the pin when the file exists; UI Use/Active (r9-H1 work this session) |
| C13 duplicate Electron entry | ✅ Fixed — single `src/electron/main.ts` |
| H6 calculator trailing tokens | ✅ Fixed — `atEnd()` rejects unconsumed input |
| H7 fixed device dump paths race | ✅ Fixed — unique temp names + cleanup |
| H8 falsy id 0 | ✅ Fixed (journal falsy-zero pattern; explicit null checks) |
| H9 Range→200 resume corruption | ✅ Fixed — 200 resets counters, 206 verifies Content-Range |
| H10 stale voice buffer | ✅ Fixed — availability guards + user-facing "Microphone Unavailable" |
| H20 `setMaxListeners(30)` | ⚠️ STILL-PRESENT, justification changed — per-connection `off()` cleanup now exists (close handler detaches all 6 emitters), the raised cap is retained headroom, not a leak cover. Accepted. |
| H21 dead `runToolLoop` + duplication | ✅ Fixed — symbol gone from src |
| H23/H24 orphaned config/generateId | ✅ Fixed — files deleted |

Also this session: `firstJsonObject` deduplicated (the H21-family duplication instinct), and the
three real TS parity divergences fixed (see r7-wave commit).
