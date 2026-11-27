# Vision in the main chat composer (`FeatureFlags.visionInChat`)

The still-image path in the Apple chat composer merged in
[PR #250](https://github.com/alikatgh/quenderin/pull/250).
It remains unreleased and disabled in source as of 27 November 2026.

## Current status: OFF by default

`FeatureFlags.visionInChat` is **`false`** in both:

- `apple/QuenderinKit/Sources/QuenderinKit/FeatureFlags.swift`
- `android/quenderin-core/src/main/kotlin/ai/quenderin/core/FeatureFlags.kt`

The availability helper `FeatureFlags.visionInChatAvailable(flag:runtimeAvailable:modelInstalled:)`
returns `true` only when **all three** hold:

1. `flag == true`
2. The pinned native vision runtime is linked and passes its ABI/revision/patch check
3. A complete, verified vision model (main GGUF + projector GGUF) is installed

With `visionInChat` set to `false`, source builds retain the existing attachment behavior.

- Apple `ChatView` keeps the existing paperclip help text
  (`"Attach a text, PDF, or image (images: vision not available yet)"`) and routes image picks to
  `DocumentTextExtractor`, which displays the existing honest rejection notice.
- Android `ChatScreen` has no UI changes; a `TODO` comment marks where `FeatureFlags.visionInChatAvailable`
  will route once verified.
- The separate experimental vision workflow (`VisionView` / `VisionScreen`) remains unchanged.

## What is wired

- **Shared pure flags:** `FeatureFlags.swift` and `FeatureFlags.kt` define `visionInChat = false`
  and `visionInChatAvailable(flag:runtimeAvailable:modelInstalled:)`.
- **Apple `ChatView.swift`:** When `FeatureFlags.visionInChatAvailable(...)` evaluates to `true`:
  - Selecting a still image copies it through `VisionSelectedImage.copy(_:into:)` (same 8 MiB /
    4,096 px / 16 MP PNG/JPEG bounds as `VisionView`).
  - Sending a prompt with the attached image acquires the exclusive `SpecialistInferenceLease`
    (`suspendForSpecialist()`), verifies the installed vision artifacts and checks the live
    memory/disk gate (`VisionModelInstaller.verify` + `VisionModelInstaller.checkResources`), runs
    `VisionInferencePort` / `NativeVisionEngine.answer(...)`, always resumes the specialist lease
    on completion or failure, and appends the turn to the chat transcript.
  - Cancelling stops the task and invokes `VisionInferencePort.cancel()`.
- **Android `ChatScreen.kt`:** Flag and availability helper live in `quenderin-core`; `ChatScreen.kt`
  documents the future routing hook without altering current attachment or send behavior.

## Why it is off

- Full-weight multimodal inference inside the main chat flow has not been verified on physical
  phones or Macs.
- Loading a vision language model + `mmproj` projector while a text chat model is already resident
  carries a real jetsam / OOM risk if lease handoff, memory gating, or teardown misbehaves.
- Enabling image attachments in chat before end-to-end physical validation would violate the
  project rule against advertising unverified inference.

## Required pinned vision runtime

The build under test must link the pinned native vision runtime (`QUENDERIN_VISION_LLAMA`) defined
in `apple/QuenderinKit/Sources/QuenderinKit/VisionEngine.swift`:

- **ABI version:** `1` (`quenderin_vision_runtime_abi() == 1`)
- **Pinned revision:** `e8fd209c975c80aa7fb36a8423571ff3b1b7e955`
- **Pinned patch SHA-256:** `417a4d19ed4e05625cd4bc3ec269bf1a4331e8dd9263956b95e86b6158f938a9`

## Device verification required before flipping the flag

Do **not** set `FeatureFlags.visionInChat = true` until every check below passes on real hardware
and the measurements are recorded in this repository:

### 1. Physical Apple devices (iPhone >= 8 GB RAM and Apple-silicon Mac)

- [ ] Build links the pinned `QUENDERIN_VISION_LLAMA` runtime matching the revision and patch SHA-256 above.
- [ ] Install **MiniCPM-V 4.7 1B** (`MiniCPM-V-4_7-1B-Q4_K_M.gguf` + `mmproj-model-f16.gguf`) and
      confirm SHA-256 verification succeeds for both files.
- [ ] Answer **5 fixed test images** in the main chat composer and confirm accurate content for each:
  1. **Photo** (real-world scene / object identification)
  2. **Screenshot** (UI text and layout comprehension)
  3. **Receipt** (line items and totals extraction)
  4. **Chart** (axes, trend, and key values)
  5. **Handwriting** (legible transcription of handwritten note)
- [ ] Record **peak memory** (Xcode Memory Gauge / Instruments) for each image — confirm zero jetsam kills.
- [ ] Record **time-to-answer** (wall clock from tap Send to complete assistant message) for each image.
- [ ] **Cancel mid-answer:** tap Stop while vision inference is running; confirm generation halts cleanly,
      the UI unlocks, and the previous text model lease resumes cleanly for the next text turn.
- [ ] **Low-memory refusal:** test on a device (or budget) below the 8 GiB available app memory gate;
      confirm the existing refusal message is shown cleanly with no crash.
- [ ] **App quit / background during vision:** force-quit or background the app mid-inference;
      confirm no crash, no native use-after-free, and clean relaunch.

### 2. Physical Android device (Galaxy S23)

- [ ] Build links the pinned Android JNI vision runtime matching the same provenance contract.
- [ ] Install and SHA-256-verify **MiniCPM-V 4.7 1B** (model + `mmproj`).
- [ ] Run the same **5 fixed images** (photo, screenshot, receipt, chart, handwriting) and verify correct answers.
- [ ] Record **peak memory** (no LMK / OOM kill) and **time-to-answer**.
- [ ] Verify **cancel mid-answer**, **low-memory refusal**, and **app background/quit during vision**
      with clean recovery and zero crashes.
- [ ] Wire Android `ChatScreen.kt` through `VisionController` / `VisionEngine` behind `FeatureFlags.visionInChatAvailable`
      and pass full on-device checks before shipping.
