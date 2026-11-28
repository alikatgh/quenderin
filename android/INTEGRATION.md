# Android integration — native 0.6.3

This is the Android twin of `apple/QuenderinKit/INTEGRATION.md`. The native 0.6.3
candidate uses the locked Prism runtime, verified Muse source patch and isolated
image runtime. A stock llama.cpp checkout does not provide these capabilities.

The update expands the shared text catalog to 28 entries, including complete-part
Beam and Muse installation. Dedicated workflows cover still-image questions with
managed vision model/projector pairs, explicit Hy-Memory proposals, receipt-verified
Granite Switch imports, Step 5 Preview through a user-owned CUDA host, and isolated
FLUX/MOSS image generation. Resource leases, memory floors and cancellation guard
these workflows; availability depends on each model's artifacts and device capacity.
See `docs/bonsai-2.md` for exact sources and limits. Source integration and hosted
compilation do not establish full-weight inference or image quality.

The source declares `versionCode = 8`, `versionName = "0.6.3"`, and compile/target
API 36. The candidate workflow uses JDK 21, AGP 8.10.1, Kotlin/Compose compiler
2.4.21, and the checked-in Gradle 8.11.1 wrapper. It installs `platform-tools`,
`platforms;android-36`, `build-tools;35.0.0`, `ndk;26.3.11579264`, and
`cmake;3.22.1`. Java source and bytecode targets remain 17.
The wrapper verifies its distribution against Gradle's published SHA-256.
Use code 8 for a Play update only after confirming that it is unused and above
the highest uploaded code across tracks. See the
[Play update checklist](../docs/ANDROID_PLAY_UPDATE_CHECKLIST.md).

## Verification boundaries

| Layer | State | How it's verified |
|-------|-------|-------------------|
| `quenderin-core` (Kotlin brain) | Portable source and fixture tests | `kotlinc` verification and `:quenderin-core:test` |
| Prism/Muse source identity | Build-time gate | `prepare_prism_runtime.py verify` and CMake's provenance check |
| Image runtime and package identity | Build and final-package gates | `build_android_diffusion.sh` seals the private runtime; `verify_diffusion_android_package.py` checks APK/AAB bytes, dependency closure and 16 KiB alignment |
| Noise/JNA SDK and package identity | Hosted build and final-package gates | `native_sdk.py build --platform android` runs in hosted Linux x86_64 GitHub Actions; `native_sdk.py verify-package` checks Noise/JNA bytes, `arm64-v8a`, 16 KiB ELF alignment for every `.so`, and stored APK ZIP alignment |
| `jni/llama_jni.cpp` and Compose app | Hosted compilation gate | CI builds `assembleDebug` and `bundleRelease` with prepared Prism, image, and Noise/JNA runtimes |
| Signed Google Play update | Separate release step | Requires the package's registered upload key and Play Console acceptance |
| Android 16 behavior and real inference | Device validation still required | No current physical-device evidence is implied by compilation or fixtures |

The historical 2026-06-14 smoke test used NDK r26d and an arm64 emulator with an
older runtime, reporting coherent output and about 102 tok/s. Verification of the
current candidate, Bonsai, Muse, Android 16, and physical-phone performance requires
separate evidence. The legacy `verify-llama-link.sh` is for device smoke tests.

The app **boots on `MockInferenceEngine`** when `jni/llama.cpp` is absent so onboarding → chat
runs in Android Studio without NDK. `MainActivity` switches to real `LlamaEngine` automatically
once `libquenderin_llama.so` is present (Gradle auto-enables `externalNativeBuild` when the
checkout exists). **Demo mode is labeled in chat + Settings** and mock replies say they are
canned. **Release/bundle builds fail** without `jni/llama.cpp` unless you pass
`-Pquenderin.allowMockRelease=true` (intentional demo APK only).

## Debug builds without a native checkout

Open `android/` in an Android Studio version compatible with AGP 8.10.1, or run
`./gradlew :app:assembleDebug`. Without a native checkout this compiles the demo
engine; it cannot establish native inference support. The Gradle wrapper is
already checked in. Building does not require an emulator or model weights.

## Prepare and compile the pinned native runtime

llama.cpp stays C/C++; `jni/llama_jni.cpp` is the only glue (twin of the Swift adapter).

1. From the repository root, prepare the runtime at a new or matching destination:
   ```sh
   quenderin_root="$PWD"
   python3 scripts/prepare_prism_runtime.py fetch --destination "$quenderin_root/android/jni/llama.cpp"
   python3 scripts/prepare_prism_runtime.py verify --source "$quenderin_root/android/jni/llama.cpp"
   ```
   This downloads source only. The lock is `shared/prism-runtime.json`; the helper
   verifies the base revision, applies the locked Muse patch, and verifies its
   files. It refuses to replace a mismatched existing checkout. Choose a separate
   destination if `android/jni/llama.cpp` already contains other work and pass that
   absolute path below. The example checkout is gitignored.
2. Build the isolated image runtime and, in hosted Linux x86_64 GitHub Actions CI,
   the verified Noise/JNA SDK in new absolute work directories. Replace the example
   NDK and output paths with your own paths.
   ```sh
   export ANDROID_NDK_HOME="/absolute/path/to/Android/sdk/ndk/26.3.11579264"
   quenderin_diffusion_work="/absolute/new/android-diffusion"
   quenderin_remote_sdk="/absolute/new/remote-android-sdk"
   bash scripts/build_android_diffusion.sh "$quenderin_diffusion_work"
   # Hosted Linux x86_64 GitHub Actions only (requires GITHUB_ACTIONS=true, CI=true,
   # and the NDK linux-x86_64 prebuilt toolchain):
   rustup toolchain install 1.90.0 --profile minimal
   rustup target add --toolchain 1.90.0 aarch64-linux-android
   python3 -B native/remote-crypto/tools/native_sdk.py build \
     --platform android --sdk "$quenderin_remote_sdk"
   ```
   The image builder fetches pinned source, statically links its private C++
   runtime, and verifies both sealed image DSOs. The SDK builder enforces hosted
   Linux x86_64 GitHub Actions execution (`GITHUB_ACTIONS=true` and `CI=true`),
   generates Kotlin bindings, compiles arm64 API 28 Noise, and verifies the
   Android JNA AAR; it refuses local workstation runs (use the hosted Android CI
   or candidate workflow to produce a Prism release bundle, or pass a verified
   SDK directory checked with `native_sdk.py verify --platform android`).
3. Build the app with all three runtime paths and run the JVM unit tests.
   ```sh
   cd "$quenderin_root/android"
   ./gradlew :app:assembleDebug :app:bundleRelease \
     --no-daemon --console=plain \
     -Pquenderin.runtime=prism \
     -Pquenderin.llamaDir="$quenderin_root/android/jni/llama.cpp" \
     -Pquenderin.diffusionLibDir="$quenderin_diffusion_work/jniLibs" \
     -Pquenderin.remoteCryptoDir="$quenderin_remote_sdk"
   ./gradlew :quenderin-core:test --no-daemon --console=plain
   ```
   Gradle enables CMake/NDK automatically and builds arm64-v8a JNI plus the CPU
   backend variants. Prism release builds require both the verified image
   runtime and Noise/JNA SDK. These build tasks require no model weights.
4. Verify the actual packaged libraries in **both** outputs.
   ```sh
   cd "$quenderin_root"
   python3 scripts/verify_diffusion_android_package.py \
     --libraries "$quenderin_diffusion_work/jniLibs" \
     --package android/app/build/outputs/apk/debug/app-debug.apk
   python3 scripts/verify_diffusion_android_package.py \
     --libraries "$quenderin_diffusion_work/jniLibs" \
     --package android/app/build/outputs/bundle/release/app-release.aab
   python3 -B native/remote-crypto/tools/native_sdk.py verify-package \
     --sdk "$quenderin_remote_sdk" --package android/app/build/outputs/apk/debug/app-debug.apk
   python3 -B native/remote-crypto/tools/native_sdk.py verify-package \
     --sdk "$quenderin_remote_sdk" --package android/app/build/outputs/bundle/release/app-release.aab
   ```
   These commands check the packaged image and Noise/JNA bytes, image dependency
   closure, ABI, and 16 KiB ELF alignment. The Noise/JNA verifier also checks ZIP
   alignment for stored native libraries in the APK it receives.
5. The bundle is `android/app/build/outputs/bundle/release/app-release.aab`. Without
   `android/keystore.properties` it is **unsigned**. Reuse the registered upload
   key for a signed Google Play update; do not create a replacement key as a
   workaround. See `docs/RELEASE.md` for the signing and console steps.

CI uses the same explicit runtime selections and compiles an unsigned release
bundle. A passing job proves compilation and package verification of that
revision, not signing, upload, submission, installation, or inference with the
real model weights.

### Keep the C API in sync
`llama_jni.cpp` targets the post-2024 llama.cpp API (`llama_model_load_from_file`,
`llama_init_from_model`, the `llama_vocab` + `llama_sampler` chain). The API moves —
if the build breaks, diff against `jni/llama.cpp/include/llama.h` at your pinned commit
and adjust (same discipline as the iOS adapter, which was checked against `llama.h`).

### CPU-variant backends (0.2.1 default)

`jni/CMakeLists.txt` builds ggml's Android CPU variant set (`android_armv8.0` … `armv9.2`, DOTPROD/I8MM)
as dlopen-able plugins. The JNI loads them from `applicationInfo.nativeLibraryDir` and ggml picks the
best match for the live CPU. **Packaging:** `useLegacyPackaging = true` is required — AGP otherwise
leaves the `.so` files inside the APK and the scan finds zero devices.

Affinity (`ggml_threadpool_new`) is resolved at runtime from the CPU backend registry, not linked into
`libquenderin_llama.so` (link-time was an undefined-symbol with `GGML_BACKEND_DL`).

### Optional — GPU offload (Vulkan)
CPU-variant backends are the default win. Vulkan stays opt-in because the vendored llama.cpp Vulkan
backend requires SPIRV-Headers at configure time (not in the NDK). To build it:
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

## Downloads and Android 16 validation

The native app uses a WorkManager `dataSync` foreground worker with disk/memory
preflights, resumable transfers, artifact verification, and persisted progress.
Muse is a multipart installation; all required shards must verify before loading.
The demo-only `MockModelDownloader` does not download weights.

The API 36 source audit found existing Compose Scaffold/system-bar/IME inset
handling and no edge-to-edge opt-out or legacy `onBackPressed` interception.
Android 16 job quotas also apply to long-running foreground WorkManager jobs;
large background downloads can pause when quota is exhausted. Physical-device
checks must still establish download stop/resume behavior, keyboard and system
bar layout, predictive back, and lifecycle recovery. These checks were not run
for the current build-only candidate preparation.

## Measure on a physical phone before promotion

On a physical device, capture tok/s, time-to-first-token, peak RAM, and battery for the
recommended model. That's the number that tells us whether the "50-year-old, off-grid,
asks a question" story actually holds — and it can only be measured here.
