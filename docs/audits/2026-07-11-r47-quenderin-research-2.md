# r47 — Research second pass (2026-07-11)

- **Dependency currency:** vite 8 (today), Express 5, Electron 40, node-llama-cpp ^3.2 — current
  across the board; Dependabot + CI audit keep it visible. 0 vulnerabilities at both roots.
- **Corrected 2026-07-11:** the KV context-shift is ALREADY MERGED on main (`0350f55`) — the
  2026-07-01 report's "not merged" status was stale (cross-machine). Residual: the S23
  throughput A/B as a post-merge measurement. Mobile thermal/decode ceiling question is with
  Gerganov (awaiting reply, 2026-06-30 email).
- **Convention posture:** Express 5 async error semantics relied on correctly; ws maxPayload now
  explicit rather than default-trusted; rolldown (vite 8) manualChunks lesson recorded in
  vite.config comment + r23 report so the eager-bundle trap can't silently return.
