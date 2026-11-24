# Native 0.6.1 store drafts

Updated 24 November 2026 from `main` (original 9 November 2026 draft from
`6e87618908b2f919c929d9cf7ae4cfa87df0885f`, refreshed for the 22–24 November
source integrations and dependency/build-floor updates). This text is the 0.6.1
draft. It is not a submitted update and it is not the version currently on the
stores.

## What is on the store now

- Apple live App Store versions (per PR `#247` / `5e7b4d1`): iOS **0.6.2** and
  macOS **0.6.1** are Ready for Sale, so Apple source now targets marketing
  version **0.6.3** with `CURRENT_PROJECT_VERSION` floor **35**
  (`apple/QuenderinApp/project.yml` and `Quenderin.xcodeproj`; Xcode Cloud
  assigns live build numbers above prior processed build `34`).
- Google Play has no public production listing for `ai.quenderin.app`. Closed
  testing - Alpha remains live on build **2 (0.2.0)** across 178 countries;
  upload key reset `88:0A:CA:18…84:F8:B6:F` was verified active on 22 November
  2026, and Android source sets `compileSdk = 36`, `targetSdk = 36`,
  `versionCode = 7`, `versionName = "0.6.1"`.

## What this draft describes

The 0.6.1 candidate on `main`, including model roles, the on-device checker,
Look and Listen, local tools, Doctor, Practice, plus 22 November source
integrations for Kromoss 8-step local image generation (Apache-2.0) and Hex /
`transcribe.cpp` local speech & dictation formatting (MIT, 20 presets + Silero
VAD v6.2). No Quenderin account. Local model files stay on the device.

## What was checked

Hosted GitHub CI passes on `main` (Android Gradle/AndroidX updates, Kotlin
core + debug APK, Apple Prism XCFramework + QuenderinKit tests + iOS simulator
SDK compile, desktop native runtimes, model/catalog/agent/router parity). That
is hosted compilation and synthetic host fixtures (`inferenceVerified: false`).
It is not tested full-weight inference, not a simulator or physical-device run,
and not a signed store archive.

An experimental catalog entry means the app can select that engine. It is not
tested inference, and it is not a claim about the 0.6.0 build already on the
App Store.

The App Store Connect 0.6.1 iOS and macOS versions were saved on 9 November at
**Prepare for Submission**. Refresh their What's New / App Review notes below
before attaching build **35** and submitting.

## Apple description

Quenderin runs open language models on your device. Download a compatible model for local offline chat, or explicitly choose a separate remote destination. Local chat needs no Quenderin account. Local model files stay on the device.

• Give this chat separate on-device models for chat, for an output check, and for photos or speech. Choosing a role does not download a model.
• When a checker model is already installed, a reply or a tool result is checked before it is shown. Look and Listen use a photo or speech model that is already on the device, then restore the previous local model. A missing file is not downloaded, and those replies are not presented as tested inference.
• Add optional tools on this device and turn each one off. A tool that is off does not run. On Mac, a local command is available. iPhone and Android accept only a server on this device.
• Doctor reports the models, notes, and tools for this chat. It does not start a chat or run a model. Practice scores saved tool questions. It does not score the model.
• Choose models with download sizes, compatibility checks and memory estimates. Automatic selection uses available device and performance information; manual choices remain available.
• Keep local conversations on your device. Saved Hy-Memory facts require your review and approval.
• Optionally connect to DeepSeek using your own API key. That destination sends its conversation to DeepSeek under your provider account and billing terms.
• Optionally connect to your own prepared Remote Harness server and trusted computer. Review the destination, trust and action approvals before remote work. Quenderin does not provide or provision a hosted AI service.
• Read formatted replies, copy code, retain separate drafts and recover interrupted remote sessions.
• Use separate workflows for still-image questions, verified Granite imports and local image generation on suitable hardware. Step 5 remains a separately approved connection to your prepared CUDA host.

Large models need complete downloads and substantial memory. Some specialist workflows are unavailable on ordinary phones. An experimental catalog entry is a manual choice of an engine. It is not tested inference. File size and active parameter count are not RAM requirements.

Internet access is needed for downloads, discovery and remote destinations. Local inference works offline after setup. Optional remote processing transmits data to the destination you select; its operator controls retained copies. On-device and remote models can make mistakes. Check important answers.

## What's new

This chat can use a different model already on the device for chat, for an output check, and for photos or speech. Choosing a role does not download a model, and local models stay on the device.

When a checker model is already installed, a reply or a tool result is checked before it is shown. Look and Listen use a photo or speech model that is already on the device, then restore the previous local model. If that file is missing, nothing is downloaded. Those replies are not tested inference.

Includes source integrations for Kromoss 8-step local image generation and Hex / transcribe.cpp local speech presets (experimental manual choices; not tested full-weight inference). Local tools are optional, and each tool can be turned off. Doctor does not start a chat. Practice scores tool use on saved questions and does not score the model.

No Quenderin account is required. Optional remote destinations are unchanged and still send data only when you choose them. An experimental catalog engine is a manual choice, not a tested model.

## App Review notes

0.6.1 adds on-device model roles, an output check, Look and Listen, local tools, Doctor, Practice, and experimental Kromoss image / Hex speech source integrations. No Quenderin account is required. Choose and download a small compatible model over Wi-Fi for ordinary local chat. No model download or server provisioning starts automatically.

A checker, photo, or speech model is used only when its file is already on the device. Nothing is downloaded for those roles. Look and Listen do not present their reply as tested inference. Doctor does not run a model. Practice scores saved tool questions and does not score the model.

DeepSeek, My computer, and Step 5 are the same optional destinations as 0.6.0. Each sends data only after the person chooses it. An experimental catalog entry is a manual engine choice, not tested inference.

Host fixtures and hosted compilation passed on `main` (build floor 35). This build is not tested full-weight inference, and no simulator or physical device was run for this submission.

## Google Play release notes

0.6.1 (versionCode 7, targetSdk 36): Use separate on-device models for chat, output checks, and photos or speech, plus experimental Kromoss image and Hex speech source support. Files stay on the device. Local tools can be turned off; Doctor does not start a chat; Practice scores saved tool questions, not the model. No account. Not tested full-weight inference.

The existing available track is Closed testing - Alpha (serving 0.2.0 / versionCode 2). Uploading a signed 0.6.1 / versionCode 7 AAB targeting API 36 resolves the Play Console API 36 policy enforcement banner on the active closed-test track. A draft or unsigned bundle is not a published Google Play update.
