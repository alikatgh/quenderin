# r47 — Research second pass (2026-07-11)

- **Dependency currency:** vite 8 (today), Express 5, Electron 40, node-llama-cpp ^3.2 — current
  across the board; Dependabot + CI audit keep it visible. 0 vulnerabilities at both roots.
- **Standing research thread:** KV context-shift (r8 R2) remains THE open engine question —
  `llama_memory_seq_rm`-based shift with greedy-decode parity validation, plan already written
  (`2026-07-01-kv-cache-reuse-cliff.md`). Mobile thermal/decode ceiling question is with
  Gerganov (awaiting reply, 2026-06-30 email).
- **Convention posture:** Express 5 async error semantics relied on correctly; ws maxPayload now
  explicit rather than default-trusted; rolldown (vite 8) manualChunks lesson recorded in
  vite.config comment + r23 report so the eager-bundle trap can't silently return.
