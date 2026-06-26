# NPU / Neural Engine — the honest landscape (and why we don't target it yet)

**Short version:** on-device LLM **decode is memory-bandwidth bound**, so an NPU mostly helps **prefill**,
not the tokens/sec a user feels in chat. Targeting NPUs means rebuilding — per vendor, with closed SDKs
and finicky model conversion — what `llama.cpp` already gives us portably via **Metal (iOS)** and
**Vulkan (Android Adreno)**. We use the GPU path now (see [`GpuOffloadPlanner`](../android/quenderin-core/src/main/kotlin/ai/quenderin/core/GpuOffloadPlanner.kt))
and revisit NPUs only if a specific device + vertical justifies the cost. This doc records the analysis
so the decision is deliberate, not an omission.

---

## The physics that frames everything

Autoregressive **decode** generates one token at a time, and each token must stream the **entire model's
weights** through the compute units. On a phone the CPU, GPU, and NPU all hang off the **same memory
bus**, so the bottleneck is **memory bandwidth**, not raw FLOPs. A 4-bit 4B model is ~2.5 GB of weights;
at ~50 GB/s of usable mobile bandwidth that caps you near ~20 tok/s *regardless of which compute unit
runs the matmul*. (`AndroidSoc.kt` says this directly: "Decode is memory-bandwidth bound, so GPU/NPU
mostly help prefill, not these numbers.")

Where an NPU/GPU **does** help:
- **Prefill** (processing the prompt) — compute-bound and highly parallel, so offload cuts
  time-to-first-token on long prompts (RAG context, long chats, agent transcripts).
- **Energy** — an NPU can do the same work at lower power, which matters for the battery/thermal
  ceiling (`REALITY.md`: sustained loops drain ~15–25%/hr and throttle 10–44%).

Neither changes the headline chat tok/s much. That's the trap in "we'll be faster because NPU."

---

## iOS — Apple Neural Engine (ANE) via Core ML

- **The ANE is not generally programmable.** You reach it through **Core ML**, which runs a converted,
  static graph — not arbitrary transformer ops with a KV cache, dynamic shapes, and custom sampling.
  Converting an LLM to Core ML that *actually lands on the ANE* (vs falling back to GPU/CPU) is finicky,
  per-model work, and Apple controls op support.
- **Apple's own stack splits the difference:** Apple Intelligence uses the ANE — but with a model Apple
  trained and converted in-house on their private runtime. **MLX**, Apple's open on-device framework,
  runs LLMs primarily on the **GPU (Metal)**, not the ANE — a strong signal about where the practical
  win is.
- **What we use instead:** `llama.cpp`'s **Metal** backend (`n_gpu_layers = 999` in `LlamaEngine.swift`).
  It's a single, uniform, Apple-maintained driver — competitive, zero per-model conversion, and it
  tracks new models the day they ship in GGUF.

**Verdict (iOS):** Metal is the right default. An ANE path would be large, per-model, Apple-gated work
for a mostly-prefill gain. Not worth it unless a vertical needs the energy win badly enough to fund it.

---

## Android — NNAPI, vendor SDKs (QNN/…), MediaPipe

- **NNAPI is a dead end.** Google **deprecated NNAPI in Android 15** (2024). Building on it now is
  building on a sunset API.
- **Vendor NPU SDKs are fragmented and closed.** Qualcomm **QNN / AI Engine Direct**, MediaTek
  **NeuroPilot**, Samsung **Exynos** SDKs — each is a different, per-vendor, often-NDA'd toolchain with
  its own model-conversion format. Supporting "Android NPUs" means supporting *N* of these and the
  matrix of driver versions. That's a team's worth of maintenance for a wrapper project.
- **Google's answer is MediaPipe LLM Inference / AICore (Gemini Nano)** — which *is* the NPU path, but
  it's **Google's** stack, gated to specific models and devices. Using it means shipping Google's models
  through Google's runtime, not running arbitrary GGUF.
- **What we use instead:** `llama.cpp`'s **Vulkan** backend, gated by `GpuOffloadPlanner` to the
  GPU family that's actually proven for it — **Adreno** (Qualcomm/Snapdragon, e.g. the test S23's 8 Gen 2).
  Mali/Xclipse stay on CPU until a real device proves they're stable and faster (a `forceGpu` override
  exists to benchmark them). Portable, open, one codebase.

**Verdict (Android):** Vulkan-on-Adreno is the pragmatic GPU win today; NPUs are fragmented, closed,
and partly sunset (NNAPI). Revisit per-vendor (most likely **QNN on Snapdragon**) only for a specific
device + use case where the prefill/energy gain is the product.

---

## When NPU *would* be worth it (the honest triggers)

Revisit this decision if **any** of these become true:

1. **Prefill latency is the product** — e.g. long-context RAG or agent transcripts where
   time-to-first-token, not tok/s, is what the user feels. NPU/GPU prefill offload is real there.
2. **Battery/thermal is the blocker for a vertical** — field/industrial use with hours of sustained
   generation, where the NPU's lower energy-per-token is the difference between shippable and not.
3. **You commit to one platform + one SoC** — e.g. a Snapdragon-only enterprise device. Then a single
   **QNN** integration is tractable and the fragmentation argument disappears.
4. **A portable NPU abstraction matures** — if `llama.cpp`/`ggml` grows a maintained NPU backend, we
   inherit it for free, exactly as we inherit Vulkan today. (This is the most likely path — ride the
   ecosystem rather than rebuild it.)

Until one of those holds, the GPU path is the correct, honest engineering choice — and it's the one a
small open-source team can actually maintain.

---

## What we shipped toward this

- **`GpuOffloadPlanner`** (pure, unit-tested) — safe-by-default, per-SoC Vulkan offload decision.
- **`n_gpu_layers` plumbed** through the JNI (`llama_jni.cpp`) and Kotlin `LlamaEngine`.
- **`-DQUENDERIN_VULKAN=ON`** opt-in build flag in `android/jni/CMakeLists.txt`.
- **Benchmark path** — `android/verify-llama-link.sh` can build CPU and Vulkan `.so`s for a real
  device A/B (see `docs/DEVICE_VERIFICATION.md`). The numbers from a physical Snapdragon device are
  what turn "Adreno is the proven target" from a documented default into a measured one.
