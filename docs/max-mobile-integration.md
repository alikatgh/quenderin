# Mobile MAX/Bonsai integration status

Updated 25 October 2026. This records the mobile half of the
[MAX acceleration work](modular-acceleration-plan.md). It separates the
portable adapter boundary that now exists from the mobile vendor runtime that
has not been integrated.

**Current status: not integrated, not validated on a phone, store submission
deferred.** No model weights were downloaded, no MAX SDK was installed locally,
and no device or simulator was run for this increment.

## What is actually true

| Layer | State | Evidence |
| --- | --- | --- |
| MAX CPU tensor bridge | Foundation merged | [PR #185](https://github.com/alikatgh/quenderin/pull/185), real SDK run [40174916756](https://github.com/alikatgh/quenderin/actions/runs/40174916756) |
| Portable model-adapter boundary | Source + host fixture | `native/max-runtime/{include,src}/quenderin_max_model.*`, `native/max-runtime/tools/test_model_adapter.py` |
| Android arm64 / iOS SDK compile probes | Compile-only CI gates; inspect the exact candidate's checks | `native/max-runtime/android-check`, `native-remote-sdk.yml` steps |
| Mobile audit receipt | Recorded and gated | `native/max-runtime/mobile-lock.json`, `tools/check_mobile_lock.py` |
| Android MAX runtime | Blocked | Pinned MAX 26.7 source has zero Android/Adreno/Qualcomm/Dragonfly paths |
| Bonsai MEF/tokenizer/cache contract | Blocked | Only the official GGUF is pinned; no reviewed MEF or mapping exists |
| Apple iOS MAX artifact | Blocked | MAX's Apple target is Apple Silicon macOS; no iOS application artifact |
| Phone speed, memory, thermals, rendered UI | Unverified | Standing restriction forbids device and simulator runs |
| Store submission | Deferred | — |

The demonstrated Android result (Bonsai 2B at a reported 40 tokens/sec on a
Snapdragon 8 Elite Gen 5) is an author-reported social post. Modular states that
plugins for other chips, including Qualcomm Dragonfly, are planned "in the
coming months". The pinned source tree contains none of them, and no public
source/build recipe for the demo was located. It is not a Quenderin measurement
or a supported configuration.

## The adapter boundary

`quenderin_max_model.h` defines a narrow contract:

- **Receipt** — one to eight app-owned files with exact byte sizes and SHA-256
  values, an exact runner ABI, a compiled backend identity and bounded context
  and output budgets.
- **Runner** — supplied by a separately built backend. It owns tokenization,
  sampling, model semantics and KV-cache behavior. It returns one token piece
  at a time and must not copy transcripts into diagnostics.
- **Adapter** — always hashes the regular app-private files before opening
  them; requires MAX telemetry and crash-reporting opt-outs; enforces a
  single-flight lease; reassembles UTF-8 split across token pieces (invalid,
  overlong, surrogate and truncated sequences become U+FFFD); bounds prompt,
  output, stream and context bytes; observes cancellation at token boundaries;
  and emits numeric-only performance data.
- **Capability** — reports `available` only when the static contract, the
  telemetry opt-outs and a real load probe all pass. Passing
  `load_probe_passed = 1` without a probe is explicitly not done by this module,
  so Automatic cannot admit MAX from a label or a benchmark record.

The adapter has no vendor dependency. The fake runner and smoke fixture exercise
verification failures, symlink rejection, mandatory hashing, telemetry opt-outs,
runner open failure, streaming, split and malformed UTF-8, cancellation, sink
abort, runner failure, oversized pieces, output and stream caps, context
clamping, invalid requests, zero-token tokenization, close-during-generation,
single-flight under contention and cleanup.

Residual time-of-check/time-of-use gap: MAX opens the artifact path itself, so a
writer with access to the model directory can replace bytes between the adapter's
final hash and the vendor open. Receipts therefore require app-private storage;
never stage these files in shared or user-writable external storage. The adapter
cannot close this gap without a vendor API that accepts an already-open
descriptor.

```sh
python3 -B native/max-runtime/tools/test_model_adapter.py --work "$HOME/quenderin-max-scratch"
python3 -B -m unittest discover -s native/max-runtime/tests -p 'test_*.py'
python3 -B native/max-runtime/tools/check_mobile_lock.py
```

The compile/run check uses an inert runner double and sanitizers. The author of
the original source increment (`fb1bcb7`) recorded a local Darwin arm64 pass with
Apple clang and ASan/UBSan on 25 October 2026. Subsequent candidates require their
own hosted results: the [MAX workflow](https://github.com/alikatgh/quenderin/actions/workflows/max-runtime.yml)
runs the C fixture under ASan/UBSan; the
[native SDK workflow](https://github.com/alikatgh/quenderin/actions/workflows/native-remote-sdk.yml)
contains the Android arm64 build and iOS SDK syntax probes. Check the exact PR
head revision and retain its run links in the PR validation record. These checks
establish host fixture execution and compile compatibility, not MAX execution
or a distributable mobile runtime.

## Why mobile MAX is still blocked

1. **No public mobile backend.** The pinned source revision
   `527d069ee11a41ac5320af1f9402db0a66b2b868` (26.7.0) has 13,588 paths and none
   match Android, Adreno, Qualcomm, Hexagon, QNN or Dragonfly. The official blog
   defers those plugins. The demo's custom port is not public.
2. **No Bonsai MEF contract.** The official
   `prism-ml/Ternary-Bonsai-2-2B-gguf` file is pinned
   (`683f7be2629342a50987627b40881e54761a2430`, 429,183,456 bytes, SHA-256
   `36061ad4…`), but a MEF conversion, weight mapping, tokenizer contract,
   sampling/stops and multi-turn cache behavior are all missing. Matching the
   PTQ1_0/Hadamard layout is not optional.
3. **Licensing and telemetry are unresolved for mobile.** Published 26.7.0
   wheels declare `LicenseRef-MAX-Platform-Software-License`; the inspected SDK
   embeds the August 18, 2026 Community License with the same SHA-256 recorded
   for the pinned source license. That metadata label does not establish
   different terms. Mobile redistribution still needs review of the exact
   components, third-party notices and distribution requirements. MAX usage data is
   described as collected by default, so opt-outs must be proven in the actual
   mobile artifact.
4. **No iOS artifact.** MAX supports Apple Silicon through Metal on macOS. That
   does not create an iOS framework, signing identity or app-store-safe binary.
   The pinned C API compiles a MEF at runtime, so an ahead-of-time path and the
   platform's executable-memory rules must be resolved before this can be an app
   target.
5. **No phone evidence.** Inference speed, memory, driver stability, sustained
   thermals, battery and rendered UI require the device runs the project has
   explicitly deferred.

## Phone validation protocol (not run)

The standing restriction forbids simulator and physical-device runs, so this is
a protocol, not a result. When device work is authorized, compare the exact
pinned Bonsai 2B artifact against the existing llama.cpp/Prism baseline on the
same device, build mode and thermal starting point:

1. **Devices** — one current iPhone (A18-class) and one Android phone with the
   demonstrated Snapdragon family or an 8 Elite predecessor. Record model, OS,
   RAM, free storage, driver and thermal state.
2. **Conditions** — fresh install, 2,048- and 4,096-token contexts, cold cache
   and warm multi-turn cache, prompt buckets (32 and 512 tokens), output caps
   (128 and 512 tokens), fixed sampler settings and the same prompt set.
3. **Metrics** — time to first token, prefill and decode tokens/sec, worst
   inter-token gap, peak resident memory, thermal state and battery delta over
   five sustained minutes, cancellation latency at a token boundary, and crash/
   recovery behavior.
4. **UI** — rendered capture of onboarding, picker, chat, cancellation, settings
   and error states at the supported font sizes and both themes; frame pacing
   during streaming (Xcode Instruments / Android Studio) rather than a
   screenshot-only check.
5. **Acceptance** — no model answer before the load probe passes; no claim of a
   speed win without a same-condition baseline; no regression that hides the
   non-MAX path; cancellation stops within one token; memory stays inside the
   existing fitness gate; no unreviewed network or telemetry traffic.
6. **Recording** — fill the table below with device, build, artifact hashes,
   commands and raw numbers. Do not copy the author's 40 tokens/sec.

| Device / build | Artifact | Context / cache | TTFT | Prefill | Decode | Peak RSS | Thermal / battery | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| _not run_ | — | — | — | — | — | — | — | — |

No row in this section is filled or implied by the host fixture. The existing
[device verification](DEVICE_VERIFICATION.md) and
[mobile performance](MOBILE_PERFORMANCE_101.md) guides cover the capture
workflow.

## What a future integration must provide

- A pinned, reproducible Android backend (official Qualcomm plugin or an
  independently produced equivalent) with source receipt, compiler profile,
  driver dependencies and exact Bonsai artifact identity.
- A runner implementing `QMaxModelRunner` with real tokenization, sampling,
  stops, cache reuse and cancellation, plus a load/generate probe.
- Android arm64 JNI packaging that preserves API levels, 16 KiB page alignment
  and graceful fallback when the optional backend fails to load.
- A separate Apple milestone with an actual iOS artifact and license review.
- Device validation: same model/artifact, prompt and output lengths, cache
  state, context, thermal/power conditions and sampling; baseline versus MAX
  latency, throughput, memory and sustained performance.
- Only then: admission to Automatic and any store/availability claim.

Until those exist, the app must not offer MAX for Bonsai, and no speed claim may
cite the social post as a Quenderin result.
