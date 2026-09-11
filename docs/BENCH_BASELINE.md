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

## Inference SLO rows (`scripts/bench_inference.sh`) — 2026-09-05

Vendored pin `android/jni/llama.cpp` @ 0eca4d4 built with the app's flags. Mac M3 Pro (5P+6E, 18 GB), Metal,
all layers, 5 threads, **load average ≈ 20 during the run** (another workload) — treat as lower bounds.
First-token = `llama-smoketest --ttft` in a fresh process; "cold" = cold page cache (first run after download),
"warm" = after the load-time warmup decode. Targets: `docs/INFERENCE_SLO.md`.

| Model | pp512 | tg128 | tg512 | first token, cold page cache | first token, warmed | sky-blue 48-tok decode |
|-------|------:|------:|------:|-----------------------------:|--------------------:|-----------------------:|
| Llama 3.2 1B Q4_K_M | 1530 tok/s | 78.8 | 79.7 | 47–54 ms (page cache already warm) | 26–29 ms | 76–82 tok/s |
| Gemma 3 4B Q4_K_M | 518 tok/s | 27.5 | — | **3694 ms** (first run after download); 153 ms once cached | 114–142 ms | — |

S23 (SM8550, i8mm) rows still pending: binaries are built by `scripts/bench_inference.sh android`; the phone was
unplugged and at 49 °C when this pass ran (the script refuses to measure above 38 °C).

## Paged-MoE (35B-A3B) on a memory-tight Mac — 2026-09-11

The catalog's one MoE (`qwen36-35b-a3b`, UD-IQ3_XXS, 12.3 GiB) on the same M3 Pro (18 GB), vendored pin
@ 0eca4d4, `llama-bench -t 5 -p 512 -n 128,512 -r 3`. Disk was **97 % full (≈2–10 GB free)** — no swap
headroom — which matters (see the panic note).

| Config | pp512 | tg128 | tg512 |
|--------|------:|------:|------:|
| `-ngl 0` (today's `GpuOffloadPolicy` paged-MoE path: full CPU-only) | 13.1 tok/s | 3.0 tok/s | 2.2 tok/s |
| `-ngl 999 -ncmoe 40` (spine on Metal, experts on CPU — edge0's portable half) | ❌ `failed to decode prompt batch, res = -3` | — | — |

**Two findings, both uncomfortable and both recorded rather than rounded:**

1. **The Metal + CPU-experts offload does not run here.** `-ncmoe` + `-ngl 999` failed the prompt decode
   (`res = -3`) on the 12.3 GiB model with ~2–10 GB free. The engine change that would use it
   (`GpuOffloadPolicy.plan` / `LlamaEngine`) is therefore **default-OFF** (`QUENDERIN_MOE_EXPERT_CPU=1`
   opts in) until a config exists that both loads and wins.
2. **CPU-only decode is ~3 tok/s, not the 17.3 tok/s** the `MoEShape.swift` comment cites for "a 13 GB
   35B-A3B on a 16 GB M4". That number does not reproduce on an 18 GB M3 Pro with a nearly-full disk.
   The original measurement's conditions (free disk / warm page cache / machine) are not recorded —
   treat **17.3 as unverified** and re-measure on a machine with real free space before trusting any
   paged-MoE speed claim.

### ⚠️ Watchdog panic — never run an over-RAM model on a full disk

The `-ngl 999` run **panicked the kernel** (`panic-full-2026-09-11-144540.0002.panic`):
`"watchdog timeout: no checkins from watchdogd in 93 seconds"`. That is a system-freeze watchdog, not a
GPU fault: a 12.3 GiB model on 18 GB with the disk 97 % full has no swap headroom, so the machine
thrashed until the watchdog fired and force-restarted. **Free disk (≥ model size) before benchmarking a
model that doesn't fit comfortable RAM headroom**, and prefer configs that keep the working set under RAM.

