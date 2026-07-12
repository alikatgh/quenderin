# Quenderin v0.2.0 — first Android release

An AI that runs entirely on your phone. No account, no cloud, no telemetry —
after a one-time model download every token is generated locally via llama.cpp.

## Android APK (sideload)

**`Quenderin-v0.2.0.apk`** — arm64-v8a, Android 9+ (API 28), ~23 MB.

- Chat with an on-device LLM — curated catalog sized to your device, or any GGUF
- Governed on-device agent: plans, uses local tools, asks before every mutation
- Interface in English, Russian, Korean, Japanese, Simplified Chinese
- Works fully offline after the model download
- Long-press any AI response to report it

Install: enable "install unknown apps" for your browser/file manager, open the APK.

> Note: this APK is signed with the project's own key. The upcoming Google Play
> version is re-signed by Play App Signing, so Play cannot update a sideloaded
> install (and vice versa) — pick one channel per device.

## iOS / macOS

v0.2.0 is submitted to the App Store (iOS + macOS universal) and pending review.

## Engine notes

- llama.cpp pinned at `b9190`; single baseline arm64 CPU backend this release.
  GPU (Vulkan/Adreno) offload and per-CPU-variant kernels return in 0.2.1.
- Verified end-to-end on an Android 15 arm64 emulator: model download →
  streaming inference → agent tools.
- Native Material 3 chrome (platform top bar + pill tab indicator); the whole
  UI — first-run flow AND the in-conversation chat screen — localized in all 5
  languages, including screen-reader labels.

APK SHA-256: `1815fd0d5e0693939dfeb6834660860493996f5da9d9a6be6827471c0a6fc362`
