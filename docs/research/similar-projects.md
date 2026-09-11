# Similar projects — the landscape Quenderin learns from

One canonical list of the projects doing what we do (an LLM running ON the device),
what each proves, and what we took from it. Detailed evidence lives in the linked
in-repo docs; keep this page the index, not the essay.

## Platform vendors (proof the category ships)

| Project | Who | What runs on-device | What we take from it |
|---|---|---|---|
| **Apple Intelligence** | Apple | ~3B foundation model, 2-bit QAT, Neural Engine, iPhone 15 Pro+ | Category proof. Their 30 tok/s is a QAT+ANE+speculation ceiling — we deliberately do NOT seed speed scores from it ([REALITY.md §1](../../apple/REALITY.md)). |
| **Gemini Nano / AICore** | Google | on-device LLM on Pixel 8 Pro+ | Category proof on Android; AICore shows the OS-level direction our app-level approach must coexist with. |

## Direct peers (open-source on-device chat apps)

| Project | Stack | What we took — with receipts |
|---|---|---|
| **PocketPal AI** + **llama.rn** | React Native over llama.cpp (`github.com/a-ghorbani/pocketpal-ai`, `github.com/mybigday/llama.rn`) | The deepest audit we've done of a peer: [2026-07-02 OSS audit](../audits/2026-07-02-oss-audit-llamacpp-mobile.md). Top deltas: per-CPU-feature arm64 builds (+dotprod/+i8mm) picked at runtime; explicit `n_batch`/`n_ubatch`; `-O3 -flto` fast-math on kernels; thread affinity pinned to the fastest cores; GPU/NPU offload defaults. Also: their on-device benchmark + public crowd-sourced leaderboard is the model for the per-device dataset we still need ([on-device-llm.md](on-device-llm.md) §9). |
| **LLMFarm** (guinmoon) | SwiftUI iOS over a prebuilt llama.cpp xcframework | Same audit. Validates our Route-A xcframework approach; a thinner wrapper than ours with fewer safety gates. |
| **MLC Chat** | TVM/MLC engine, iOS + Android | The engine-matters datapoint: MNN/MLC-class engines run ~2× stock llama.cpp ([on-device-llm.md](on-device-llm.md) §1). We stay llama.cpp for GGUF-ecosystem reach, and treat 2× as headroom, not a loss. |
| **Private LLM** | Commercial iOS, mlc-based | Proof of paid demand for exactly our privacy pitch (REALITY.md §1). |

## The engine itself

| Project | What we take |
|---|---|
| **llama.cpp** (ggml-org) | The inference engine on every platform we ship. M-series baselines from `discussions/4167`; our own measured anchors via `apple/verify-llama-link.sh` (~157–177 tok/s decode, 0.5B Q4 on M-series Metal). |

## Adjacent, watched but not copied

- **Ollama / LM Studio** — desktop-class local-LLM products; the Quenderin Mac app
  overlaps their space but stays one shared codebase with the phones (QuenderinKit).
- **Google Antigravity** — agent-workspace research. Checked 2026-06: its one
  transferable idea (an agent run exported as a shareable artifact/walkthrough)
  already ships in Quenderin's agent surface; the rest is IDE-bound and
  deliberately not copied.
- **edge0** ([Edge0-AI/Edge0](https://github.com/Edge0-AI/Edge0)) — streaming MoE inference
  (SSD expert offload + trained **prerouter** routing prediction + Recover-LoRA), MLX /
  Apple Silicon, Apache-2.0, preview tiers (35B-A3B, 8B-A1B). **Not copied:** macOS-only,
  Python, checkpoint-specific adapters — not a drop-in for our GGUF/llama.cpp stack (no
  Android). **What we take:** the *prerouter* idea (predict next-layer routing to overlap
  expert loads with compute) and its validation of SSD expert streaming; llama.cpp already
  ships the offload half (`--cpu-moe`/`-ncmoe`/`-ot`) but not the prediction. **Revisit when:**
  edge0 ships a CUDA or mobile backend, or a llama.cpp-compatible path. Detail:
  [moe-ssd-streaming.md](moe-ssd-streaming.md).

## Where the research lives

- [docs/research/on-device-llm.md](on-device-llm.md) — verified perf/thermal/energy claims (28 sources, adversarially verified).
- [docs/research/moe-ssd-streaming.md](moe-ssd-streaming.md) — SSD MoE streaming + the prerouter: what edge0 proves, what llama.cpp already ships, and the offload spike we can run without a fork.
- [docs/audits/2026-07-02-oss-audit-llamacpp-mobile.md](../audits/2026-07-02-oss-audit-llamacpp-mobile.md) — line-level audit of PocketPal/llama.rn/LLMFarm configs vs ours, ranked action list.
- [apple/REALITY.md](../../apple/REALITY.md) — the honest "can phones do this" summary that seeds our calibration code.
