# r43 — Performance third pass (2026-07-11)

- **Startup JS re-measured on vite 8:** preloads = jsx-runtime 9k + index.dom 18k + lib 136k +
  index 271k ≈ **434 kB** (was ~1.05 MB before Wave D) — the 597 kB grammar bundle loads only at
  the first rendered code block.
- **No hot-path regressions introduced:** atomicWrite adds one rename per persist (μs); WS
  error listener is passive; nosniff/maxPayload are header/limit checks.
- **Corrected 2026-07-11:** the KV context-shift is ALREADY MERGED (`0350f55`) — the "open"
  status was doc drift from the 2026-07-01 report. Residual: S23 throughput A/B (measurement).
