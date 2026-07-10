# r14 — Quenderin error-handling audit (2026-07-11)

**Lens:** Silent catch, swallowed rejections, user-visible failures (50-round plan r14)
**Mode:** Inline audit + same-session fixes (Claude). Server side (`src/`); the UI's
error-surfacing gaps were covered in r10.

## State of play (verified good)
- Zero empty `catch {}` blocks in `src/`; every `.catch(() => {})` is best-effort temp-file /
  adb cleanup with a comment saying so.
- Process-level `unhandledRejection` (log) + `uncaughtException` (log + exit) handlers exist.
- Express 5 forwards async route rejections to the error middleware (`middlewares/errorHandler.ts`,
  which also strips `?token=` from logged URLs).
- Streams/spawns carry `'error'` handlers (journal-driven fixes: adb spawn, download/extract streams).
- The WS message handler is fully wrapped in try/catch.

## Findings

### E1 — No per-socket `ws.on('error')` → one flaky client kills the server — **FIXED** (High)
- **File:** `src/websocket/index.ts` (connection handler)
- **Symptom:** `wss.on('error')` existed but individual sockets had no `'error'` listener. An
  abrupt client drop (ECONNRESET mid-write) or malformed frame emits `'error'` on the socket;
  unlistened, EventEmitter rethrows → `uncaughtException` → **`process.exit(1)`**
  (`src/server.ts:48-51`). A browser tab dying at the wrong moment could take down the whole
  local agent server.
- **Fix:** `ws.on('error', …)` logs a warning; the subsequent `'close'` does the real cleanup.

### E2 — Catch-all mislabeled every handler failure as a parse error — **FIXED** (Low)
- **File:** `src/websocket/index.ts:569`
- **Symptom:** The message handler's outer catch logged "Failed to parse ws message" for ANY
  throw inside the 340-line handler — misleading first clue during an incident.
- **Fix:** Message now says what it guards: "WS message handling failed".

## Open
- `uncaughtException` → exit(1) with no supervisor/restart: acceptable for a user-launched local
  app (Electron relaunches the backend; CLI users rerun), noted for the ops lens (r39).
