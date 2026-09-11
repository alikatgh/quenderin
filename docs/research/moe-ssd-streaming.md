# SSD MoE streaming and the prerouter — what edge0 changes for us

_Researched 2026-09-10. Source: [Edge0-AI/Edge0](https://github.com/Edge0-AI/Edge0) (Apache-2.0,
MLX / Apple Silicon, ~1.1k stars). Companion to [similar-projects.md](similar-projects.md)._

The question this answers: edge0 streams a 35B-A3B from SSD on a 24 GB Mac at ~15–17 tok/s. We
already do the crude version of that (a paged MoE at 17.3 tok/s, [MoEShape.swift](../../apple/QuenderinKit/Sources/QuenderinKit/MoEShape.swift)).
Do we copy it, and if so, which half?

## The three mechanisms (only one is novel)

1. **SSD expert offload** — experts mmap'd from disk on demand, bounded by the active set (LRU
   cache + fixed-slot double buffering). This is the mechanism we already lean on via `use_mmap`
   + the OS page cache.
2. **Prerouter** — a *trained* per-layer head predicts the **next layer's** routing one token
   ahead, so expert loads overlap compute instead of stalling decode. Their claim: **+59% decode**.
   This is the one genuinely novel piece.
3. **Recover-LoRA** — distillation adapters recover most of the int4 quantization loss.

## What llama.cpp already has — don't rebuild it

The offload *half* is upstream already (verified in our vendored pin **and** HEAD):

| Flag | Effect |
|---|---|
| `-ot` / `--override-tensor` | per-tensor buffer-type override (`llama_model_params.tensor_buft_overrides`) |
| `--cpu-moe` | keep **all** MoE expert weights on CPU |
| `-ncmoe N` / `--n-cpu-moe N` | keep MoE weights of the first N layers on CPU |

What upstream does **not** have is the **prediction** — llama.cpp has no routing-lookahead prefetch.
It relies on the OS page-cache readahead heuristic.

## What we do today, and the concrete gap

Our Apple engine sets only `n_gpu_layers` (`LlamaEngine.swift:247`), all-or-nothing
(`GpuOffloadPolicy`): a model that fits the app budget → every layer on Metal; a paged MoE that
doesn't → **CPU-only** for the whole model. We never use `tensor_buft_overrides`/`-ncmoe`.

So for the exact case edge0 targets (35B-A3B on a 16 GB Mac) we currently pay CPU compute on the
**dense spine too** (attention, embeddings, shared experts), when llama.cpp would let the spine
stay on Metal while only the routed experts stream from CPU/mmap.

**The spike:** expose MoE expert buffer-type offload in the Apple engine and measure it against the
current full-CPU-only path on the same 35B-A3B. Gate: needs a MoE GGUF on disk (we have only dense
models today). Until measured, this stays a spike — the full-CPU path is the *verified* config and
must not be changed blind.

## The prerouter itself is an upstream research project, not a fork

A trained prerouter cannot be bolted on generically: it needs **per-model trained heads** (weights
tied to a checkpoint, like edge0's `prerouter_*.safetensors`). "Push it upstream" therefore means a
research contribution to llama.cpp (or a plugin surface for trained heads), not something we
implement in Quenderin — and it stays inside the no-fork rule. Watch, don't build.

## Recover-LoRA, for our quality grades

Quenderin grades each catalog model honestly (Quality: Low … High). Recover-LoRA is the technique
that makes a 4-bit MoE land close to its fp16 base (edge0 reports 3.9 / 2.8 avg-point loss). It is
**checkpoint-specific** (adapters trained per model), so it can't raise grades for arbitrary GGUFs —
but it is the reason the "int4 is a real quality hit" line in our grades may soften over time, and
it's worth flagging next to any future "we could ship a bigger model if we recovered its quant"
decision.

## Decision

- **Steal the offload idea, at the llama.cpp layer** — the spike above. No fork, no new engine.
- **Do not adopt edge0** — macOS-only, Python, checkpoint-specific; not a fit for our GGUF /
  llama.cpp cross-platform stack (and no Android).
- **Watch for the trigger** — a CUDA or mobile backend, or a llama.cpp-compatible path, would
  change the calculus ([similar-projects.md](similar-projects.md)).
