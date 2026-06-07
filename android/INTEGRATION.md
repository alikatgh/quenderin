# Android integration — from mock to on-device llama.cpp

This is the Android twin of `apple/QuenderinKit/INTEGRATION.md`. It explains the two
states the app ships in and how to cross the on-device cliff.

## What's proven vs. what's the cliff

| Layer | State | How it's verified |
|-------|-------|-------------------|
| `quenderin-core` (Kotlin brain) | **Done, tested** | `kotlinc` + `src/verify/CoreVerify.kt` → 29 checks; JUnit `CoreTest` for `./gradlew test` |
| `LlamaEngine` Kotlin adapter | **Done** — fails cleanly off-device | Part of the 29 checks (reports unavailable, throws a clear "not linked" error) |
| `jni/llama_jni.cpp` (C++ bridge) | **Written, not compiled here** | Needs the NDK + a llama.cpp checkout — build in Android Studio |
| `app/` Compose UI | **Written, not compiled here** | Needs the Android SDK + AGP — build in Android Studio |
| Real inference on a device | **The cliff** | Needs your hardware + a GGUF file |

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
   git submodule add https://github.com/ggml-org/llama.cpp android/jni/llama.cpp
   cd android/jni/llama.cpp && git checkout <PINNED_COMMIT>
   ```
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
