# r23 — Quenderin performance re-pass (2026-07-11)

**Lens:** Second performance pass; regression check vs June findings.

## Findings

### P1 — C7 re-pass: the Prism bundle was split but still EAGER — **FIXED** (High for first paint)
- **Files:** `ui/src/components/CodeBlock.tsx`, `ui/vite.config.ts`
- **Symptom:** The June fix gave react-syntax-highlighter its own chunk — but the `manualChunks`
  pin merged the async grammar payload into a chunk the entry statically needs, so **619 kB
  (220 kB gzip) sat on the startup `modulepreload` path** anyway.
- **Fix:** `PrismAsync` + deep style import + drop the `'syntax'` manualChunks pin. Measured
  result: grammar bundle (598 kB) is now a lazy chunk fetched when the first code block renders;
  startup preloads are icons (32k) + markdown (158k) + react-vendor (134k) + index (129k) —
  **~600 kB less JS before first paint**.

| June finding | Status |
|---|---|
| C4 RAG embed + 500-vector scan per step | ✅ Fixed — corrections cached per-UI-state (`promptBuilder.relevantCorrectionsCached`, tested) |
| C6 blocking `execSync` on hot paths | ✅ Fixed — 1 s TTL memo (Q-505), probe ≤1/s |
| C7 1.1 MB eager chunk | ✅ Fixed properly this round (above) |
| KV strict-prefix reuse cliff (r8 R2) | ⏳ OPEN — engine-level context-shift project, tracked in `2026-07-01-kv-cache-reuse-cliff.md`; not a patch |

No new hot-path regressions found in the post-June code (paged-MoE and skill-memory paths carry
their own caching; sampling profiles parity-pinned).
