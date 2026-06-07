# On-device LLM inference on phones — verified research (2024–2026)

Source report for `apple/REALITY.md` and the calibration in `apple/QuenderinKit`.
Produced by a fan-out/adversarial-verification research pass (28 sources → 129 claims →
25 verified, 19 confirmed). Confidence and vote tallies are from 3-way verification.

## Confirmed findings

1. **Decode throughput, ~1–1.5B Q4 (CPU, stock llama.cpp), measured anchors** (3-0,
   arXiv 2506.19884): Kirin 9000 = 10.2; A14/iPhone 12 = 15.3; A16/iPhone 15 = 20.5 tok/s.
   MNN-class engines run ~2× faster. These are CPU figures — GPU/Metal/Vulkan decode is
   *comparable* (memory-bound), not a large multiplier.

2. **Apple Intelligence ≈ 3B**, vendor-reported **30 tok/s decode / ~1,667 prompt-tok/s
   prefill** on A17 Pro (3-0). ⚠️ This is a **2-bit-QAT, Neural-Engine, speculation**
   number — an optimistic ceiling, NOT generic Q4_K_M/Metal. Do not seed scores with it.

3. **Apple's 3B is not a Q4 footprint comparable** (3-0): ships at 2 bits/weight (QAT),
   ~0.75 GB weights / ~1 GB runtime, vs ~2 GB for a real Q4_K_M 3B GGUF.

4. **iOS jetsam limits are undocumented** (3-0): `increased-memory-limit` is a Boolean,
   no per-tier MB published; apps must call `os_proc_available_memory()`. Empirical
   third-party: ~1.4 GB (2 GB device), ~2.1 GB (4 GB), ~4.5 GB (6 GB), ~6 GB (8 GB).

5. **Sustained generation throttles phones** (3-0): 42.6 → 66.8 °C; Snapdragon 8 Gen 3
   prime clocks "nearly halved" by ~round 9/20; 10–20% drop (one study) up to **44% on
   iPhone 16 Pro, throttled 65% of the run** (arXiv 2603.23640); S24 Ultra thermal failure
   by iteration 6.

6. **Energy per round** (2-1/3-0, arXiv 2410.03613): 7B Q4, 192-token round = ~4.5–8.3 mAh
   → several hundred rounds per 4000–6000 mAh charge. Per-token 0.031–0.144 mAh.
   Decode energy 16–26× prefill (decode is memory-bound GEMV; prefill is compute-bound GEMM).

7. **NPU helps prefill, not decode** (3-0): mllm-NPU ~106 tok/s prefill (vs 10.9 CPU),
   PowerInfer-2 ~88 tok/s, on Snapdragon Hexagon — but decode stays memory-bound. Implies a
   hybrid "NPU for prefill, CPU/GPU for decode" split; no promised NPU decode gain.

8. **Stock Android DVFS governors leave ~25–40% on the table** (2-1, arXiv 2507.02135) —
   measured on ONE family (Tensor G2/Mali); may not transfer to Adreno/Apple/MediaTek.

9. **PocketPal AI** ships an on-device benchmark + a public crowd-sourced phone leaderboard
   (3-0) — the recommended way to *generate* the per-device dataset we still need.

## Refuted (did NOT survive verification — do not cite)

- "Android Cortex-A76/77 only 2–4 tok/s for 7B" (0-3).
- "4-bit 7B needs ≤4 GB peak" (0-3).
- "1.5B decode draws 7.9–9.9 W; 6–25% battery in 15 min" (1-2).
- "iOS Metal compute buffer 37× macOS / 4 GB for a 4B" (0-3).

## Biggest caveats

- Almost every hard tok/s number is **CPU-only on 2020–2024 SoCs**; A18/A18 Pro, 8 Elite,
  and Q4_K_M-on-Metal/Vulkan decode are sparse/absent → **interpolated**.
- Several "phone" benchmarks are **tablets** with phone chips (more thermal headroom).
- **Engine matters ~2×**; encode the engine, not just the chip.
- Throttle magnitude varies widely (10–20% vs 44%) by chassis/ambient/run length.
- iOS jetsam tiers are empirical and OS-version-variable → query at runtime.

## Open questions (the on-device cliff)

1. Real Q4_K_M **GPU (Metal/Vulkan) decode** tok/s vs CPU on the same device.
2. Per-tier iOS jetsam ceilings on current iOS/chips via `os_proc_available_memory()`.
3. Steady-state **post-throttle** sustained tok/s on phone chassis (A18/8 Elite/Dimensity).
4. Does QNN/Hexagon or ANE accelerate Q4_K_M **decode** in a shippable build, or only prefill?

## Primary sources

- arXiv 2506.19884 (MNN-AECS) · arXiv 2410.03613 (energy/thermal survey) · arXiv 2507.02135
  (DVFS/FUSE) · arXiv 2407.05858 (mllm-NPU) · arXiv 2406.06282 (PowerInfer-2)
- Apple ML Research: foundation models 2024 + 2025 updates · Apple `increased-memory-limit`
  entitlement docs · developer.android.com/ai/gemini-nano · github.com/a-ghorbani/pocketpal-ai
- github.com/ggml-org/llama.cpp discussions/4167 (M-series baseline — Macs, not phones)
