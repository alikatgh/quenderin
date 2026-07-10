# r17 — Quenderin concurrency audit (2026-07-11)

**Lens:** Locks, TOCTOU, races, schedulers (50-round plan r17)
**Verdict: clean — no fixes required.** Prior journal-driven work already installed the guards
this lens hunts for; this round verified each one against current main.

## Verified

1. **Telemetry append** serializes through `writeChain` promise chaining (`metrics.service.ts:52`)
   — no read-modify-write interleave.
2. **Agent memory** serializes ALL mutators through `withWriteLock` (7 call sites:
   saveTrajectory, injectOverride, clearTrajectories, corrections…).
3. **Model download** dedupes via `isDownloading` (llm.service:956) — a second kickoff while one
   is running is refused rather than double-streamed into the same file.
4. **Agent loop re-entry** is guarded (`_isRunning` + the H7 finally that can't deadlock future
   runs); `switchModel` during active generation THROWS (`INFERENCE_BUSY`, Q-283) instead of
   ripping the model out from under a decode.
5. **Lazy-init memoizes the PROMISE, not a flag** (desktop provider — the double-init race is a
   journaled pattern and its fix is still in place).
6. **Session store** mutates via synchronous fs in a single-threaded process — no interleave
   window; the periodic flush and addMessage both go through the (now atomic) sync writer.
7. **WS approval flows fail closed on disconnect** — an approval pending when the approving
   socket closes is answered NO (no hung run, no nobody-approved-it).

## Notes
- The `isDownloading` guard is one-flag-global: two DIFFERENT models can't download
  concurrently. That's a deliberate bandwidth/IO choice, not a race — noted, not a finding.
