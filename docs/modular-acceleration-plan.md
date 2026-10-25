# Native acceleration: MAX/Mojo and measured automatic selection

Updated 25 October 2026. This extends Quenderin's native inference work; it does
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
| Model recommendations previously used estimated speed only | Native `InferencePerformance` policy and existing model selectors | Comparable observations can inform the first ordinary reply of a new conversation; retain eligibility and quality gates. |
| Real generation timings previously reached logs only | Swift `LlamaEngine.runGeneration`, `android/jni/llama_generate.h` | Source now emits an immutable numeric report after a successful ordinary generation. |
| Automatic mode was absent | Native app composition, onboarding loaders and speed controls | Source now has deliberate opt-in and persisted manual choices; hosted verification is tracked below. |
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
The MAX tensor bridge and Automatic implementation are described below. Mobile
MAX inference remains a separate, incomplete milestone.

Grounding: [Qualcomm product page](https://www.qualcomm.com/smartphones/products/8-series/snapdragon-8-elite-gen-5)
lists SM8850 variants. OEM `Build.SOC_MODEL` formatting remains variable.

### 2. Turn existing timings into usable local evidence

- [x] Add an optional performance callback to each concrete engine and its
  factory. Keep current text-stream interfaces. Capture identity at generation
  start; avoid a shared last-result getter that another agent run can overwrite.
- [x] Carry actual model-token counts, prefill/decode durations, first-token
  latency and maximum gap, completion/error/cancellation status, context/cache
  conditions, thermal state and the backend actually loaded.
- [x] Emit only after a successful, uncancelled generation. Partial text is not
  proof of successful native decoding. Never count rendered text chunks as tokens.
- [x] Store at most 64 recent records locally, with a bounded encoded size and
  atomic replacement. Keep prompts, generated text, paths and account IDs out.
- [x] Key records by verified model artifact identity, runtime revision, actual
  backend, device/driver signature and comparable context/cache conditions.
  Ignore incompatible, stale, non-finite and undersized samples.
- [x] Learn during ordinary inference. No automatic download, warm-up sweep,
  provider request or background benchmark is needed to collect a sample.

Reports use the already verified artifact receipt, registered runtime and
nonunique hardware/OS/execution signature. A source-derived runtime fingerprint
invalidates observations when the inference implementation changes. The store
holds at most 128 KiB, expires records after 30 days, and contains no transcript,
file path or account identity. Agent, grammar and specialist calls do not train
ordinary-chat selection. Android Vulkan observations are ineligible until an
exact usable driver identity is available; manual Vulkan behavior is preserved.

### 3. Add an explicit Automatic policy

- [x] Introduce its own preference. Do not silently repurpose `suggestBestModel`,
  which currently controls task-routing suggestions, or overwrite manual choices.
- [x] Build candidates from installed, verified, executable model/backend pairs.
  An advertised model, benchmark record or backend label is insufficient.
- [x] Apply memory/context, disk, task-modality, runtime and thermal gates first.
  Within those gates, use comparable observations to evaluate expected response
  latency; retain current estimates for unknown candidates and label them.
- [x] Switch only between turns through the existing onboarding/model loader,
  preserving unload/cancel ownership and recovery to the prior working model.
  Do not switch a model mid-answer or move a local conversation to a provider.
- [x] Prefer a stable choice unless measured benefit clears a documented margin;
  expire failure cooldowns and runtime-specific observations deliberately.
- [x] Show the selected model/backend and whether its speed is observed or
  estimated. Remote Harness/API destinations retain their own execution owners.

Automatic defaults off. When enabled, the first admitted ordinary inference of a
new conversation can choose an installed text model. That conversation then
retains its model; guided computer tasks do not consume its first ordinary turn.
Explicit Automatic pins are distinct from older descriptive model metadata.
Manual model or speed choices disable Automatic and persist across relaunch.

Three distinct comparable observations are required. Comparison uses exact
artifact/runtime/backend/environment/effective context, the same prompt-size
bucket, nominal thermal state and the expected cache mode. A retained model's
prefix reuse is compared with a freshly loaded alternative's cold observations,
never pooled. Predicted prefill plus decode latency includes switch/load cost;
an alternative must improve the prediction by at least 20 percent. Unknown
evidence preserves a viable current model. One lazy alternative integrity check
and one switch attempt are permitted per new conversation, with one prior-model
recovery and a ten-minute failure cooldown. No model sweep is started.

The actual target template/tokenizer, available context and response budget are
checked while the existing execution owner exclusively holds the engine. A
switch cannot race an ordinary turn, specialist task or agent approval. Drafts,
attachments and history must survive preparation and model restoration. The
shared [contract](../shared/inference-performance-contract.json) and
[24 policy fixtures](../shared/inference-performance-fixtures.json) define the
cross-platform numeric behavior; platform lifecycle regressions test admission,
manual intent, rollback and conversation changes separately.

### 4. Integrate the real MAX adapter

Completed foundation: [PR #185](https://github.com/alikatgh/quenderin/pull/185)
adds a real MAX C API tensor-session boundary, pinned C headers, explicit
ownership and bounded failures. Its hosted fake-C-API tests compile the actual
bridge and exercise cleanup/failure paths under sanitizers. The manual hosted
SDK workflow separately inspects exact wheel bytes and their embedded terms
before installation can be allowed. The successful
[SDK audit](https://github.com/alikatgh/quenderin/actions/runs/40099566447)
verified selected-wheel PEP 658 metadata and the actual `libmax.so`. Five Modular
wheels lack separate embedded terms; the execution gate requires explicit
per-package coverage of the inspected SDK terms and third-party notices before
any installation or execution. The guarded CPU projection's
[first actual attempt](https://github.com/alikatgh/quenderin/actions/runs/40104752084)
passed installation, file/loader absence checks and SDK import. Graph compilation
then failed because the deliberately omitted `shmem.mojoc` is required even for
the CPU graph. Its upstream Linux build links NVIDIA device bitcode into that
module. Restoring the packaged module would invalidate the omission argument.
The replacement profile pins nine Apache/LLVM source files and rebuilds the module
with the upstream precompile recipe without GPU bitcode. In
[attempt 40108358239](https://github.com/alikatgh/quenderin/actions/runs/40108358239),
that source build and real SDK CPU graph compilation/export passed. Native C
initialization then exposed a missing SDK resource root. The fixture now supplies
the same explicit package root as Modular's pinned official launcher, with an
ambient-override regression test.

[Actual SDK run 40174916756](https://github.com/alikatgh/quenderin/actions/runs/40174916756)
passed at `dfa3db7494be35706608a285b7ce298d3013826a`: source precompile, graph
export and real C execution succeeded. Three executions returned `[2, 6, 12, 20]`;
wrong shapes and stop-before-execution were rejected. All 35 Python guards and
the injected C lifecycle/sanitizer suite passed. Runtime was offline and
unprivileged with telemetry disabled; the forbidden payload/loader checks and
hosted cleanup passed. Exact lock/profile/output receipts and reproduction
commands are in the [bridge README](../native/max-runtime/README.md).

This completes the real CPU tensor-bridge foundation. It does not establish
mobile packaging, Bonsai generation, phone inference, or a speed improvement.

The mobile increment adds a portable adapter boundary and a fail-closed source
receipt. Details and the blocked matrix are in
[Mobile MAX/Bonsai integration status](max-mobile-integration.md).

- [x] Define a vendor-neutral model receipt/runner boundary with verified files,
  exact sizes and SHA-256 values, telemetry opt-outs, single-flight generation,
  bounded prompt/output/context/stream budgets, UTF-8 streaming, cancellation,
  capability probing and numeric performance reports.
- [x] Record the mobile audit outcome against pinned source `527d069e…` and the
  pinned Bonsai 2B GGUF; reject unverified support, MEF and phone-performance
  claims in a checked lock.
- [x] Exercise the boundary on a host with an inert runner double, including
  failure injection and sanitizers. No vendor runtime was loaded.

This boundary accepts an exported float32 graph or a vendor runner. It does not
load GGUF, tokenize chat itself, implement autoregressive decoding, package an
Android/iOS runtime, or make MAX an eligible Automatic candidate. Those
remaining tasks stay unchecked:

- [ ] Pin the Android demo's source, compiler, runtime, device backend, build
  recipe and exact Bonsai artifact. **Blocked:** no public demonstration source
  or build recipe was located, and the pinned 26.7 tree has no mobile backend
  in the recorded audit. Record a source receipt and all licenses when one exists.
- [ ] Verify redistribution and telemetry behavior for the exact components.
  The wheels declare `LicenseRef-MAX-Platform-Software-License`; the inspected
  SDK embeds the same Community License hash recorded for the pinned source.
  Exact mobile component terms, notices and redistribution remain unreviewed.
  MAX usage data is described as collected by default.
  [MAX uses mixed licenses](https://www.modular.com/blog/max-license): some are
  Apache/LLVM and others use the community/platform terms. Retain notices and
  terms; do not assume the whole tree is Apache-2.0.
- [ ] Implement a real mobile runner behind the new boundary (load, streaming
  generation, cancel, unload, capability and numeric performance reports) using
  the existing generation leases; bound concurrency, context, token count and
  allocation failures.
- [ ] Package Android arm64/JNI and exact driver dependencies through the existing
  hosted build route. Verify API levels, ABI, 16 KiB page alignment and release
  packaging. Keep the app functional when the optional backend fails to load.
- [ ] Prove its tokenizer, sampling, stops and multi-turn cache behavior against
  a known baseline; test cancellation, process lifecycle and resource release.
- [ ] Admit MAX to Automatic only after its real compiled capability and model
  load probe pass. Use its measured performance; back off on regression/failure.
- [ ] Develop Apple MAX support as a separate adapter/build/validation milestone.
  **Added:** a hosted probe compiles the portable boundary against the iOS SDK
  as a per-candidate CI gate. An actual iOS artifact, ahead-of-time compilation
  path and license review remain.
  Existing Metal support in MAX does not establish an iOS application artifact.

Do not rewrite Modular's compiler or copy a second token pipeline. Reuse its
published extension interfaces and the existing Quenderin ownership/streaming
contract. Host-side MAX serving can later use the existing computer execution
destination, with Host-owned provider configuration; it is separate from mobile
on-device MAX and must be labelled accordingly.

### 5. Verify before enabling or making speed claims

- [x] Shared policy fixtures: faster/slower measured candidates, stale runtime,
  changed artifact/driver, missing backend, insufficient samples and memory veto.
- [x] A fake 40-token/sec MAX record cannot enable an absent adapter.
- [x] Cancelled/failed runs cannot train the policy; numeric storage remains
  bounded and contains no conversation content. Manual mode survives relaunch.
- [x] Hosted native builds/tests with actual libraries, independent review and
  exact staged secret scans before source publication.
- [ ] Later authorized hardware validation: same model/artifact, prompt/output
  lengths, cache state, context, thermal/power conditions and sampling. Compare
  baseline and MAX latency, throughput, memory and sustained performance.
- [x] Keep MAX unavailable to Automatic; retain the existing runtime gates and
  deterministic fallback until a complete model adapter is verified.

Under the current native-run restriction, source/fixture/hosted compilation can
advance. Actual phone speed, energy use, driver stability and sustained thermal
behavior remain unverified. Store release follows the existing release checklist.

## Implementation boundaries

1. Engine worker: immutable reports, concrete Swift/Kotlin engines and JNI sink.
2. Policy worker: bounded store, selection policy, shared fixtures and core tests.
3. Primary integration: Automatic preference, composition, loader/speed controls,
   integrated validation and fresh independent review.
4. Backend worker, after a public mobile backend receipt exists: MAX adapter and
   hosted ABI packaging. The policy must work with existing engines before MAX is
   admitted.

Use separate file ownership and preserve concurrent edits. Keep all benchmark
numbers attributable to the exact source, artifact and hardware that produced them.

## Verification and reproduction

Run the lightweight source gates from the repository root:

```sh
python3 -B scripts/generate_inference_performance_identity.py --check
python3 -B -m unittest scripts.tests.test_inference_performance_contract
python3 -B scripts/check_inference_performance.py
python3 -B -m unittest discover -s native/max-runtime/tests -p 'test_*.py'
python3 -B native/max-runtime/tools/check_source.py
python3 -B native/max-runtime/tools/check_mobile_lock.py
python3 -B native/max-runtime/tools/test_model_adapter.py --work "$HOME/quenderin-max-scratch"
```

The model-adapter fixture compiles the portable boundary with an inert runner
double under sanitizers. It is host compilation only: no MAX SDK, weights,
network, simulator or device is used.

After intentionally editing any runtime-fingerprint input, run the generator
without `--check` and commit both generated native identity files. Do not hand
edit their hashes. CI requires each platform to emit each of the 24 policy
fixture markers exactly once; a marker inventory alone is not execution proof.

`.github/workflows/ci.yml` runs the pure Kotlin controller and actual shared JNI
generation-loop fixture. `.github/workflows/native-remote-sdk.yml` runs Swift
controller tests and compiles the real native app/library targets with their
existing SDK integrations. These hosted checks do not run a phone model or
establish rendered interaction, signed release behavior or sustained speed.
Follow [the MAX bridge instructions](../native/max-runtime/README.md) for its
separate metadata audit and gated CPU fixture. Never treat a fake API fixture as
actual SDK execution or the CPU graph as a mobile LLM benchmark.

Automatic was delivered through [PR #186](https://github.com/alikatgh/quenderin/pull/186)
at main revision `c089da2e5437713a863459a809db846bdc84118e`. Its tree exactly matched
tested head `eecfa6ef889b0ef0524e7754b2ff83fcacd5f7f2`:

- [CI 40103248277](https://github.com/alikatgh/quenderin/actions/runs/40103248277):
  all 18 jobs passed; 763 Swift tests, six skipped, zero failures. Swift and Kotlin
  each executed all 24 shared policy fixtures exactly once. The actual JNI
  generation-loop fixture and existing core/regression checks passed.
- [Native SDK/app linking 40103248222](https://github.com/alikatgh/quenderin/actions/runs/40103248222):
  Apple and Android passed with their actual SDKs. Apple compiled unsigned
  iPhone, simulator-SDK and Mac targets; these were compilation checks, not UI runs.
- Fresh independent reviews covered admission, manual intent, conversation
  changes, cancellation, context overflow, recovery and draft preservation.
  Both exact staged-blob secret scans passed before publication.

Store submission remains deferred. Phone rendering, signed native interaction and
sustained model speed remain unverified; no provider, relay or inference service
is activated by this increment. The separate MAX SDK attempt above is not a
successful native graph execution, mobile adapter or Bonsai benchmark.
