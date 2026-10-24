# Native acceleration: MAX/Mojo and measured automatic selection

Updated 24 October 2026. This extends Quenderin's native inference work; it does
not replace the [Remote Harness/Bot delivery](deepseek-bot-sol-implementation.md).
Store submission remains deferred. The current restriction on local weights,
native builds and simulator/physical-device runs remains in force.

## What the linked posts actually show

- [Chris Lattner's announcement](https://x.com/clattner_llvm/status/2113639627445965251)
  opens the Mojo language and MAX compiler/runtime internals for extension and
  commercial applications. His thread describes kernel fusion, generated kernels
  and hardware abstraction. These are execution-backend capabilities.
- [Apurva Mishra's demonstration](https://x.com/mav3ri3k/status/2113730606215397523)
  reports Bonsai 2 2B at 40 tokens/sec on Snapdragon 8 Elite Gen 5 using Modular.
  The author [identifies a GPU path](https://x.com/mav3ri3k/status/2113833316768002102)
  and says NPU synchronization made that attempt slower. Lattner
  [describes the Android work as a custom addition](https://x.com/clattner_llvm/status/2113819429373194517)
  made before their Qualcomm support release. The reported speed is the author's
  result, not a Quenderin measurement or a guarantee for other devices.

The [26.7 release](https://www.modular.com/blog/26-7) exposes NVIDIA, AMD, Apple
and CPU implementations; it describes other device plugins as upcoming. The
[package requirements](https://max.modular.com/packages/) do not supply a native
Android/iOS application SDK. That does not invalidate the custom Android demo.
The demonstrated port's public source/build recipe has not been located in the
author's public repositories or the inspected Modular tree. Obtain that exact
implementation, or produce a reproducible equivalent adapter, before claiming
Android MAX support.

Public model inputs do exist: [official Bonsai 2 2B GGUF artifacts](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf)
at revision `683f7be2629342a50987627b40881e54761a2430`, with publisher checksums.
Quenderin already catalogs `bonsai2-2b`; adding a duplicate catalog entry would
not add the demonstrated execution path. Match its actual precision, tensor
layout, tokenizer, hybrid architecture and activation transforms to the adapter.

## Current gaps in Quenderin

| Gap | Existing integration point | Required behavior |
| --- | --- | --- |
| Gen 5 previously fell into the unknown-device path | `AndroidSoc.kt`, `GpuOffloadPlanner.kt` | Corrected in this branch; recognition preserves compiled-backend checks. |
| No MAX/Mojo engine adapter | Concrete `LlamaEngine` and native factory/JNI seams | Package a pinned backend with real load/generate/cancel/unload behavior. |
| Model recommendations use estimated speed | `IPhoneModelSelector.swift`, `AndroidModelSelector.kt` | Prefer comparable measured results while preserving memory, disk and workflow gates. |
| Real generation timings reach logs only | Swift `LlamaEngine.runGeneration`, `android/jni/llama_generate.h` | Emit an immutable numeric report from the generation owner. |
| No persisted Automatic mode | Native app composition, onboarding loaders and speed controls | Deliberate opt-in; choose installed eligible models between turns. |
| Android Vulkan is opt-in at build time | Gradle `quenderin.vulkan`, JNI CMake | Detect actual compiled/loadable capabilities; a SoC name cannot create a backend. |

## Implementation order and acceptance criteria

### 1. Correct the demonstrated device's classification

- [x] Recognize Qualcomm's documented SM8850 family and human Gen 5 names before
  the generic 8 Elite match. Preserve older and unknown device behavior.
- [x] Classify its GPU family for the existing Vulkan policy; keep CPU selection
  when Vulkan is absent. Do not advertise NPU support or enable Vulkan globally.
- [x] Reuse the previous Elite generation's conservative estimate explicitly as
  an unmeasured fallback. Never import the video's 40 tokens/sec as app data.
- [x] Test aliases, misleading near-matches, non-Elite names and backend gates.

Delivered scope: `AndroidSoc.kt`, `GpuOffloadPlanner.kt` and 13 focused checks in
`CoreVerify.kt`. The complete pure Kotlin verifier passed all 350 checks. No
weights, inference, device run or native build was used. Vulkan remains an
explicit build option; recognizing a GPU family is not a Gen 5 driver benchmark.
MAX and measured Automatic selection below remain unimplemented.

Grounding: [Qualcomm product page](https://www.qualcomm.com/smartphones/products/8-series/snapdragon-8-elite-gen-5)
lists SM8850 variants. OEM `Build.SOC_MODEL` formatting remains variable.

### 2. Turn existing timings into usable local evidence

- [ ] Add an optional performance callback to each concrete engine and its
  factory. Keep current text-stream interfaces. Capture identity at generation
  start; avoid a shared last-result getter that another agent run can overwrite.
- [ ] Carry actual model-token counts, prefill/decode durations, first-token
  latency and maximum gap, completion/error/cancellation status, context/cache
  conditions, thermal state and the backend actually loaded.
- [ ] Emit only after a successful, uncancelled generation. Partial text is not
  proof of successful native decoding. Never count rendered text chunks as tokens.
- [ ] Store at most 64 recent records locally, with a bounded encoded size and
  atomic replacement. Keep prompts, generated text, paths and account IDs out.
- [ ] Key records by verified model artifact identity, runtime revision, actual
  backend, device/driver signature and comparable context/cache conditions.
  Ignore incompatible, stale, non-finite and undersized samples.
- [ ] Learn during ordinary inference. No automatic download, warm-up sweep,
  provider request or background benchmark is needed to collect a sample.

Existing loaders already receive `ModelEntry`, including artifact identities;
reuse that input and the runtime provenance manifest. Feed reports through
app composition into an injected store. If a protocol getter is chosen instead,
both `CoordinatedInferenceEngine` wrappers must forward it with generation identity.

### 3. Add an explicit Automatic policy

- [ ] Introduce its own preference. Do not silently repurpose `suggestBestModel`,
  which currently controls task-routing suggestions, or overwrite manual choices.
- [ ] Build candidates from installed, verified, executable model/backend pairs.
  An advertised model, benchmark record or backend label is insufficient.
- [ ] Apply memory/context, disk, task-modality, runtime and thermal gates first.
  Within those gates, use comparable observations to evaluate expected response
  latency; retain current estimates for unknown candidates and label them.
- [ ] Switch only between turns through the existing onboarding/model loader,
  preserving unload/cancel ownership and recovery to the prior working model.
  Do not switch a model mid-answer or move a local conversation to a provider.
- [ ] Prefer a stable choice unless measured benefit clears a documented margin;
  expire failure cooldowns and runtime-specific observations deliberately.
- [ ] Show the selected model/backend and whether its speed is observed or
  estimated. Remote Harness/API destinations retain their own execution owners.

The current returning-user path restores the remembered model immediately.
Updating first-install recommendation alone will not implement Automatic mode.
Wire restore, picker/speed controls and new-turn routing through the same policy.

### 4. Integrate the real MAX adapter

- [ ] Pin the Android demo's source, compiler, runtime, device backend, build
  recipe and exact Bonsai artifact. Record a source receipt and all licenses.
- [ ] Verify redistribution and telemetry behavior for the exact components.
  [MAX uses mixed licenses](https://www.modular.com/blog/max-license): some are
  Apache/LLVM and others use the [MAX License](https://raw.githubusercontent.com/modular/modular/main/Licenses/MAX_LICENSE).
  Retain notices and terms; do not assume the whole tree is Apache-2.0.
- [ ] Build a narrow native boundary for load, streaming generation, cancel,
  unload, capability and numeric performance reports. Use existing generation
  leases; bound concurrency, context, token count and allocation failures.
- [ ] Package Android arm64/JNI and exact driver dependencies through the existing
  hosted build route. Verify API levels, ABI, 16 KiB page alignment and release
  packaging. Keep the app functional when the optional backend fails to load.
- [ ] Prove its tokenizer, sampling, stops and multi-turn cache behavior against
  a known baseline; test cancellation, process lifecycle and resource release.
- [ ] Admit MAX to Automatic only after its real compiled capability and model
  load probe pass. Use its measured performance; back off on regression/failure.
- [ ] Develop Apple MAX support as a separate adapter/build/validation milestone.
  Existing Metal support in MAX does not establish an iOS application artifact.

Do not rewrite Modular's compiler or copy a second token pipeline. Reuse its
published extension interfaces and the existing Quenderin ownership/streaming
contract. Host-side MAX serving can later use the existing computer execution
destination, with Host-owned provider configuration; it is separate from mobile
on-device MAX and must be labelled accordingly.

### 5. Verify before enabling or making speed claims

- [ ] Shared policy fixtures: faster/slower measured candidates, stale runtime,
  changed artifact/driver, missing backend, insufficient samples and memory veto.
- [ ] A fake 40-token/sec MAX record cannot enable an absent adapter.
- [ ] Cancelled/failed runs cannot train the policy; numeric storage remains
  bounded and contains no conversation content. Manual mode survives relaunch.
- [ ] Hosted native builds/tests with actual libraries, independent review and
  exact staged secret scans before source publication.
- [ ] Later authorized hardware validation: same model/artifact, prompt/output
  lengths, cache state, context, thermal/power conditions and sampling. Compare
  baseline and MAX latency, throughput, memory and sustained performance.
- [ ] Enable only the verified combinations and retain deterministic fallback.

Under the current native-run restriction, source/fixture/hosted compilation can
advance. Actual phone speed, energy use, driver stability and sustained thermal
behavior remain unverified. Store release follows the existing release checklist.

## Ownership for the next Sol 6.1 implementation

1. Engine worker: immutable reports, concrete Swift/Kotlin engines and JNI sink.
2. Policy worker: bounded store, selection policy, shared fixtures and core tests.
3. Primary integration: Automatic preference, composition, loader/speed controls,
   integrated validation and fresh independent review.
4. Backend worker, after the source receipt exists: MAX adapter and hosted ABI
   packaging. The policy must work with existing engines before MAX is admitted.

Use separate file ownership and preserve concurrent edits. Keep all benchmark
numbers attributable to the exact source, artifact and hardware that produced them.
