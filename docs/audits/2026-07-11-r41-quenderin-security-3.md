# r41 — Security third pass (2026-07-11)

**Scope:** adversarial self-review of everything changed since r21 (i.e. this session's waves).

## Finding (caught + fixed this pass)
- **S1 (Medium): the r19 Docker run example published the port on ALL host interfaces.**
  `-p 3000:3000` binds the host side to 0.0.0.0 — after the container-bind fix, that example
  quietly LAN-exposed the dashboard (token-gated, but exposure is exposure). Docs now say
  `-p 127.0.0.1:3000:3000` with the trade-off spelled out.

## Re-verified safe
- `QUENDERIN_HOST=0.0.0.0` stays container-scoped (host binary default untouched: loopback).
- `maxPayload`/`nosniff`/per-socket error handler: no behavior widened, only tightened.
- vite 8 upgrade: lockfile-pinned, dev-only surface, 0 vulnerabilities after.
- crash.log write: try/wrapped, homedir-scoped, no user input in the path.
