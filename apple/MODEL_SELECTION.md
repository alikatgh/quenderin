# World-class model picking for iPhones

Choosing *which* on-device model to run is the make-or-break decision of an offline AI
app. Pick too big and iOS jetsam-kills the app mid-sentence; pick too small and a
flagship phone feels dumb. This is how Quenderin picks — and why a RAM-band heuristic
(fine for desktop) is the wrong tool here.

## Why total RAM is the wrong input on iOS

1. **Jetsam, not capacity.** iOS enforces a *per-app* memory limit far below total RAM.
   An 8 GB iPhone may only let an app hold ~5 GB before it's killed — and that's *with*
   the `com.apple.developer.kernel.increased-memory-limit` entitlement (which a serious
   LLM app must ship). A model that "fits 8 GB" can still crash the app. The binding
   constraint is the **jetsam budget**, read live via `os_proc_available_memory()`.
2. **Bandwidth, not just fit.** Token generation is memory-bandwidth bound. The same
   model that's snappy on an A18 Pro crawls on an A12. A pick that fits memory but runs
   at 4 tok/s is the wrong pick.
3. **iPhones are knowable.** iOS doesn't expose total RAM via a public API, but
   `hw.machine` ("iPhone16,1") identifies the device — so a curated table gives us its
   chip and RAM ceiling directly.

## The three gates (`IPhoneModelSelector`)

Each catalog model, largest → smallest (general-purpose first), must clear all three:

| Gate | Rule | Source |
|------|------|--------|
| **Memory** | est. runtime ≤ 85% of the jetsam budget | `os_proc_available_memory()` → live; device table → fallback |
| **Speed** | est. ≥ 7 tok/s on this chip | `AppleChip.inferenceScore` × reference rate |
| **Disk** | download + 0.5 GB margin ≤ free space | `DiskSpace` |

The first general-purpose model that clears all three is the default. Specialized models
(coder, reasoning) are **never** auto-picked — only offered as alternatives. Every result
carries a plain-English **rationale**, a **confidence** (comfortable / tight / forced),
and the **alternatives** considered (with why each was gated), so the UI can explain
itself instead of presenting a mystery choice.

## What this produces (verified in `IPhoneModelSelectorTests`)

| Device | Chip · RAM | Pick | Why |
|--------|-----------|------|-----|
| iPhone SE 2 / XR | A12–A13 · 3 GB | Llama 3.2 1B | budget ~1.5 GB |
| iPhone XS | A12 · 4 GB | Llama 3.2 1B | even where 4B-class fits RAM, A12 is too slow → down-tiered |
| iPhone 12 / 13 | A14–A15 · 4 GB | Llama 3.2 1B | 3B (~2.3 GB) exceeds the **measured ~2.1 GB** jetsam budget; live probe may upgrade |
| iPhone 13 Pro / 15 | A15–A16 · 6 GB | Qwen3 4B | the mainstream sweet spot (~4.5 GB budget) |
| iPhone 15 Pro / 16 Pro | A17–A18 Pro · 8 GB | Qwen3 4B (comfortable) | 7B *fits* (~6 GB budget) but is offered as a "tight" alternative, not the default |

The headline test: a device reporting **12 GB total RAM but a ~5 GB jetsam budget** — the
naive band recommends the 14B; the selector refuses it and picks 4B. Same RAM + different
chip → different pick. Neither is possible with a RAM-only heuristic.

The default prefers the largest **comfortable** model (snappy + real headroom) over a bigger
one that merely fits — so an 8 GB iPhone defaults to a fast 4B and *offers* the 7B, rather
than forcing a hot, tight 7B on everyone.

## Calibration — now measured, not guessed (with an honest cliff)

`AppleChip.inferenceScore` and the jetsam-budget fractions are **anchored to measured
2024–2026 data** (see `REALITY.md` + `docs/research/on-device-llm.md`): the chip scores
reproduce real stock-llama.cpp 1B rates (A14 ≈ 15, A16 ≈ 20 tok/s), and the memory budgets
match empirical iOS crash-report ceilings (4 GB→~2.1, 6 GB→~4.5, 8 GB→~6.0 GB). They are
deliberately conservative — a safe default that never gets jetsam-killed beats a bigger
model that crashes. **Still interpolated/unverified:** A15/A17 Pro/A18/A18 Pro scores, and
GPU-Metal/NPU decode (which barely helps — decode is memory-bound). Turning those into
ground truth needs on-device measurement (a PocketPal-style benchmark on physical
devices) — the same cliff that gates linking llama.cpp. When that lands, update the scores
and the tests' expected picks follow.

## Where it lives

- `AppleSilicon.swift` — chip scores + the curated iPhone device table + jetsam estimate.
- `IOSDeviceProfile.swift` — the rich profile + `DeviceProfiler` (live `os_proc_available_memory()`, seamed so `swift test` runs on macOS).
- `IPhoneModelSelector.swift` — the gates, the pick, the rationale, the alternatives.
- `OnboardingModel` uses it on iPhones (RAM-band elsewhere) and exposes `selection`;
  `OnboardingView` shows the rationale, speed, confidence, and "Other options".
