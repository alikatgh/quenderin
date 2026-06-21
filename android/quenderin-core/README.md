# Quenderin — Android (Kotlin)

The Android port, started the same way as iOS: the portable **Kotlin "brain"**
first, compiled and tested, before the device-coupled parts.

`quenderin-core` is a **pure-Kotlin/JVM** module (no Android framework deps), so
it compiles and unit-tests without a device — and it mirrors the Swift
`apple/QuenderinKit` and the desktop `src/constants.ts` exactly. All three
platforms must agree on the catalog and the recommendation.

## What's here

| File | Role |
|------|------|
| `ModelCatalog.kt` | The 11-model catalog (Qwen, DeepSeek, Gemma, Phi, Mistral, Llama) + quantization table |
| `ModelRecommender.kt` | `device RAM → recommended model` — Qwen3-first, identical thresholds to Swift/TS |
| `MemoryFitness.kt` | "Can this device load it?" — same 0.85/0.65 budgets |
| `SafetyBlocklist.kt` | The agent's hard sandbox (Pay/Delete/Password…) |
| `InferenceEngine.kt` | The runtime-agnostic seam + `MockInferenceEngine` |

## Verify

Headless, with just the Kotlin compiler (Android Studio bundles one) — no Gradle
needed:

```bash
KOTLINC="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc"
cd android/quenderin-core
bash "$KOTLINC" src/main/kotlin/ai/quenderin/core/*.kt src/verify/CoreVerify.kt -include-runtime -d core.jar
java -jar core.jar      # → 139 checks, ALL PASSED
```

Or, in Android Studio / with Gradle: `./gradlew test` (runs `src/test` JUnit).

## The architecture (same engine, thin Kotlin adapter)

Quenderin runs **llama.cpp** on every platform; only the adapter differs. On
Android that adapter is **Kotlin + JNI over the NDK** (already installed at
`~/Library/Android/sdk/ndk`):

```
Quenderin (Android app)
  └─ :app            Jetpack Compose UI + WorkManager downloads
      └─ :quenderin-core   this module (probe, catalog, recommend, fitness, safety, seam)
          └─ LlamaEngine (Kotlin) ── JNI ──► llama.cpp (C/C++)  ← built with the NDK
```

## Next steps (mirror iOS)

- `LlamaEngine.kt` + a JNI `.cpp` bridge → llama.cpp built via the NDK (the real
  inference; needs a device/emulator + a GGUF to verify — the same cliff as iOS).
- `HardwareProbe` real impl via `ActivityManager.MemoryInfo` (the core keeps it
  abstract so the JVM build stays pure).
- Background/resumable downloader via `WorkManager` + `DownloadManager`.
- The `:app` Compose module: onboarding → chat, on the mock engine first.

See `../../apple/ARCHITECTURE.md` for the cross-platform picture.
