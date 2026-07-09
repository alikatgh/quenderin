# Engine bench baseline

Run `npx tsx scripts/smoke_llm_engine.ts --bench 12` and compare against the latest entry
below **before and after any engine change** (llm.service, grammar schemas, prompt layout,
node-llama-cpp upgrades). Append a new entry when the numbers move materially and the change
is intentional; investigate when they move and it isn't.

The bench decodes N grammar-constrained agent steps through one cached mission sequence
(prompts share a stable head, volatile tail — the real agent's shape), then runs the last
prompt on a fresh sequence as the full-re-prefill control.

| Date | Machine | Model | Engine | step1 (load) | cached p50 | cached p95 | fresh control | speedup |
|------|---------|-------|--------|-------------:|-----------:|-----------:|--------------:|--------:|
| 2026-07-07 | M-series 10-core, 16 GB, Metal | Llama 3.2 1B Q2_K | metal, FA=on | 1441ms | 529ms | 600ms | 672ms | ×1.27 |

The **Engine** column records the *actual* decode config the bench reads back from the context
(`gpu=`, `flashAttention=`) — not what was requested. node-llama-cpp silently disables flash
attention for models that can't support it (Grok, Gemma2, unsupported head dims), so a run
labelled `FA=off` is a genuinely different regime; don't compare its numbers against an `FA=on`
row. If a model you expect to support flash attention reports `FA=off`, that's the signal to
investigate the model/build, not the prompt path.

Notes 2026-07-07: first baseline, taken right after the engine overhaul (grammar decode +
KV cacheKey reuse + input-lookup prediction). The single-screen smoke steps (smaller prompts)
run ~350–400ms cached vs ~790ms with model warm on a fresh sequence — the speedup grows with
the size of the stable prompt head (goal, attachments, hints), which the bench's synthetic
prompt keeps deliberately small.

## Android / mobile inference stack (engineering status 2026-07-09)

The Tier-1 OSS-audit deltas are **in the build**, awaiting physical-device re-measure:

| Lever | State |
|-------|--------|
| Per-CPU-feature arm64 backends (`GGML_CPU_ALL_VARIANTS` + runtime pick) | ✅ CMake + `ggml_backend_load_all_from_path` |
| Explicit `n_batch`/`n_ubatch` (512, ≤ n_ctx) | ✅ `llama_jni.cpp` nativeLoad |
| `-O3` RelWithDebInfo kernels | ✅ CMake `CMAKE_*_FLAGS_RELWITHDEBINFO` |
| Flash Attention AUTO | ✅ both platforms |
| In-decode thermal re-tune (every 32 tokens) | ✅ `llama_generate.h` thermalPoll |
| Chat-path repetition penalty 1.1/256 | ✅ 2026-07-09 (was agent-only) |
| UTF-8 stream reassembly in JNI emit | ✅ 2026-07-09 |
| CPU affinity mask (`strict_cpu` / top-N by max_freq) | ✅ 2026-07-09 — `pin_threads` builds a `ggml_threadpool` with `strict_cpu` + sysfs-ranked `cpumask`, attached via `llama_attach_threadpool`; Kotlin `ThreadPlanner.bestCoreIndices` is the pure twin |
| Vulkan default-on for Adreno | ✅ 2026-07-09 — CMake/Gradle default ON; `GpuOffloadPlanner` still CPU-only for Mali/Xclipse/unknown; opt-out `-Pquenderin.vulkan=false` |
| Sampling recipes (chat / agent decision / deliberation) | ✅ 2026-07-09 — canonical `shared/sampling-profiles.json`; CI `npm run check:sampling-parity` greps Swift/Kotlin/JNI; chat top_k=40, agent_decision max_tokens=192 |

**Next measure:** run `android/verify-llama-link.sh` + on-device prefill/decode logcat on S23 (or
equivalent) and append a row here with prefill tok/s vs decode tok/s. Prefill ≈ decode was the
smoking gun the variant builds target.
