# Android integration — from mock to on-device llama.cpp

This is the Android twin of `apple/QuenderinKit/INTEGRATION.md`. It explains the two
states the app ships in and how to cross the on-device cliff.

## What's proven vs. what's the cliff

| Layer | State | How it's verified |
|-------|-------|-------------------|
| `quenderin-core` (Kotlin brain) | **Done, tested** | `kotlinc` + `src/verify/CoreVerify.kt` → 139 checks; JUnit `CoreTest` for `./gradlew test` |
| `LlamaEngine` Kotlin adapter | **Done** — fails cleanly off-device | Part of the 139 checks (reports unavailable, throws a clear "not linked" error) |
| `jni/llama_jni.cpp` (C++ bridge) | **Written; one-command verify ready** | `android/verify-llama-link.sh` builds llama.cpp for Android + compile-checks it |
| `app/` Compose UI | **Written, not compiled here** | Needs the Android SDK + AGP — build in Android Studio |
| Real inference on a device | **✅ PROVEN (2026-06-14)** | `android/verify-llama-link.sh` ran it on a booted arm64 emulator — coherent output, ~102 tok/s |

> **One-command verification (`android/verify-llama-link.sh`):** the Android twin of the
> **proven** `apple/verify-llama-link.sh`. It builds llama.cpp for Android (NDK), compiles
> `jni/llama_jni.cpp` against it, builds `tools/llama-smoketest.cpp` (a C++ mirror of the
> verified iOS Swift smoke test), and runs inference on a booted emulator/device via adb.
>
> ✅ **PROVEN END-TO-END (2026-06-14, NDK r26d):** `libllama.so` built for Android arm64-v8a,
> `jni/llama_jni.cpp` compiled against it, and the smoke test **ran on a booted arm64
> emulator** — coherent output ("the sky is blue because…"), **~102 tok/s decode (CPU)**. The
> real-inference **APK** (`./gradlew :app:assembleDebug` with `jni/llama.cpp` present) installs
> and the running app loads `libquenderin_llama.so` (`nativeloader: …ok`), so the app uses the
> real engine. Matches the iOS twin (Mac Metal + simulated iPhone). Physical-phone tok/s/
> battery/thermals are the only thing left to measure.

The app **boots on `MockInferenceEngine`** so the whole onboarding → chat flow runs the
moment you open it in Android Studio — no llama.cpp required. `MainActivity` switches to
the real `LlamaEngine` automatically once `libquenderin_llama.so` is present. So you can
ship/run the shell first and link llama.cpp second.

## Step 1 — open + run on the mock

1. Install the Android SDK (already at `~/Library/Android/sdk`) + NDK (installed).
2. Open `android/` in Android Studio (Giraffe+). It will create the Gradle wrapper.
3. Run `app` on an emulator or device. It probes RAM, recommends a model, "downloads"
   (mock), and opens chat on the canned engine. This proves the UI + the shared brain.

## Step 2 — link llama.cpp (cross the cliff)

llama.cpp stays C/C++; `jni/llama_jni.cpp` is the only glue (twin of the Swift adapter).

1. Add llama.cpp pinned to a known commit:
   ```sh
   # v0.2.0 release pin (2026-07-11): tag b9190 — the LAST tag before ggml-vulkan
   # started requiring the SPIRV-Headers host package (2026-05-17, #22009).
   git clone --depth 1 --branch b9190 https://github.com/ggml-org/llama.cpp android/jni/llama.cpp
   ```
   The checkout is **gitignored** — do NOT park it in /tmp and symlink (a reboot wiped
   exactly that on 2026-07-11 and cost a re-derivation of the whole pin).
   Release builds also need `ninja` on PATH for the Vulkan shader-gen host tool:
   `export PATH=$HOME/Library/Android/sdk/cmake/3.22.1/bin:$PATH` (harmless when Vulkan is off).
2. In `app/build.gradle.kts`, **uncomment** the `ndk { abiFilters … }` and the
   `externalNativeBuild { cmake { … } }` blocks. (`jni/CMakeLists.txt` does
   `add_subdirectory` on the checkout and links `quenderin_llama` → `llama`.)
3. Rebuild. Gradle invokes CMake/NDK, produces `libquenderin_llama.so` per ABI, and
   `LlamaEngine.NATIVE_AVAILABLE` flips `true` — the app now uses real inference.

### Keep the C API in sync
`llama_jni.cpp` targets the post-2024 llama.cpp API (`llama_model_load_from_file`,
`llama_init_from_model`, the `llama_vocab` + `llama_sampler` chain). The API moves —
if the build breaks, diff against `jni/llama.cpp/include/llama.h` at your pinned commit
and adjust (same discipline as the iOS adapter, which was checked against `llama.h`).

### Optional — GPU offload (Vulkan)
CPU is the default and is stable everywhere. To build the **Vulkan** backend, configure the
native build with `-DQUENDERIN_VULKAN=ON` (the flag is in `jni/CMakeLists.txt`):
```kotlin
// android/app/build.gradle.kts → externalNativeBuild { cmake { ... } }
arguments += "-DQUENDERIN_VULKAN=ON"
buildConfigField("boolean", "QUENDERIN_VULKAN", "true")   // tell Kotlin the .so has the backend
```
Then let `GpuOffloadPlanner` decide **per SoC** whether to actually offload, and pass the result to
the engine — so a Vulkan build stays safe on every device (Adreno offloads; Mali/Xclipse stay on CPU):
```kotlin
val soc = AndroidSoc.fromSocModel(Build.SOC_MODEL)           // API 31+
val gpuLayers = GpuOffloadPlanner.recommend(soc, vulkanAvailable = BuildConfig.QUENDERIN_VULKAN)
val engine = LlamaEngine(deviceBudgetGb = budget, gpuLayers = gpuLayers)
```
**Why a decision and not just "all layers":** Android Vulkan driver quality is heterogeneous, and on
mobile **decode is memory-bandwidth bound** — GPU offload mainly speeds **prefill** (long-prompt
time-to-first-token), not steady tok/s. Background + measured rationale: `docs/NPU_NEURAL_ENGINE.md`.
A/B it on your device with `QUENDERIN_VULKAN=1 ./verify-llama-link.sh` (see `docs/DEVICE_VERIFICATION.md`).

## Step 3 — get a model onto the device

`MockModelDownloader` returns a fake path. The real downloader (next milestone) is a
`WorkManager` foreground job with a Wi-Fi/disk-space preflight (port of the iOS
`BackgroundModelDownloader`). Until then, push a GGUF manually for a device smoke test:
```sh
adb push qwen3-4b.Q4_K_M.gguf /sdcard/Android/data/ai.quenderin.app/files/
```
and point `load(model, filePath)` at it.

## Step 4 — measure (the real proof)

On a physical device, capture tok/s, time-to-first-token, peak RAM, and battery for the
recommended model. That's the number that tells us whether the "50-year-old, off-grid,
asks a question" story actually holds — and it can only be measured here.
