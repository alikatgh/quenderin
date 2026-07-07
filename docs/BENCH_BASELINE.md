# Engine bench baseline

Run `npx tsx scripts/smoke_llm_engine.ts --bench 12` and compare against the latest entry
below **before and after any engine change** (llm.service, grammar schemas, prompt layout,
node-llama-cpp upgrades). Append a new entry when the numbers move materially and the change
is intentional; investigate when they move and it isn't.

The bench decodes N grammar-constrained agent steps through one cached mission sequence
(prompts share a stable head, volatile tail — the real agent's shape), then runs the last
prompt on a fresh sequence as the full-re-prefill control.

| Date | Machine | Model | step1 (load) | cached p50 | cached p95 | fresh control | speedup |
|------|---------|-------|-------------:|-----------:|-----------:|--------------:|--------:|
| 2026-07-07 | M-series 10-core, 16 GB, Metal | Llama 3.2 1B Q2_K | 1441ms | 529ms | 600ms | 672ms | ×1.27 |

Notes 2026-07-07: first baseline, taken right after the engine overhaul (grammar decode +
KV cacheKey reuse + input-lookup prediction). The single-screen smoke steps (smaller prompts)
run ~350–400ms cached vs ~790ms with model warm on a fresh sequence — the speedup grows with
the size of the stable prompt head (goal, attachments, hints), which the bench's synthetic
prompt keeps deliberately small.
