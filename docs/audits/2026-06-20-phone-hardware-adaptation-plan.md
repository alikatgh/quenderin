# Phone hardware-adaptation plan

This plan adapts on-device inference to real phone hardware constraints by correcting thread scheduling, memory budgeting, and model selection so the engine stops scheduling decode onto slow E-cores and stops sizing context/model picks off total RAM instead of the live app-memory budget. It splits into changes whose logic is unit-verifiable on the JVM/Swift now and changes whose effect requires a physical device (Vulkan, Metal flash attention, cache-tuning, live thermal/battery signals).

## Status — shipped (as of 2026-06-21)

Every **Priority 1–2** "do now" item plus the verifiable slices of Priority 3 are merged to `main`,
each behind iOS `swift test` + Android core verification, with the iOS engine's native fields proven
compiled against the **pinned** llama/ggml headers (vendored xcframework → `canImport(llama)` true) via
a bogus-symbol probe:

- **P-core thread count at load** — `ThreadPlanner` (both platforms). _(PR #22)_
- **Footprint-aware n_ctx** — `ContextWindow.recommend(appBudget, weights)`. _(PR #23)_
- **Android selection via native-heap budget** — already routed through `AndroidModelSelector` in `AppRoot` (verified, no change). _(audit #26)_
- **Honest 'unsupported' exit** — `SelectionConfidence.unsupported` → onboarding `Failed`. _(PR #24)_
- **Live ThermalMonitor + thermal-adaptive threads (load-time)** — `ThermalLevel`/`ThermalThrottle`; iOS reads `ProcessInfo.thermalState`, Android maps `PowerManager` status. _(PR #25)_
- **In-flight thermal governor** — `ThermalGovernor` re-tunes threads *during* a long decode (iOS fully wired: samples every 32 tokens → `llama_set_n_threads`; Android governor tested for parity, JNI loop is on-device). _(PR #29)_
- **KV-cache quantization (q8_0)** — `KVCacheType`/`KVCachePolicy` + cache-aware `n_ctx`; engine sets `type_k`/`type_v`. ~2× context on tight devices. _(PR #26)_
- **mmap/mlock jetsam guard** — explicit `use_mmap = true`, `use_mlock = false` at model load (both platforms). _(PR #27)_

**Finding — Metal flash attention is already optimal:** the pinned header's `flash_attn_type` defaults to
`LLAMA_FLASH_ATTN_TYPE_AUTO` (-1), so llama.cpp auto-enables FA where the backend supports it (Metal).
Forcing `ENABLED` is a no-op at best and unsafe on backends where AUTO correctly disables it → **no change**.
This is also why KV quant stops at q8_0: q4_0 for the V cache requires FA on the non-AUTO path.

**Genuinely needs a device next** (can't be CI-verified here): Android's in-decode thermal read + thread
set inside the JNI C++ loop (iOS is already wired; the shared `ThermalGovernor` decision logic is tested),
Android **Vulkan GPU offload**, and per-tier `n_batch`/`n_ubatch` tuning. See _On-device milestones_.

## Do now (verifiable)

| Priority | Change | Files | Impact |
|----------|--------|-------|--------|
| 1 | Use P-core-only thread count at load (both platforms) | `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift` loadLocked (the two thread assignments after n_ctx, ~L131); `android/quenderin-core/src/main/kotlin/ai/quenderin/core/LlamaEngine.kt` constructor default for threads (L18) + new pCoreCount() helper. JNI already accepts the threads param. | 15-30% sustained tok/s on A-series iPhones (e.g. 7→4 threads on A16), 20-35% on big.LITTLE Android (e.g. 8→4 on Snapdragon 778G), plus lower heat/throttle. No-op on M-chip iPads where P-core count already meets the old value. Pure logic verifiable now: sysctl returns >0 and ≤ activeProcessorCount; pCoreCount() unit-testable on the JVM with a temp /sys fixture. |
| 1 | Route Android model selection through AndroidModelSelector (native-heap budget), not total-RAM bands | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelRecommender.kt` (L10-19); parallel to apple ModelRecommender.swift:39-44. | Stops the most common silent OOM on sub-4 GB Android: a 3 GB-total phone (~1.4-1.8 GB heap) currently gets llama32-3b (~3 GB runtime) which jetsams on load. Routing through the selector picks a model that fits. High on every constrained Android device. Verifiable now by unit test. |
| 1 | Size n_ctx from real app-memory budget and model footprint, not total RAM | apple ContextWindow.swift (new overload ~L9) + MemoryFitness.swift (L72-75); android ContextWindow.kt (L11) + AndroidDeviceProfile call sites; add kvBytesPerToken() to ModelEntry on both platforms. | A 1B on a 4 GB phone gets ~3× more context (≈3072 vs 1024); a 7B on a 4 GB phone correctly capped ≤1024, preventing silent KV+weights OOM. Fixes false-safe loads on busy iPhones (sees 6 GB, real budget 1.8 GB) and over-sized n_ctx on Android where app budget is ~60-75% of total. Largest budget-correctness win for ≤4 GB devices. Pure functions verifiable now. |
| 2 | Add an honest 'cannot run' / unsupported exit to the forced-fallback path | `apple/QuenderinKit/Sources/QuenderinKit/IPhoneModelSelector.swift` (L174-193); `android/quenderin-core/src/main/kotlin/ai/quenderin/core/AndroidModelSelector.kt` (L123-141); add unsupported to SelectionConfidence on both platforms. | Replaces the silent load→OS-kill→crash failure on bottom-5% devices with an honest message. High UX impact on the absolute floor. Verifiable now by unit test. |
| 2 | Add live ThermalMonitor (foundation for runtime adaptation) | NEW `apple/QuenderinKit/Sources/QuenderinKit/ThermalMonitor.swift` (~50 lines); NEW `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ThermalMonitor.kt` (~60 lines). | Zero inference impact alone, but unblocks thermal-adaptive threading and the generation thermal pause — the engine currently has no thermal visibility. Foundational. The enum mapping is verifiable now; the live OS values need a device. |
| 2 | Surface KV-cache quantization (q8_0 / q4_0) by RAM band | apple IOSDeviceProfile.swift (~L17) + ContextWindow.swift; android AndroidDeviceProfile.kt (~L10) + ContextWindow.kt; llama.cpp bridge layer for the param pass-through. | q4_0 cuts KV memory ~75% on 2-3 GB phones (e.g. 1.5B@2048: 176 MB fp16 → 44 MB), the difference between OOM at ~1500 tokens and completing 2048. Quality cost small (q8_0 perplexity +1-2%, q4_0 +3-5%). Profile/multiplier logic verifiable now; the bridge param pass-through is on-device. |
| 3 | Thermal-adaptive thread reduction during generation | apple LlamaEngine.swift loadLocked (L131-132) + runGeneration decode loop (L202-215); android LlamaEngine.kt load()/complete() loop + new nativeSetThreads JNI bridge. | On a 10-minute agent loop, dropping 6→1 thread under 'serious' cuts CPU watts ~4-6× on big.LITTLE, sustaining ~60-70% of peak tok/s instead of ~35% worst-case. High for sustained loops on budget SoCs; negligible for single chat turns. The threshold→thread-count mapping is verifiable now; the heat-driven effect needs a device. |
| 3 | Enable Metal flash attention on iOS | `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift` loadLocked (after the n_threads assignment, ~L131). | Fused FA kernel avoids materializing the N×N attention matrix: ~15-25% tok/s at n_ctx=4096 (and lower peak VRAM under shared-memory pressure), ~5-10% at 2048. The flag being set is verifiable now in a Swift test; the speedup needs a device. |
| 4 | Generation thermal pause with UI feedback | apple LlamaEngine.swift runGeneration loop (L202-217); android LlamaEngine.kt complete() path; both ThermalMonitor files. | Replaces the uncontrolled thermal cliff (44% flagship, 60%+ budget, no feedback) with a controlled inter-token pause that keeps the SoC at a sustainable clock and tells the user. Medium for chat, high for multi-minute agent loops. Loop logic verifiable now; thermal behavior on-device. |
| 4 | Make memory-overhead estimate quantization-aware and self-consistent | apple MemoryFitness.swift (overhead logic L23-35); android MemoryFitness.kt (L18-27) + AndroidModelSelector.kt estimatedRuntimeGb (L75). Depends on ModelEntry.kvBytesPerToken + planned n_ctx. | Unblocks false-blocked loads on 4-6 GB devices (7B q4_0 reported 5.2 GB vs real ~4.65 GB) while the Android base bump correctly disqualifies ~15-20% of 3-4 GB Android picks that look like they fit but jetsam. Both pure functions, verifiable now. |
| 4 | Make mmap explicit and forbid mlock (jetsam guard) | apple LlamaEngine.swift loadLocked (after modelParams, ~L122); android/jni/llama_jni.cpp (after mp default params, ~L121). | Correctness guard for the exact device class this project targets: prevents a regression that would cause jetsam kills under background pressure, and keeps faster mmap cold-start loads (~30% on a 4.7 GB GGUF). Field values verifiable now in a unit test. |
| 4 | Add a Q3_K_M 1B catalog entry for 1.0-1.5 GB budgets | apple ModelCatalog.swift (after llama32-1b, ~L162) + IPhoneModelSelector.swift defaultPreferenceIDs (L68-71); android ModelCatalog + AndroidModelSelector.kt defaultPreferenceIds (L53-56). | Fills the Q4(1.5 GB)→Q2 cliff: devices with 1.0-1.5 GB usable budget currently fall to Q2_K (Low quality, not recommended); Q3_K_M (Fair) still fits and is meaningfully better. Affects 2-3 GB Android and older 2 GB-jetsam iPhones. Verifiable now (catalog + selection unit test). |
| 5 | Honest tok/s expectation in the forced-fallback rationale | apple IPhoneModelSelector.swift forced-path rationale (L188-192); android AndroidModelSelector.kt (L136-139). | Sets honest expectations on very weak SoCs (old Snapdragon 4xx, Helio G). Tiny code change, real UX-integrity win on the floor. Verifiable now (assert rationale string for a low-score profile). |
| 5 | Session-mode-aware ThermalBattery estimate (chat vs agent loop) | apple ThermalBattery.swift estimate() (L37-71); android ThermalBattery.kt estimate() (L35-60). | Informational accuracy only (no inference change): an agent-loop session honestly predicts ~50% throttle instead of ~35%. Medium for user trust on budget phones where the chat-vs-sustained gap is largest. Pure function, verifiable now. |
| 5 | Low-battery guard before generation start (Android lead, iOS low-power) | android LlamaEngine.kt constructor (L16-21) + complete() (L67-71); apple LlamaEngine.swift generate() (L87-102). | Prevents draining the last 5% in a 3-minute agent loop and dying mid-response — proportionally worse on smaller budget-phone batteries. Low frequency, high severity. Battery-read + policy logic verifiable now; full behavior needs a device. |
| 5 | Proactive memory-pressure degradation hooks | apple MemoryFitness.swift (add enum + helper); android MemoryFitness.kt (same). OS-callback wiring lives in the app layer. | Replaces silent jetsam/LMK kills under concurrent load (music, browser tabs) with proactive KV shedding so the engine survives. High for 2-3 GB devices, medium for mid-range. The helper/enum are verifiable now; the OS-callback wiring is on-device. |

## On-device milestones

| Priority | Change | Files | Impact |
|----------|--------|-------|--------|
| 3 | Enable Vulkan GPU offload on capable Android devices | android/jni/llama_jni.cpp nativeLoad signature + mp.n_gpu_layers (L121-122); android LlamaEngine.kt constructor + nativeLoad external decl (L17-19, L89). | Single largest Android throughput gain: 2-4× tok/s for 4B-7B models on Adreno 600+/Mali-G7x+ (community benches ~4→12-18 tok/s on Snapdragon 778G). Fallback (0 layers) unchanged on non-Vulkan budget phones. Requires the Vulkan .so on a real device; detection logic mockable on JVM. |
| 3 | Tune n_batch / n_ubatch per hardware tier | android/jni/llama_jni.cpp (after n_ctx, L127-129); apple LlamaEngine.swift loadLocked (after n_ctx, L129-133). | ~1.5-2× faster prefill (time-to-first-token) on CPU-only budget Android by fitting the micro-batch in L2; ~10% on iOS/Metal. Decode tok/s unchanged. The wiring (n_ubatch set before init) is inspectable now; the cache-sensitivity gain is on-device. |

## Top picks now

1. Use P-core-only thread count at load (both platforms)
2. Route Android model selection through AndroidModelSelector (native-heap budget), not total-RAM bands
3. Size n_ctx from real app-memory budget and model footprint, not total RAM
4. Add an honest 'cannot run' / unsupported exit to the forced-fallback path
5. Surface KV-cache quantization (q8_0 / q4_0) by RAM band
