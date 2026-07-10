# r33 — WebSocket/realtime audit (2026-07-11)

**Verdict: clean** (largely hardened by prior rounds; re-verified as one surface):
- **Auth**: token on upgrade + origin gate + `path: '/ws'` (r15/r21).
- **Frames**: `maxPayload` 16 MiB; per-field slices; send-buffer backpressure (r20).
- **Liveness**: server heartbeat (`isAlive`/pong) reaps dead sockets; per-socket `'error'`
  listener (r14 — the one-flaky-tab-kills-server fix).
- **Reconnect (client)**: bounded exponential backoff with jitter, attempts surfaced in the log,
  settings re-pushed on reconnect so the server never sits on defaults, `intentionallyClosed`
  guard, unique log ids on repeat failure cycles.
- **State adoption**: connect ADOPTS the active session (Q-596) — a second tab/refresh can't
  clobber an in-progress session; approval flows fail closed on disconnect.
- **Stale handlers**: every emitter listener attached per-connection is detached in `'close'`.
