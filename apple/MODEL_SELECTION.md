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
| iPhone SE 2 / XR | A12–A13 · 3 GB | Llama 3.2 1B | budget ~1.4 GB |
| iPhone XS | A12 · 4 GB | Llama 3.2 1B | 3B *fits* RAM but A12 is too slow → down-tiered |
| iPhone 12 / 13 | A14–A15 · 4 GB | Llama 3.2 3B | fits the ~2.8 GB budget, fast enough |
| iPhone 13 Pro / 15 | A15–A16 · 6 GB | Qwen3 4B | the mainstream sweet spot |
| iPhone 15 Pro / 16 Pro | A17–A18 Pro · 8 GB | Qwen3 4B (safe) | 7B offered as a "tight" alternative |

The headline test: a device reporting **12 GB total RAM but a ~5 GB jetsam budget** — the
naive band recommends the 14B; the selector refuses it and picks 4B. Same RAM + different
chip → different pick. Neither is possible with a RAM-only heuristic.

## Calibration honesty (the on-device cliff)

`AppleChip.inferenceScore` (A18 Pro ≡ 1.0), the jetsam-budget fractions, and the runtime
footprint formula are **heuristics calibrated from public benchmarks**, not measured here.
They're deliberately conservative (safe defaults that never get killed beat a bigger model
that crashes). The one thing that turns these estimates into ground truth is **measuring
tok/s, time-to-first-token, peak footprint, and battery on real devices** — the same
on-device cliff that gates linking llama.cpp. When that data exists, update the scores and
the tests' expected picks follow.

## Where it lives

- `AppleSilicon.swift` — chip scores + the curated iPhone device table + jetsam estimate.
- `IOSDeviceProfile.swift` — the rich profile + `DeviceProfiler` (live `os_proc_available_memory()`, seamed so `swift test` runs on macOS).
- `IPhoneModelSelector.swift` — the gates, the pick, the rationale, the alternatives.
- `OnboardingModel` uses it on iPhones (RAM-band elsewhere) and exposes `selection`;
  `OnboardingView` shows the rationale, speed, confidence, and "Other options".
