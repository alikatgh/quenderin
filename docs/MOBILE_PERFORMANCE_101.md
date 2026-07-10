# Mobile Performance & Hardware Adaptation 101

> The sequel to [`INFERENCE_101.md`](INFERENCE_101.md). That doc explained *why* on-device decode is
> slow (memory-bandwidth-bound) and *why* phones throttle (heat). **This doc is the answer to "so what
> do you DO about it?"** — the six adaptations that make a 1–4B model feel good on a hot phone, each
> grounded in the exact real code + numbers. This is Quenderin's most unique engineering and the part
> worth being able to explain from memory. Every piece has an **Android twin** (kept in lockstep by
> `scripts/check_agent_parity.py`); the Swift is shown because it's the clearest.

---

## The problem, in one sentence

From the 101: sustained `tok/s` is capped by memory bandwidth, **and a phone's effective bandwidth
falls as it heats** (10–44% throttle on multi-minute runs, per `apple/REALITY.md`) — *and* if you use
too much RAM the OS kills you (**jetsam** on iOS). So the whole game is: **pick a model that fits, run
it as fast as the bandwidth allows, and stay cool + alive over a long generation.** Six moves do that.

---

## Move 1 — Right-size the model to the device (before anything runs)

Don't offer a model the phone can't run well. `IPhoneModelSelector` gates on **three** things — and
crucially **not** total RAM (full reasoning: [`../apple/MODEL_SELECTION.md`](../apple/MODEL_SELECTION.md)):

1. **Per-app memory budget** (iOS jetsam limit / Android native-heap) — *not* total RAM. iOS may kill
   an app at ~half the phone's RAM; total RAM is the wrong input.
2. **Chip throughput** — the measured `tok/s` class of the SoC (so we don't pick a model that "fits"
   but runs at 3 tok/s).
3. **Disk** — the GGUF has to download and live somewhere.

Output: the *largest comfortable* model + an honest heat/battery expectation. iPhone SE/12/13 → 1B;
13 Pro/15/16 Pro → Qwen3 4B; Android 12–16 GB flagships → Mistral 7B.

## Move 2 — Use performance cores only (`ThreadPlanner.swift`)

```swift
public static func recommend(performanceCores: Int?, totalCores: Int) -> Int {
    if let p = performanceCores, p >= 1, p <= total { return p }   // P-cores only
    return max(1, total - 1)                                       // fallback: all-but-one
}
```

A phone has fast **P-cores** and slow **E-cores**. Scheduling matmul-heavy decode onto the E-cores is
**slower AND hotter** — the slow cores bottleneck the fast ones and add heat for no throughput. And
because decode is bandwidth-bound (101), once you have enough threads to saturate the memory bus, *more
threads do nothing but generate heat*. So: target the P-core count, not all cores.

## Move 3 — The thermal governor: shed threads *as the phone heats* (`ThermalMonitor.swift`)

This is the centerpiece. A load-time thread count only catches a phone that's *already* hot — but a
10-minute agent loop is **what makes it hot**. So Quenderin re-tunes the thread count *during*
generation. The thread schedule per thermal level:

```swift
case .nominal:  return base          // full speed
case .fair:     return max(1, base-1)  // shed one core
case .serious:  return max(1, base/2)  // halve
case .critical: return 1               // single core — minimal heat
```

The `ThermalGovernor` is a tiny state machine with **built-in hysteresis** — it only re-tunes when the
4-level state *changes* AND the thread count actually differs, so a sensor flapping at a boundary can't
thrash the native call:

```swift
public mutating func update(level: ThermalLevel) -> Int? {
    guard level != currentLevel else { return nil }                 // same level → no-op
    let n = ThermalThrottle.recommendedThreads(level: level, baseThreads: baseThreads)
    guard n != currentThreads else { return nil }                   // same count → no-op
    currentThreads = n; return n
}
```

The engine drives it: in `LlamaEngine.swift:257`, **every 32 tokens** it reads the thermal level and, if
the governor returns a new count, calls `llama_set_n_threads(...)`. The read is cheap, heat moves
slowly, so 32 tokens is the right cadence. **Counter-intuitive but correct: when the phone is hot, the
fix is FEWER threads, not more** — you trade peak tok/s for a *sustainable* rate instead of throttling
to a crawl or getting killed. (This is exactly "power-aware decode" — the lever in the Georgi email.)

## Move 4 — KV-cache reuse: keep time-to-first-token flat (`KVCacheReuse.swift`)

In a chat, turn 2's prompt is "turn-1 + the reply + your new message." Re-processing the whole thing
every turn makes replies get slower as the conversation grows (and re-heats the SoC chewing the same
tokens). So decode **only the new suffix**:

```swift
public static func plan(cached: [Int32], new: [Int32]) -> Plan {
    if !cached.isEmpty, cached.count < new.count, new.prefix(cached.count).elementsEqual(cached) {
        return Plan(clearCache: false, decodeFrom: cached.count)   // pure append → reuse
    }
    return Plan(clearCache: true, decodeFrom: 0)                   // diverged → full reprefill
}
```

**The fail-safe is the elegant part:** reuse *only* when the cache is a strict prefix of the new prompt
(the common "append one turn" case). Any divergence — the context slid and evicted old turns, history
was edited, a new chat — wipes the cache and reprefills from scratch. So a mismatch costs a re-prefill
(correct, just no speedup); it can **never** feed the model a corrupted context. (An Android JNI
cache-mirror desync was caught + fixed by exactly this equivalence check.)

## Move 5 — Size the context to survive jetsam (`ContextWindow.swift` + `KVCachePolicy.swift`)

The KV cache grows with `n_ctx` and sits *on top of* the weights in RAM. A fixed `4096` can push a
tight phone into a jetsam kill even for a model that "fits by weights alone." So `n_ctx` is sized from
the **headroom left after the weights load**:

```swift
let headroomGB = appBudgetGB - modelWeightsGB * 1.15   // free after weights + ~15% overhead
case ..<0.25: return 512     // barely fits → minimal KV
case ..<0.6:  return 1024
case ..<1.2:  return 2048
default:      return 4096
```

Then **quantize the cache to stretch it.** `KVCachePolicy` picks `q8_0` when headroom `< 1.2 GB`, else
`f16`. A `q8_0` token costs ~**53%** of an `f16` token, so the *same* memory budget holds ~**+90%**
context — `ContextWindow` scales the f16 size by `1 / 0.53`, clamps to `[256, 8192]`, rounds to a
256-multiple. Net: a 1B gets a big context; a 7B on the *same* phone is capped tight but usable instead
of a 512-token stub — and neither gets OOM-killed.

## Move 6 — Load the weights without getting killed (`LlamaEngine.swift:131-137`)

```swift
modelParams.n_gpu_layers = 999     // offload all layers to Metal (helps prefill; free on unified memory)
modelParams.use_mmap  = true       // weights stay pageable → fast cold start, OS can reclaim
modelParams.use_mlock = false      // do NOT wire multi-GB resident — that's what gets you jetsam-killed
```

`mmap` keeps the multi-GB weights *pageable* (the OS can reclaim them under pressure); `mlock` is
explicitly **off** — pinning gigabytes of weights resident is exactly what gets the app killed when the
user switches to music/maps. The safe default is pinned so it can't regress.

**Android is NOT the same story** (r8 R4): `n_gpu_layers = 999` is safe on Apple silicon (Metal,
unified memory) but must be **SoC-gated on Android** — llama.cpp's Vulkan backend quality is
heterogeneous. Per-SoC reality as measured/researched (`GpuOffloadPlanner` encodes this):

| GPU family | Vendor examples | Verdict |
|------------|-----------------|---------|
| Adreno (Snapdragon 8xx) | Samsung S23/S24 US, Pixel-on-QC | Proven — offload helps prefill |
| Mali (Dimensity, Tensor) | Pixel 6–9, many mid-range | Can be **slower than CPU** or crash on compute shaders |
| Xclipse (Exynos) | Samsung S22–S24 EU | Unproven — default CPU |

Default is **CPU**; offload is enabled per-SoC only after a measured tok/s win, and decode barely
benefits either way (bandwidth-bound) — the win is prefill. Update this table only with on-device
measurements, never by extrapolation.

---

## How they compose (load-time → in-flight)

```
DOWNLOAD/PICK         LOAD                                    GENERATE (per turn / per token)
─────────────         ────                                    ──────────────────────────────
Move 1: pick model →  Move 6: mmap on / mlock off             Move 4: reuse KV (decode only new suffix)
   (3 gates)          Move 5: n_ctx from headroom + KV quant  Move 3: governor re-tunes threads /32 tok
                      Move 2: P-core thread count                      as the SoC heats
```

Load-time moves (1, 5, 6, the initial 2) decide *what runs and how big*; in-flight moves (3, 4)
keep it *fast and sustainable while it runs*.

## The honest limit (what none of this fixes)

These adaptations make the model **fit and stay sustainable** — they do **not** break the fundamental
ceiling. `tok/s ≈ bandwidth ÷ model-size` still rules; the governor *manages* throttling, it doesn't
*eliminate* it. The only things that beat the ceiling for a single stream are a **smaller/more-quantized
model** and **speculative decoding** (101 §6) — the latter being the open question with Georgi. Be
honest about this: Quenderin's edge is *making a small model feel good on the device it's on*, not
making a phone as fast as a server.

## Cross-platform parity

Every piece above has an Android twin (`android/quenderin-core/.../`): `ThreadPlanner.kt`,
`ThermalMonitor.kt`/`ThermalThrottle`/`ThermalGovernor`, `KVCacheReuse.kt`, `ContextWindow.kt`,
`KVCachePolicy.kt`. The in-decode thermal loop runs in the JNI C++ on Android (the Kotlin holds the
pure state machine). `check_agent_parity.py` gates that they stay equivalent.

## Prove it to yourself

1. **Predict the governor:** a phone at `base=4` P-cores hits `.serious` mid-generation — how many
   threads now? (Answer: `base/2 = 2`. Then `.critical` → `1`.)
2. **Predict the context:** app budget 3 GB, a 2.4 GB model, `q8_0` cache — roughly what `n_ctx`?
   (Headroom ≈ `3 − 2.4×1.15 = 0.24 GB` → 512 f16 → `512/0.53 ≈ 966` → round → ~1024.)
3. **Explain, out loud:** why does the governor *remove* threads when hot? Why does KV reuse make
   replies stay fast as the chat grows? Why is `mlock` off? When does KV reuse refuse to reuse?

When those come out fluently, you own the hardest, most original part of the codebase — and you can
walk Georgi (or an investor, or a hire) through it without notes.

## Where it lives

| Adaptation | iOS | Android |
|---|---|---|
| Model selection | `IPhoneModelSelector.swift` | `*ModelSelector.kt` + `MODEL_SELECTION.md` |
| P-core threading | `ThreadPlanner.swift` | `ThreadPlanner.kt` |
| Thermal governor | `ThermalMonitor.swift` + `LlamaEngine.swift:251` | `ThermalMonitor.kt` + JNI loop |
| KV reuse | `KVCacheReuse.swift` | `KVCacheReuse.kt` |
| Context + KV quant | `ContextWindow.swift`, `KVCachePolicy.swift` | `*.kt` twins |
| Jetsam-safe load | `LlamaEngine.swift:131` | `llama_jni.cpp` model params |
