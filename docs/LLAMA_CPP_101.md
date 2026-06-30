# llama.cpp C++ Internals 101 — what runs *under* the functions you call

> The third in the series ([`INFERENCE_101.md`](INFERENCE_101.md) = how decode works;
> [`MOBILE_PERFORMANCE_101.md`](MOBILE_PERFORMANCE_101.md) = how Quenderin adapts to a phone). This one
> goes one layer **down**: into the actual C/C++ of llama.cpp + ggml — the engine Quenderin links but
> doesn't own. It's grounded in a fresh read of the real upstream source (8 agents, one per subsystem),
> and every section ties back to the **exact C-API calls your `apple/.../LlamaEngine.swift` already makes**.
> So this reads as "here's what happens inside `llama_decode()`," not abstract theory.
>
> Caveat: llama.cpp moves *fast*. File/line refs are from the current clone; treat them as "look near
> here," not gospel. The architecture is stable; the function names churn (there's an active rename
> sweep — see §K).

---

## A. The two layers

llama.cpp is really **two libraries stacked**:

1. **`ggml`** (`ggml/src/`) — a pure-C tensor library + deferred compute engine. Knows nothing about
   LLMs; it does tensors, a compute graph, quantization, and hardware backends (CPU/Metal/Vulkan/CUDA).
2. **`llama`** (`src/llama-*.cpp`) — the LLM library *on top of* ggml: GGUF model loading, the
   transformer graph, the KV cache, tokenizer, sampler, chat templates.

You (Quenderin) only ever call the **`llama` C API** in `include/llama.h` — ~12 functions. Everything
below is what those 12 trigger.

## B. The C API surface — the ~12 functions your Swift actually calls

`include/llama.h` is the entire stable contract (Swift bridges to it; Android JNI calls it). All types
are **opaque pointers** (`llama_model*`, `llama_context*`, `llama_sampler*`, `llama_vocab*`). Mapped to
your real `LlamaEngine.swift` lifecycle:

| Lifecycle | C function | In your code |
|---|---|---|
| Init once/process | `llama_backend_init()` | `LlamaEngine.swift:128` |
| Load weights | `llama_model_load_from_file(path, params)` | `:139` (params at `:131-137`) |
| Make a context | `llama_init_from_model(model, ctxParams)` | `:170` (params `:151-166`) |
| Prefill / decode | `llama_decode(ctx, llama_batch_get_one(...))` | `:229` |
| Retune threads | `llama_set_n_threads(ctx, n, n)` | `:259` (the governor) |
| Build the sampler | `llama_sampler_chain_init` + `_add(top_p/temp/dist)` | `:217-220` |
| Sample a token | `llama_sampler_sample(sampler, ctx, -1)` | `:261` |
| Stop? | `llama_vocab_is_eog(vocab, tok)` | `:262` |
| Token → text | `llama_token_to_piece(...)` | `:264` |
| Free | `llama_free` / `llama_model_free` | `:122-123` |

> `model` is shared, read-only weights; `context` is per-session runtime state (KV cache + graph +
> logits). One model, many contexts. (And `include/llama-cpp.h` gives RAII `unique_ptr` wrappers — if
> you ever write C++ glue, use `llama_model_ptr` etc. so an exception can't leak the handle.)

## C. ggml — the deferred tensor graph (the foundation)

The non-obvious core: **`ggml_add(ctx, a, b)` does no math.** It allocates a tiny `ggml_tensor` struct
that *records* the op + its sources — a node in a DAG. Math happens only when
`ggml_backend_graph_compute()` runs the whole graph.

- **`ggml_tensor`** (`ggml/include/ggml.h:667`): `type` (F32/F16/Q4_K…), `ne[4]` (shape), `nb[4]`
  (byte strides), `op`, `src[10]` (up to 10 inputs), `data` (the bytes), `buffer` (which backend owns
  them). **A `permute`/`transpose`/`view` is free** — it just rewires `nb[]`, never moves data.
- **`ggml_context`** = a bump allocator (one big buffer, objects appended). Built with `no_alloc=true`
  for GPU graphs: tensor structs are zero-size; real memory comes later from the allocator.
- **`ggml_cgraph`** = the topologically-ordered node list, built by a DFS over `src[]`
  (`ggml_build_forward_expand`). **`ggml-alloc`** then simulates execution to find peak memory, reuses
  buffers when a tensor's last consumer is done, and even does **in-place** ops (RMSNorm, RoPE, ADD
  reuse their input's buffer). A `uid` on the graph lets backends **cache the compiled kernels** when
  the shape is identical across decodes — critical for Metal on iOS.

## D. Inside `llama_decode()` — the hot path

Every token your loop generates runs this pipeline (`src/llama-context.cpp`, `llama-batch.cpp`,
`llama-graph.cpp`, `llama-kv-cache.cpp`):

1. **Validate + split the batch.** `llama_batch_allocr` auto-fills positions/seq-ids, marks which
   tokens need logits (default: only the last), and splits into `ubatch`es that fit `n_ubatch`.
2. **Reserve KV slots** (`llama_kv_cache::find_slot`). A linear scan finds free cells. It's a
   **speculative dry-run** — tentatively reserve, then roll back — so a too-big batch fails *cleanly*
   with **return code `1`** ("no KV slot; shrink/clear and retry") without corrupting the cache.
3. **Build the graph — OR REUSE IT.** For single-token decode `n_tokens == 1` every step, so the graph
   topology is *identical* every call. `res->can_reuse()` detects this and **skips the rebuild** —
   only the input data is refreshed. This is the dominant decode optimization.
4. **Write K/V + attend.** Per layer, `ggml_set_rows` scatters the new token's K/V into the cache; then
   attention reads a **view** over the whole cache up to `n_kv`.
5. **`n_kv` is padded to a multiple of 256** so the mask/cache tensor *shapes* stay constant as the
   cache grows — which is what *keeps* the graph reusable (step 3). Padded cells get `-inf` in the
   mask. (Clever, and the reason trimming the cache mid-gen costs a ~1ms rebuild.)
6. **Compute + extract logits** via the backend scheduler (async on GPU).

**Ties to your code:** this is the deep version of `INFERENCE_101` §3. Your `KVCacheReuse` (decode only
the new suffix) is the app-level mirror of `llama_memory_seq_rm` — keep the system-prompt cells, evict
the user turn, re-decode. Return `1` is the "context full" signal your wrapper should handle by evicting
old turns.

## E. Quantization — why the model is 2.4 GB (and the bandwidth ceiling)

(`ggml/src/ggml-quants.c`, `ggml-common.h`.) `QK_K = 256` weights per k-quant superblock.

- **`block_q4_K`** = `{ half d; half dmin; uint8 scales[12]; uint8 qs[128]; }` = **144 bytes / 256
  weights = 4.5 bits/weight.** A two-level scale hierarchy (a superblock scale over 8 sub-block
  scales) is what makes k-quants better than the flat `q4_0`.
- **`Q4_K_M`** (your default) mixes `q4_K` for most layers + `q6_K` (6.5 bpw) for attention → a 4B model
  lands ~**2.4 GB**. On an iPhone 15 Pro (~68 GB/s) that's a **~28 tok/s ceiling** (real: 15–25). This
  *is* `INFERENCE_101` §0, now with the byte layout that proves it.
- **IQ quants** (`iq4_nl`…) use a non-linear codebook + an **importance matrix** (calibration stats) to
  spend bits where they matter — better quality at the same size, the lever if you want smaller models.
- ⚠️ **Directly relevant to your iOS build:** `ggml-quants.c` carries a `// HAVE_BUGGY_APPLE_LINKER`
  workaround (`volatile` loop counters to dodge an Apple `ld64` unroll bug). Good to know if a release
  build ever miscompiles a quant kernel.

## F. Backends + the prefill/decode split (the concrete mechanism)

`ggml-backend.cpp` schedules one graph across devices. The key heuristic (`ggml_backend_sched_split_graph`):
**weights on GPU → that layer's matmul runs on GPU**; the input layer + anything unclaimed falls to
**CPU (always registered last, the fallback)**.

**The punchline you've been circling** (`ggml-metal.cpp:757`, `ggml_backend_metal_device_offload_op`):
a matmul is offloaded to the GPU only when `batch_size >= 32` (env-tunable). During **prefill** the
batch = prompt length (large) → matmuls go to Metal. During **single-token decode** `ne[1] == 1` →
*below the threshold* → the matmul routes **back to CPU**. That's the exact code-level reason
"`n_gpu_layers = 999` but the GPU barely helps decode" — not a vibe, a `>= 32` check. On Apple's unified
memory there's no transfer penalty; a 1-row matmul is just faster on CPU SIMD than via GPU dispatch.

## G. Threading — what `llama_set_n_threads` actually does

(`ggml-cpu/ggml-cpu.c`.) The CPU backend runs a persistent **threadpool**; workers sleep on a condvar
and wake via a single atomic (`n_graph` packs a graph counter + active-thread count). Matmul work is
**chunk-stolen**: each worker `atomic_fetch_add`s a shared counter to claim the next row-block — dynamic
load balance, no pre-assignment.

Two things that matter for your governor:
- **More threads ≠ more speed past a point.** `ggml_graph_plan` caps threads at the graph's actual
  parallelism (`n_tasks`); attention ops cap at `n_heads`. Request 8 on a graph with 4-way ops → silently
  4. Combined with the bandwidth wall, this is *why* `ThreadPlanner` targets P-cores, not all cores.
- `llama_set_n_threads` is hot-swappable mid-run (it's grabbed via `get_proc_address` and cached) — which
  is exactly what your **in-flight thermal governor** (`LlamaEngine.swift:259`) exploits to shed threads
  as the SoC heats. You can also attach **two threadpools** (prefill = many threads; decode = fewer/
  background priority) via `llama_attach_threadpool` — a future option if you want decode to run cooler.

## H. GPU & NPU backends — and the honest NPU verdict

- **Metal** (`ggml/src/ggml-metal/`): kernels are JIT-compiled on first run (can take seconds on a fresh
  install — worth a "warming up" UI state). Simdgroup-matmul needs A15/M2+. The Metal-4 tensor API is
  gated to M5/A19+ because it was *slower* on M2/M3.
- **Vulkan** (`ggml-vulkan.cpp`, ~12k lines): the cross-platform path; the **safe Android GPU path today**.
- **CUDA**: desktop/server; not relevant to your phones.
- **Hexagon / NPU** (`ggml-hexagon.cpp`): self-labeled **"experimental."** It dispatches matmuls to the
  Snapdragon HMX neural accelerator (FastRPC to the DSP), but: needs the Qualcomm HTP SDK headers (not
  in AOSP), has op-coverage gaps with unfixed `FIXME`s, and a graph-optimizer correctness TODO.
  **Verdict: not deployable in a shipping app yet — Vulkan is the safe bet.** This is a concrete data
  point for your Georgi thread: the NPU path *exists* in llama.cpp but isn't production-ready, which
  matches the "we don't target the NPU yet" stance in [`NPU_NEURAL_ENGINE.md`](NPU_NEURAL_ENGINE.md).

## I. Model loading + GGUF + mmap

(`gguf.cpp`, `llama-model-loader.cpp`, `llama-arch.cpp`, `llama-mmap.cpp`.)

- **GGUF layout:** `[magic "GGUF"][version][n_tensors][n_kv][kv pairs][tensor infos][pad][tensor data]`.
  (Surprise: `n_tensors` is read *before* `n_kv`.) The first 4 bytes being `GGUF` is exactly what your
  `ModelIntegrity` magic-check verifies.
- **`use_mmap = true`** (your `LlamaEngine.swift:136`): the loader points each tensor's `data` pointer
  *directly into the memory-mapped file* — **zero copy**. After a tensor is uploaded to the GPU, it
  `munmap`s that fragment to reclaim RAM.
- **`use_mlock = false`** (your `:137`): exactly right for a phone — `mlock` would pin multi-GB resident
  and invite a jetsam kill (this is the engine-level confirmation of your Move 6 in `MOBILE_PERFORMANCE_101`).
- The **arch registry** (`llama-arch.cpp`) maps a model type (`LLM_ARCH_QWEN3`…) to its tensor-name
  patterns (`"blk.%d.attn_q"`) *and* the `ggml_op` each weight feeds — used to probe whether a backend
  can run that op before placing the weight there.

## J. Sampling, tokenizer, chat templates — and two hazards for you

(`llama-sampler.cpp`, `llama-vocab.cpp`, `llama-chat.cpp`.)

- **Sampler = a vtable pipeline.** Your `top_p → temp → dist` chain (`LlamaEngine.swift:217-220`) is a
  `std::vector` of `{iface, ctx}` stages; each `apply` narrows a shared candidate array; the terminal
  `dist` picks. `llama_sampler_sample` does fetch-logits + apply + accept in one call. (Nice detail:
  a no-op setting like `top_p ≥ 1.0` compiles to an empty stub, so chains are correct at any params.)
  There's even a **GPU sampling path** (build the softmax→cumsum→inverse-CDF as ggml ops) to avoid a
  CPU round-trip.
- **Tokenizer:** SPM (Llama 1/2, Gemma) vs BPE (Llama 3, Qwen, Mistral). Before merging, a `naive_trie`
  carves out special tokens like `<|im_start|>` — which is **why `parse_special=true` matters** (else
  they get fragmented). And `llama_token_to_piece` returns **zero bytes for control tokens unless
  `special=true`** — the engine-level reason control tokens don't normally appear in output.
- ⚠️ **Hazard 1 — your `stripControlTokens` is still necessary.** Chat templates are detected by
  **substring-matching the Jinja string** (no real parser), and there are **50+** of them. Models
  emit turn markers (`<start_of_turn>`, `[INST]`, `<|assistant|>`) that the engine doesn't always strip —
  exactly what your recent `stripControlTokens` fix handles. This is the upstream confirmation that the
  fix was real, not cosmetic.
- ⚠️ **Hazard 2 — `llama_vocab_is_eog()` is heuristic.** The end-of-generation set is built by name
  matching, with explicit workarounds for models where `<|end|>` is *both* a tool-call and an EOG token
  ("we don't have a good way to detect this"). Your stop-condition (`LlamaEngine.swift:262`) relies on
  this — worth a guard/test per model family, because a wrong EOG classification means either runaway
  generation or premature stop.

## K. What's churning (so you read the source correctly)

There's an active **rename sweep**: `llama_free_model → llama_model_free`,
`llama_new_context_with_model → llama_init_from_model`, `llama_token_bos → llama_vocab_bos`, etc. The old
names still compile (deprecated aliases) — make sure your Swift/JNI shim uses the **new** names. The KV
cache is now behind a `llama_memory_t` interface (to support recurrent models like Mamba alongside
transformers). And there's early wiring for **multi-token / speculative decode** (`LLAMA_CONTEXT_TYPE_MTP`)
— the thing to watch for your "beat the decode ceiling" question.

---

## L. The five things that connect straight back to Quenderin

1. **The `>= 32` offload gate (§F)** is the real reason your GPU offload helps prefill not decode — cite
   it, it's the precise mechanism behind `INFERENCE_101` §2 and the Georgi email.
2. **`mmap on / mlock off` (§I)** is validated by the loader internals — your jetsam-guard is correct.
3. **`llama_set_n_threads` hot-swap (§G)** is exactly what your thermal governor rides; and threads cap
   at graph parallelism, confirming P-core-only is right.
4. **Control-token stripping + EOG ambiguity (§J)** confirm two of your real code paths
   (`stripControlTokens`, the stop condition) are load-bearing, not paranoia.
5. **Graph reuse + `n_kv` padding (§D)** is the engine-level partner to your `KVCacheReuse` — together
   they're why time-to-first-token stays flat across a chat.

## M. Read it yourself (the fast path)

1. `include/llama.h` — skim the ~12 functions from §B. This is the whole contract; 30 min well spent.
2. `src/llama-context.cpp` → find `llama_context::decode` — the §D pipeline in one function.
3. `ggml/src/ggml-quants.c` → `block_q4_K` + `dequantize_row_q4_K` — see the 4.5-bpw layout from §E.
4. Cross-reference each against the `LlamaEngine.swift` line in the §B table. When the Swift call and the
   C++ body click together, you own the stack from your app down to the metal.
