# Reality check: can phones actually run these models?

Short answer: **yes — this is shipping reality, not a fantasy.** But the honest picture
has hard edges around heat and battery that we design around rather than wish away. Every
number here is from the cited 2024–2026 sources (see `docs/research/on-device-llm.md` for
the full verified report); where data is thin or interpolated, it's labelled as such.

> The numbers below seeded the calibration in `AppleSilicon.swift` /
> `IPhoneModelSelector.swift` / `ThermalBattery.swift`. They are **conservative, measured
> baselines for stock llama.cpp** — not best-case vendor figures.

---

## 1. Not fantasizing — the proof it ships

| Who | What runs on-device | Where |
|-----|---------------------|-------|
| **Apple Intelligence** | a ~3B foundation model (2-bit QAT, Neural Engine) | iPhone 15 Pro+ (A17 Pro, 8 GB) |
| **Google Gemini Nano** | on-device LLM via AICore | Pixel 8 Pro+ and others |
| **PocketPal AI / MLC Chat / Private LLM / LLM Farm** | 1B–8B Q4 GGUF/MLX | iPhone & Android, today |

Apple itself ships exactly what we're building. The 1B–4B tier we recommend is firmly in
range; 7–8B is feasible on 8 GB flagships but tight.

**One honest correction:** Apple's reported **30 tok/s** for its 3B model on A17 Pro is a
*2-bit-QAT, Neural-Engine, speculation-assisted* number — an **optimistic ceiling**, not
what a generic Q4_K_M GGUF on llama.cpp/Metal will do. We do **not** seed our speed scores
from it. ([Apple ML Research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates))

---

## 2. Speed — what to expect (stock llama.cpp, Q4, decode)

> **✅ Measured in-repo (2026-06-07, `apple/verify-llama-link.sh`):** QuenderinKit's exact
> `LlamaEngine` path, real llama.cpp, **Qwen2.5-0.5B Q4_K_M** — on an **M-series Mac (Metal):
> ~157–177 tok/s decode**; on the **iPhone 16 simulator (host CPU): ~160 tok/s**. These are
> a *small* model on *host/Mac* hardware — a **ceiling, not a phone result** — but they're the
> first real numbers in this repo and they confirm the pipeline + the memory-bound model
> (a 0.5B is ~2× a 1B, consistent with the table below). Real *phone* numbers still need a
> physical device.

Measured anchors (CPU, arXiv [2506.19884](https://arxiv.org/pdf/2506.19884)) plus our
interpolations. **Decode is memory-bandwidth bound, so GPU/Metal and NPU barely raise
these — they mainly speed up *prefill*.** An optimized engine (MNN-class) is ~2× faster.

| Chip | 1B | 3–4B | 7–8B | Source |
|------|----|------|------|--------|
| A14 (iPhone 12) | **15 tok/s** | ~7–9 | not advised | measured |
| A16 (iPhone 15) | **20 tok/s** | ~10–13 | tight | measured |
| A17 Pro / A18 Pro | ~24–28 | ~11–13 | ~8 (tight) | **interpolated** |
| Snapdragon 8 Gen 2/3 | ~10–20 | ~6–12 | ~4–8 | measured (Kirin/Dimensity anchors) |

⚠️ **Caveats that matter:** A15/A18/A18 Pro, Snapdragon 8 Elite, and direct
GPU-Metal/Vulkan decode figures are **sparse or absent** — treat the right two columns as
estimates. Engine choice swings results ~2×. Several published "phone" benchmarks are
tablets carrying phone-class chips (more thermal headroom than a phone).

---

## 3. Heat — the real ceiling

Phones **reliably throttle** under sustained generation. This is the single biggest
constraint on the autonomous-agent vision — not memory.

- Snapdragon 8 Gen 3 prime-core clocks **nearly halved by ~round 9** of 20 continuous
  rounds; 10–20% throughput loss on longer prompts. (arXiv [2410.03613](https://arxiv.org/html/2410.03613v3))
- **iPhone 16 Pro lost 44% throughput and was throttled 65% of the run**; Samsung S24
  Ultra hit OS thermal failure (GPU 78 °C) by iteration 6. (arXiv 2603.23640)

**What this means:**

| Use pattern | Reality |
|-------------|---------|
| **Bursty chat** (reply, then read) — the 95% case | Fine. The phone sheds heat between turns; barely warms. |
| **Sustained / agent loops** (back-to-back, minutes) | Throttles ~10–44% after a few minutes; phone gets hot. **The agent-loop ceiling.** |

Our `ThermalBattery` estimate uses a ~35% sustained-loss midpoint and says so.

---

## 4. Battery — the real cost

| Framing | Number | Source |
|---------|--------|--------|
| One 7B round (64-prompt + 128-gen ≈ 192 tok) | **~4.5–8.3 mAh** | arXiv [2410.03613](https://arxiv.org/html/2410.03613) |
| → per 1,000 generated tokens, 7B | **~35 mAh** (≈ 5 mAh × params-in-B) | derived |
| Decode vs prefill energy | decode is **16–26×** prefill (memory-bound) | arXiv 2506.19884 |
| Rounds per charge (4000–6000 mAh) | **several hundred** | derived |

**Translated to product:**
- A **typical chat reply (~300 tokens)** of a 4B model costs **well under 1% battery** —
  unnoticeable over a day.
- **Continuous** generation of a 4B model drains roughly **15–25%/hr of active generation**
  on a flagship — fine for a session, not for running flat-out all day. Treat a long agent
  run like GPS navigation: plan for it.

> The specific "1.5B draws 7.9–9.9 W" power figures we found were **refuted** in
> verification (1-2 vote) — we don't cite them; the per-round/per-token energy above held up.

---

## 5. Memory — why the picker uses jetsam, not total RAM

iOS kills an app well below total RAM. Apple publishes **no** per-tier limit; apps must
call `os_proc_available_memory()` at runtime. Empirical third-party crash reports
([Apple entitlement docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit) + forum threads):

| Device RAM | ~Usable before jetsam (with entitlement) | Implication |
|-----------|------------------------------------------|-------------|
| 4 GB | **~2.1 GB** | a 3B Q4 (~2.3 GB runtime) is **risky** → we fall back to 1B |
| 6 GB | **~4.5 GB** | 4B Q4 fits comfortably |
| 8 GB | **~6.0 GB** | 4B comfortable; 7B *tight* (offered, not default) |

These are approximate and OS-version-variable, so they're only our **offline fallback** —
the live `os_proc_available_memory()` reading is authoritative and can upgrade a device.
(Note: Apple's own 3B ships at ~1 GB because it's **2-bit**, not Q4 — not a footprint
comparable for our GGUF builds.)

---

## 6. The bottom line for Quenderin

- **The "50-year-old, off-grid, asks a few questions" persona works today.** A 1–4B model
  answers in seconds and costs a rounding error of battery.
- **The "runs an autonomous agent loop for an hour" use case is where physics pushes back** —
  heat-throttling and battery, not capability. Build agent loops with thermal awareness
  (back off, batch, let it cool).
- **Our numbers are conservative, measured baselines.** They will only improve with the
  real on-device measurement we still owe: run the PocketPal-style benchmark on physical
  A15/A17/A18 devices, capture GPU/Metal decode and post-throttle steady-state, and replace
  the interpolated chip scores. That's the on-device cliff — the same one that gates linking
  llama.cpp.
