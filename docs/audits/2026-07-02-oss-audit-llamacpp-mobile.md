# OSS audit: on-device llama.cpp inference tuning (PocketPal / llama.rn / LLMFarm)

Date: 2026-07-02
Audited repos (shallow clones in scratchpad):
- **llama.rn** `github.com/mybigday/llama.rn` — native inference layer for PocketPal (React Native). This is where the interesting config lives.
- **pocketpal-ai** `github.com/a-ghorbani/pocketpal-ai` — RN app on top of llama.rn.
- **LLMFarm** `github.com/guinmoon/LLMFarm` + submodule `llmfarm_core.swift` — SwiftUI iOS app, thin Swift wrapper over a prebuilt llama.cpp xcframework.

Comparison baseline = Quenderin digest (arm64-v8a generic build, no batch tuning, no flash-attn set, thermal thread governor, measured S23 decode ~3.8 tok/s **and prefill ~3.8 tok/s** — the anomaly this audit targets).

---

## 1. TL;DR — top 5 actionable deltas, ranked by expected speed impact

1. **Build per-CPU-feature arm64 variants (`+dotprod`, `+i8mm`) and pick at runtime — biggest prefill lever.**
   Quenderin ships ONE `arm64-v8a` generic `.so`. That means the GGML CPU matmul kernels compile WITHOUT the i8mm/dotprod repack path, so Q4_K_M matmuls fall back to scalar/NEON. **This is the single most likely cause of prefill being no faster than decode** — prefill is matmul-bound and is exactly what i8mm accelerates.
   Evidence: `llama.rn/android/src/main/CMakeLists.txt:147-156` builds 6 arm64 targets (`armv8-a`, `armv8.2-a`, `+dotprod`, `+i8mm`, `+dotprod+i8mm`, `+…+hexagon+opencl`); `android/src/main/rnllama/CMakeLists.txt:102-107,123` compiles the per-arch `ggml-cpu/arch/arm/{quants.c,repack.cpp}` with `-DLM_GGML_USE_CPU_REPACK` + the arch `-march` flag; runtime selection reads `/proc/cpuinfo` and `System.loadLibrary`s the best match at `android/src/main/java/com/rnllama/RNLlama.java:189-241`.

2. **Set `n_batch`/`n_ubatch` explicitly (they use 512) — the prefill-throughput knob.**
   Quenderin does "no n_batch/n_ubatch tuning" → llama.cpp defaults (`n_batch=2048`, `n_ubatch=512`) MAY be fine, but a too-small ubatch or an n_ctx smaller than n_batch silently caps the prefill chunk. Both audited apps pin these. If Quenderin's `n_ctx` (~3840) is being clamped or the prefill is being fed token-by-token, prefill collapses to decode speed.
   Evidence: `pocketpal-ai/src/utils/contextInitParamsVersions.ts:43-45` (`n_ctx 2048, n_batch 512, n_ubatch 512`); native passthrough `llama.rn/cpp/jsi/JSIParams.cpp:328-330`. **Verify Quenderin feeds the whole prompt in one `llama_decode` batch, not one token at a time** (see §3).

3. **Add the `+i8mm`/`+dotprod`-conditional compile flags AND `-flto -ffp-model=fast -fvectorize`.**
   Quenderin uses `RelWithDebInfo` (implies `-O2 -g`, not `-O3`, and NO LTO). llama.rn compiles the GGML/llama TU with `-O3 -DNDEBUG` (JNI) and `-flto -fvectorize -ffp-model=fast -fno-finite-math-only` (core lib). LTO + fast-math on the matmul kernels is a measurable win and is missed by `RelWithDebInfo`.
   Evidence: `llama.rn/android/src/main/CMakeLists.txt:135,141`; `android/src/main/rnllama/CMakeLists.txt:123`.

4. **Pin threads to the fastest cores via CPU-affinity mask (read `cpuinfo_max_freq`).**
   Quenderin picks a thread *count* (perf cores above LITTLE) but does not set a `cpumask`. llama.rn sorts all cores by `cpuinfo_max_freq` and sets `strict_cpu` affinity to the top-N — this stops the scheduler from parking decode threads on LITTLE cores mid-generation.
   Evidence: `llama.rn/cpp/jsi/JSIParams.cpp:25-62` (`set_best_cores`: reads `/sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_max_freq`, sorts desc, fills `params.cpumask`, sets `strict_cpu=true`, `mask_valid=true`).

5. **Evaluate GPU/NPU offload on Android (OpenCL/Adreno, Hexagon) — both apps default `n_gpu_layers=99`.**
   Quenderin's Vulkan backend is OFF by default. PocketPal defaults to **full GPU offload** (`n_gpu_layers: 99`) on both platforms and uses OpenCL on Adreno / Hexagon NPU where available; llama.rn even ships a dedicated `…_hexagon_opencl` variant. On Adreno this is often the largest decode win of all.
   Evidence: `pocketpal-ai/src/utils/contextInitParamsVersions.ts:49`; backend inference `pocketpal-ai/src/utils/flashAttnCompatibility.ts:17-66`; hexagon/opencl variant `llama.rn/android/src/main/CMakeLists.txt:156`.

**Also worth trying (secondary):** flash attention on iOS (`auto`), speculative/MTP draft decoding (llama.rn supports it), and quantized KV only when FA compatibility allows.

---

## 2. Per-repo findings

### 2a. llama.rn (PocketPal's native layer) — the reference implementation

**Context / model params.** llama.rn defers almost everything to llama.cpp's `common_params` and lets the JS caller override. Native passthrough in `cpp/jsi/JSIParams.cpp:309-400`:

| Param | Where set | Note |
|---|---|---|
| `n_ctx` | JSIParams.cpp:319 | caller-supplied (PocketPal: 2048) |
| `n_batch` / `n_ubatch` | JSIParams.cpp:328-330 | caller-supplied (PocketPal: 512/512) |
| `n_parallel` | rn-llama.cpp:242-244 | **defaults to 8** slots (parallel decode) |
| `n_threads` | JSIParams.cpp:331 → `set_best_cores` | affinity-masked, see below |
| `n_gpu_layers` | JSIParams.cpp:342 | caller-supplied (PocketPal: 99) |
| `flash_attn_type` | JSIParams.cpp:366-368 | `auto`/`on`/`off` string → enum; also legacy bool at :362-364 |
| `cache_type_k` / `cache_type_v` | JSIParams.cpp:371-374 | string → `lm_ggml_type` |
| KV cache types supported | rn-llama.cpp:53-78 | f32,f16,bf16,q8_0,q4_0,q4_1,iq4_nl,q5_0,q5_1 |
| speculative (MTP draft) | rn-llama.cpp:264-287 | draft model + own gpu_layers/cache types |
| context creation | rn-llama.cpp:249 | `common_init_from_params()` (standard path; uses `cpuparams_batch` for prefill threads) |

**Android build flags (the important part).**
- Six arm64 variants built (`CMakeLists.txt:147-156`): `armv8-a`, `armv8.2-a`, `armv8.2-a+dotprod`, `armv8.2-a+i8mm`, `armv8.2-a+dotprod+i8mm`, `armv8.2-a+dotprod+i8mm+hexagon+opencl`. (fp16-only variant intentionally dropped — broke some DeepSeek distills, PR #110.)
- Core lib TU flags (`rnllama/CMakeLists.txt:123`): `-DLM_GGML_USE_CPU -DLM_GGML_USE_CPU_REPACK -pthread <arch> -fvectorize -ffp-model=fast -fno-finite-math-only -flto -D_GNU_SOURCE`.
- JNI wrapper flags (`CMakeLists.txt:135-141`): `-O3 -DNDEBUG -fvisibility=hidden -ffunction-sections -fdata-sections`, link `-Wl,--gc-sections -flto`.
- Per-arch repack/quant kernels compiled in only for non-generic arch (`rnllama/CMakeLists.txt:102-107`) — this is the i8mm/dotprod fast matmul path.
- Runtime `.so` selection: `RNLlama.java:189-268` reads `/proc/cpuinfo` Features line, tests `dotprod|asimddp`, `i8mm`, `fp16|fphp`, plus Adreno/Hexagon hints, and loads the richest compatible library; falls back down the ladder to generic.

**Thread heuristic (`set_best_cores`, JSIParams.cpp:25-62).**
- Default thread count: `max_threads==4 ? 2 : min(4, max_threads)` (Hexagon build: 6). Apple: `common_cpu_get_num_math()/2` (JSIParams.cpp:65-68).
- **CPU affinity:** enumerate cores, read `cpuinfo_max_freq`, sort desc, set `cpumask` to the top `target_threads`, `strict_cpu=true`. This is what Quenderin lacks.

**Clever bits:** default 8 parallel slots + slot manager (`rn-slot-manager.cpp`); MTP speculative decoding; ships Hexagon NPU + OpenCL backends; runtime dead-code elimination (gc-sections/LTO) to keep 6 variants' binary size down. **No runtime thermal re-tuning** — Quenderin's 4-level governor is more advanced here.

### 2b. PocketPal (RN app)

**Production defaults** (`src/utils/contextInitParamsVersions.ts:32-53`):
```
n_ctx: 2048, n_batch: 512, n_ubatch: 512, n_threads: 4 (fallback),
cache_type_k/v: 'f16', n_gpu_layers: 99 (offload ALL layers),
use_mlock: false,
use_mmap: android 'smart' / ios 'true',
flash_attn_type: ios 'auto' / android 'off'
```
**Thread heuristic** (`src/utils/deviceCapabilities.ts:193-195`): `cores <= 4 ? cores : floor(cores * 0.8)` — 80% of cores on >4-core devices. (Simpler than Quenderin's perf-core-above-LITTLE logic; Quenderin's is arguably better, but pairs poorly without the affinity mask from §2a.)
**Device recommendation** (`deviceCapabilities.ts:203-215`): multimodal only if RAM ≥ 5.5 GB AND cores ≥ 6.
**Flash-attn compatibility gate** (`src/utils/flashAttnCompatibility.ts:17-66`): infers backend (metal/opencl/hexagon/cpu) from the `devices` array, then decides whether FA + quantized-KV combo is legal before enabling. Prevents the "FA on + quantized KV on a backend that doesn't support it" crash.
**Benchmark harness** (`src/__automation__/screens/BenchmarkRunnerScreen.tsx`): calls `ctx.bench()` and records **`pp_avg` (prefill/prompt tok/s) and `tg_avg` (decode tok/s) separately** — invariant-checked non-null (line 856-876). Bench defaults `n_ctx 2048, n_batch/ubatch 512` (`benchParams.ts:80-88`). This is a ready-made template for measuring Quenderin's prefill-vs-decode split.
**No speculative decode and no thermal handling in the production chat path** (grep found spec/thermal only in bench + unrelated TTS/HTML files).

### 2c. LLMFarm (iOS SwiftUI, `llmfarm_core.swift` wrapper)

Thin Swift wrapper over a prebuilt `llama_cpu.xcframework` (Metal comes from the core submodule's llama.cpp build). Context setup in `Sources/llmfarm_core/LLaMa.swift:71-180`:

| Param | Where | Value |
|---|---|---|
| `n_ctx` | LLaMa.swift:74 | from `contextParams.context` (default **2048**, AI.swift:437) |
| `n_threads` | LLaMa.swift:76 | `numberOfThreads==0 ? processorCount : n` (AI.swift:451) — **uses ALL cores** |
| `n_gpu_layers` | LLaMa.swift:112-129 | Metal → **100** (all); x86_64/simulator → 0 |
| `use_mmap`/`use_mlock` | LLaMa.swift:82-83 | caller (mmap disabled if LoRA present, :133) |
| `flash_attn` | LLaMa.swift:78-79 | **commented out → llama.cpp default** (parsed at AI.swift:348 but never applied to context) |
| `n_batch` (context) | — | **never set on `context_params`** → llama.cpp default |
| batch buffer | LLaMa.swift:179 | `llama_batch_init(512, 0, 1)` |
| sampling n_batch | AI.swift:480,497 | 512 |

**Prefill path (the relevant contrast):** `LLMBase.swift:355-372` chunks the prompt into `n_batch`(=512)-sized slices and `LLaMa.swift:259-262` feeds each whole chunk to **one `llama_decode` via `llama_batch_get_one(inputBatch, count)`** — i.e. proper batched prefill (many tokens per decode call), which is what makes prefill >> decode. **This is the exact thing to verify Quenderin does.**
Sampling defaults (AI.swift:497-513): temp 0.8, top_k 40, top_p 0.95, min_p 0.0, repeat_penalty 1.1, repeat_last_n 64.
No thermal/battery handling; no speculative decode.

---

## 3. Diagnosis: why is OUR prefill as slow as decode?

Prefill (prompt processing) is a batched matmul over N prompt tokens at once; decode is a per-token matmul of batch size 1. On the same hardware prefill should be 5–20× faster tok/s. If they're equal, prefill is being executed as if batch size were ~1. The three mechanisms that cause this, ranked by likelihood given the Quenderin digest:

1. **Missing i8mm/dotprod matmul kernels (most likely).** Quenderin's single generic `arm64-v8a` build compiles GGML CPU without `+i8mm`/`+dotprod`, so it never uses the wide-int8 repack matmul path that prefill leans on hardest. The two OSS apps build feature-specific variants *specifically* for this (`llama.rn CMakeLists.txt:147-156`, `-DLM_GGML_USE_CPU_REPACK`). i8mm accelerates the batched (prefill) GEMM far more than the batch-1 (decode) GEMV, so its absence flattens the prefill/decode ratio — exactly the symptom. **Fix: build `+dotprod+i8mm` variant, select at runtime.**

2. **Prompt fed token-by-token instead of one batched `llama_decode`.** If Quenderin's prefill loop calls `llama_decode` per token (or with a `llama_batch` of n_tokens=1), prefill degenerates to N decode steps. Verify the Quenderin prefill path builds a single `llama_batch` of all prompt tokens (cf. LLMFarm `LLaMa.swift:262` `llama_batch_get_one(inputBatch, count)` and llama.rn's `common_init_from_params` standard path). **Also confirm `n_ctx ≥ n_batch`** — if n_ctx is clamped below the prompt length or below n_batch, the prefill chunk shrinks.

3. **Build type `RelWithDebInfo` (-O2, no LTO).** Both OSS apps use `-O3 -DNDEBUG` + `-flto` + `-ffp-model=fast -fvectorize` on the kernel TUs. `-O2` without LTO/fast-math leaves matmul vectorization and cross-TU inlining on the table. Smaller than #1 but free to fix. **Note:** flash attention would help both paths but is NOT the prefill/decode-parity cause — its absence slows both equally.

**Recommended verification (cheap):** port PocketPal's bench pattern — measure `pp_avg` vs `tg_avg` (`BenchmarkRunnerScreen.tsx:875-876`) before/after adding the `+i8mm` variant. Expect pp_avg to jump multiple× while tg_avg moves less; that confirms #1 was the bottleneck.

---

## 4. Parity — what Quenderin already does that the OSS apps also do (no action needed)

- **Full GPU offload on iOS/Metal** — `n_gpu_layers` = all layers. (Quenderin ✓; LLMFarm `LLaMa.swift:113` = 100; PocketPal `:49` = 99.)
- **KV-cache quantization on tight devices** — Quenderin q8_0; llama.rn exposes the same q8_0/q4_0/etc. set (`rn-llama.cpp:53-78`). Quenderin gates it on device RAM, which is the right instinct.
- **n_ctx budgeted from RAM/model footprint** — Quenderin's dynamic budget is *more* sophisticated than PocketPal's fixed 2048 / LLMFarm's fixed 2048.
- **Runtime thread re-tuning under thermal load** — Quenderin's 4-level governor via `llama_set_n_threads` every 32 tokens is *more advanced* than any of the three (none re-tune at runtime). Keep it; consider pairing it with the affinity mask (§2a) so the surviving threads stay on big cores.
- **Chat template via `llama_chat_apply_template`** — standard across all; Quenderin's Qwen3 no-think handling is app-specific and fine.
- **KV reuse / context-shift across turns** — Quenderin does `seq_rm`/`seq_add`; llama.rn's slot manager is the multi-session version of the same idea.

---

### Clone notes
LLMFarm's initial full clone was killed by a network timeout mid-checkout; recovered via `--filter=blob:none --no-checkout` + sparse-checkout of just the Swift config files, and cloned the `llmfarm_core.swift` submodule the same way (that's where the actual `llama_context_params` construction lives — the app repo only has UI settings). All three repos' inference-config surfaces were read in full.
