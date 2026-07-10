# r18 — Quenderin observability audit (2026-07-11)

**Lens:** Logging, metrics, crash signals, debug gates (50-round plan r18)
**Verdict: clean — no fixes required.**

## Verified

1. **Leveled logger with env gate** (`src/utils/logger.ts`): `QUENDERIN_LOG_LEVEL` override;
   default `info` in dev, `warn` in production; `setLogLevel('error')` in CLI pipe mode so engine
   noise can't pollute piped stdout.
2. **Crash signals are captured:** `unhandledRejection` logged; `uncaughtException` logged
   critical then exit(1); per-socket WS errors logged since r14 (E1).
3. **Secrets are redacted at the logging boundary:** `?token=` stripped from logged URLs
   (errorHandler, Q-355); goals redacted via `redactSecrets` before logging (Q-644/Q-357);
   diagnostics payload is user-triggered and id-stamped.
4. **Product metrics exist and are exposed:** per-run telemetry (tok/s, TTFT, steps, retries)
   with the Metrics UI; background-daemon habit telemetry has a token-gated route (Q-599).
5. **Diagnostics affordance:** `/diagnostics` (token-gated) + the Settings "Copy diagnostics"
   flow with download fallback — the support path doesn't depend on a working clipboard.

## Open (logged, low)
- No persisted crash-report file on `uncaughtException` (the critical log line is the only
  artifact; Electron relaunch loses the terminal). Candidate: append last-gasp line to
  `~/.quenderin/crash.log` in the exit handler. Deferred to r39 (ops-scripts).
