# Release & store submission

The signing, build and console path for native app updates. Never add credentials
to this record or create new credential files. Use the established project wrapper
or already-authorized signing configuration. A debug build is not a signed store release.

## Store browser profiles — verified 19 October 2026

| Service | Chrome profile |
|---|---|
| App Store Connect and Xcode Cloud | **Apple Developer** |
| Google Play Console | **Albert - Main - CMax** |

Confirm the profile name and reuse the existing signed-in tab before store work.
Browser and tab IDs change between sessions; do not save an ID as the account
mapping. Do not open Play Console in Apple Developer: that profile's Google
account does not establish access to the registered Play developer. Reuse these
known profiles instead of starting new sign-in or account/terms setup flows.
Store-console access and access to the private Android upload key are separate
prerequisites; a public certificate is not a recovered private key.

## 19 October 2026 — native 0.5.0 preparation

The new release source includes the October model workflows described below.
Version preparation and store publication are separate states.

- **Apple live state refreshed:** iOS and macOS **0.4.0 Ready for Distribution**
  in App Store Connect. The iOS version selects build **19** and has automatic
  release selected. This supersedes the October 16 pending-review snapshot.
- **Next release:** both native Apple targets and Android are prepared as
  **0.5.0**. Xcode Cloud reports next build **20**. The active existing workflow
  archives iOS and universal macOS only, with `QUENDERIN_RUNTIME=prism`; its
  automatic trigger still targets the old Bonsai branch. A manual-only start
  condition now permits exactly `codex/native-050-20261019`; select that branch
  explicitly for this update. The included Cloud plan is 25 hours, with
  4h03 used and 20h57 available in the current period; no plan change was made.
- **Apple drafts:** iOS and macOS **0.5.0 Prepare for Submission** were created
  with updated description, release notes and review notes. Automatic release
  after approval is selected on both. No 0.5.0 build has been selected or submitted.
- **Google Play live state:** highest uploaded code **2 (0.2.0)** remains at
  100% on **Closed testing – Alpha**. There are seven opted-in testers and
  production access is not enabled. Candidate code **5** is available; preserve
  the existing closed-test track.
- **Android signing:** the canonical `android/keystore.properties` is absent,
  and the repository has no signing secrets. The existing registered upload
  key is required; no replacement key or reset is implied by release preparation.
- **Validation scope:** source/fixture checks and hosted compilation only. The
  user's exclusion of local weights, simulators and physical-device runs remains
  in effect. No 0.5.0 signed archive, store submission or public availability is
  established by this preparation record.

The Android backup rules now exclude approved memories as well as conversations
from legacy backup, cloud backup and device transfer. Host fixtures fail if any
approved-memory exclusion is removed. Apple system backups remain controlled by
the user; the privacy policy distinguishes them from app-provided cloud sync.
The localization generators retain unmanaged Android resources and are checked
against repeated generation.

The Mac source preserves its existing quit-on-last-window-close lifecycle and
prior native teardown remedy. Settings-only/window recovery in a signed candidate
has not been rendered under this update’s explicit no-device-run constraint.

## October 18 source candidate — not a store release

[PR 163](https://github.com/alikatgh/quenderin/pull/163) expands the shared text
catalog to **28 entries** in TypeScript, Swift and Kotlin. The candidate includes
the runtime, complete-artifact installation and publisher chat adapters for Beam
and Muse on native Apple, Android and desktop. Beam requires all four parts
(**133,885,310,500 bytes**) and a 160 GiB whole-model memory floor; context and
working buffers may need more. Muse requires all 22 parts (**304,080,474,208
bytes**). A small metadata entry point is never treated as a complete model.

Dedicated app workflows now cover these additional releases:

- **Still-image questions:** managed model/projector pairs for MiniCPM-V 4.7 1B,
  MiniCPM-V 4.7 35B-A3B and Nemotron 3.5 Super VL 120B-A12B, with respective
  8/32/96 GiB available-memory floors. Native and desktop clients accept one
  bounded JPEG/PNG; video, audio and tools are unavailable.
- **Hy-Memory proposals:** separate native and desktop installation and inference,
  using the pinned community conversion, official no-thinking prompt and strict
  JSON validation. Only explicitly selected proposals enter a private approved
  memory store. No automatic conversation hook or generic chat path is enabled.
- **Granite Switch 4.1 8B:** an offline converter verifies the official checkpoint
  already on disk and creates a new GGUF plus conversion receipt. Native and
  desktop import/chat adapters verify that pair before loading. The receipt is
  conversion evidence, not a publisher signature or inference result. Speech,
  decision and guardian modes are not enabled.
- **Step 5 Preview:** native and desktop text clients connect, after explicit
  consent, to the user's existing CUDA host through the pinned official backend
  and Quenderin gateway. This is a remote specialist, not on-phone inference or
  automatic server provisioning.
- **Images:** isolated FLUX 3 Image Klein and MOSS Image Base/SFT workflows use
  three complete component presets and a 24 GiB available-memory floor. Gated
  FLUX files require the user's publisher access and license decision. Native
  import/install and desktop prepared-folder verification are explicit actions.

Nemotron Bolt E4B remains unavailable because no exact public artifact has been
verified. See [the model integration record](bonsai-2.md) for pinned sources,
resource limits, conversion commands and workflow boundaries.

Ordinary and specialist engines share an exclusive resource lease. The app
joins ordinary work and unloads idle text weights before measuring memory for a
specialist; selection and conversation state are preserved. Process-exit cleanup
closes admission, cancels and joins native workers and child processes, then
disposes the shared backend. Per-service cleanup does not free another workflow's
backend.

The image build uses a separate patched-GGML DSO. Desktop builds seal and probe
its CLI/resources and test both text/image library load orders. Android statically
links its private C++ runtime, seals stripped DSOs, preserves those bytes through
AGP, and checks final APK/AAB hashes, dependency closure and 16 KiB alignment.
Apple’s final signed-export gate now also checks the image framework payload,
platform/architectures, linkage, distribution signature and embedded image catalog.

Earlier partial verification used source `8a18dff844825440ea63a61691f2a77903cba8f1`.
[Hosted CI 39096103001](https://github.com/alikatgh/quenderin/actions/runs/39096103001)
passed Linux’s real pinned image build/probe, both Node test/build jobs, Kotlin
core, JNI syntax and the existing iOS SDK compile. It exposed a Swift 6 global-page
size concurrency error, experimental website fallback recommendation and a Beam
fixture variable-scope error that were subsequently corrected. It predates the
complete workflows above and is not evidence for the final candidate. Independent
reviews and targeted host fixtures cover source provenance, prompt protocols,
multipart installation, private storage, resource bounds, cancellation and cleanup.

**Final engineering verification passed** at revision
[`1d5f4452b0dd096fdaab737bc4581562f3bce666`](https://github.com/alikatgh/quenderin/commit/1d5f4452b0dd096fdaab737bc4581562f3bce666).
[CI 39106905620](https://github.com/alikatgh/quenderin/actions/runs/39106905620)
completed successfully with **all 18 jobs passing**. The separate
[catalog URL check 39106905664](https://github.com/alikatgh/quenderin/actions/runs/39106905664)
also passed on that exact revision.

- **Apple:** the actual iOS and universal macOS Prism frameworks, linked vision
  bridge, Swift tests and iOS SDK app compilation passed.
- **Android:** the actual Prism JNI app built a debug APK and an **unsigned**
  release AAB. Both packages passed image-library identity, dependency-closure
  and 16 KiB alignment checks; Kotlin core and native runtime/memory-guard tests
  passed.
- **Desktop:** Linux and Windows passed packaged ASAR addon probes and packaged
  image/vision runtime verification. The macOS Electron lab package passed its
  image and vision runtime proofs; it is separate from the native Mac App Store
  product. Independent image-runtime build jobs passed on all three host systems.
- **Windows private storage:** actual protected-DACL approval-store tests and
  positive/negative synthetic ACL policy fixtures passed on the Windows runner.

No local weights, simulator runs or physical-device runs are authorized for this
update. Full-weight inference, image quality, measured memory/speed and native
rendered UI and ARMv7 support remain unverified. The existing hosted Bonsai CPU
generation check does not validate full-weight inference for the new models.
No new 0.5.0 archive, signing, store submission or public app availability has
been established. The dated October 16 store record below is historical; the
October 19 refresh above supersedes its pending-review status.
Windows/Linux desktop packages and their distribution channels remain separate
from the native Apple and Android store releases.

## Verified release memory — 16 October 2026

This is the reusable project release record, recovered from the repository's
July release history and the live store consoles. Refresh dated state before
reusing it; build success, signing, submission and availability are separate.

- Apple app **6789854363**, bundle `ai.quenderin.Quenderin`, signing team
  `9M2B2P4KSA`. Both iOS and macOS **0.4.0 (19)** are **Waiting for Review**.
  Both submissions retain **Automatically release this version** and immediate
  release to all users after approval. **0.3.0 (15)** remains the public version;
  submission is not approval or public availability.
  - [iOS submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/58d4e201-3d64-4c88-a76f-d2762d80757d), submitted 16 October at 13:48 Asia/Ulaanbaatar.
  - [macOS submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/fb941b2e-296d-407f-b5b1-73c1d19bb308), submitted 16 October.
- Xcode Cloud team `f68608a6-96f8-4330-b123-b99c104eec71`, product
  `4F96019F-D3C2-4ECE-AA57-12D901AC24A3`, existing workflow **Bonsai 2 App Store**.
  Workflow ID: `76741952-1095-40B7-AA3D-9DA19B3682F2`. It is enabled, starts on
  pushes to `codex/bonsai2-27b-20261012`, and automatically cancels superseded
  builds. It has only iOS/macOS Archive actions, with no simulator/device actions.
  Latest successful build is **19**; both signed-export verifiers confirmed
  version 0.4.0, build 19 and the pinned Prism revision. Cloud build ID:
  `6e352c62-20dc-49ea-bb09-a21a47f3eb8d`. Source:
  `2c1bf547846c0565f97477ff0b967b46735deecc`, merged in
  [PR 161](https://github.com/alikatgh/quenderin/pull/161) as
  `d5b5dcb91bff011137ae355ed57a6dab7147303f`. Use a later counter for another
  archive and recheck the live value. At task start the included 25-hour plan
  showed 3h 13m used / 21h 47m available, resetting October 28; subsequent builds
  consumed part of that allowance. No paid upgrade was made.
- [Play Console](https://play.google.com/console/u/0/developers/6289191549337108258/app/4976280765138921912/releases/overview):
  developer `6289191549337108258`, app `4976280765138921912`, package
  **ai.quenderin.app**. Highest observed bundle is **2 (0.2.0)**, active on
  Closed testing → Alpha, track `4700414835984777148`. Candidate 0.4.0 uses code 4.
- Android's established build loads **`android/keystore.properties`** (root of
  the Gradle project). That file and its referenced private upload key are
  machine-local and gitignored. Git history confirms the July signed release;
  it does **not** contain the private key. No repository signing secrets were
  configured when checked on 16 October.
- [Registered upload certificate](https://play.google.com/console/u/0/developers/6289191549337108258/app/4976280765138921912/keymanagement)
  SHA-256: `8B:38:F4:E5:85:88:3A:B7:37:F2:91:8F:49:90:BA:40:17:67:A0:39:37:EB:2A:68:72:88:BD:E3:E9:49:CF:3D`.
  Match this **upload** fingerprint before signing; Play's app-signing certificate
  is different. The matching private key was not found on this Mac after checking
  project/standard signing paths, available session records, keychain metadata
  and a focused connected Drive search. Android 0.4.0 **compiled successfully**
  as an APK and unsigned release AAB in hosted CI; it was **not uploaded to Play**.
  Do not claim that recovering the public fingerprint recovered the private key.
- An earlier App Store Connect banner mentioned an updated Paid Applications
  Schedule, but both 0.4.0 submissions were accepted without a new agreement
  action. No legal terms were accepted in this task. Recheck any future blocker
  rather than assuming the earlier banner prevents submission.

[CI 38856241939](https://github.com/alikatgh/quenderin/actions/runs/38856241939)
passed all 13 jobs on the exact archived source. This includes tiny synthetic
Muse CPU decode and save/reload, bounded Bonsai generation on the hosted runner,
576 Apple runtime tests (9 skips), 574 standard Swift tests (6 skips), Android
packaging, Windows/Linux native-addon and packaged-app checks, and catalog and
source-provenance checks. Catalog URL liveness and independent engineering/UI
review also passed. Do not submit build 18: it predates the Muse graph fix.

The [engineering article](https://quenderin.org/blog-muse-engineering),
[model update](https://quenderin.org/blog-bonsai-small-muse-spark) and
[changelog](https://quenderin.org/changelog) are live. Static Worker publication
`cfa3e413-b0a8-438d-8550-033d76b798e9` preserved the existing Worker code and
settings. The expanded dynamic model-release feed is committed source only;
it was not activated. No Cloudflare deployment secret was configured in GitHub.

The October 16 task explicitly excludes local model downloads, simulators and
physical-device runs. Host fixture checks and hosted compilation are permitted;
full-weight Muse inference and native UI/device behavior remain unverified. Do not
present old screenshot or inference evidence as validation of the 0.4.0 candidate.

| Product | Public channel | Owner guide |
|---|---|---|
| **macOS** (native Swift) | **Mac App Store only** (free) | [MAC_APP_STORE.md](MAC_APP_STORE.md) |
| **iOS** | App Store | § iOS below + [STORE_SUBMISSION.md](STORE_SUBMISSION.md) |
| **Android** | Google Play | § Android below |
| **Windows** | Microsoft Store **+** GitHub `.exe` | [MICROSOFT_STORE.md](MICROSOFT_STORE.md) |
| **Linux** | GitHub AppImage/deb (+ Flathub later) | [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md) |

---

## Android (Google Play)

### 1. Reuse the existing upload keystore
Use the existing private upload key matching the fingerprint above. A new key
cannot sign an update until Google's separate upload-key reset process completes.
Do not generate a replacement as a workaround for a missing local configuration.
Inspect public certificate metadata with `keytool -list -v -keystore /path/to/key`;
enter passwords interactively, never in committed commands or task output.

### 2. Point the build at it — WITHOUT committing secrets
The established build reads the human-managed `android/keystore.properties`
(gitignored, together with `*.jks` and `*.keystore`). Restore the existing secure
signing setup; do not print, copy or create credential contents in an agent
session. A path or existing signing-job name is enough to locate the setup.
`app/build.gradle.kts` loads it and signs the **release** build automatically. With no file present,
release still *builds* (unsigned) — so CI and contributors are never blocked.

### 3. Build the release bundle
Use the pinned, patched Prism runtime, including the compiled Muse ABI. A stock
checkout or mock engine is not this release. First check disk headroom; hosted CI
is preferable when this Mac cannot fit native build output.

```sh
python3 scripts/prepare_prism_runtime.py fetch --destination /absolute/new/prism-source
ANDROID_NDK_HOME="$ANDROID_HOME/ndk/26.3.11579264" \
  bash scripts/build_android_diffusion.sh /absolute/new/android-diffusion
cd android
./gradlew :app:bundleRelease --no-daemon --console=plain \
  -Pquenderin.runtime=prism -Pquenderin.llamaDir=/absolute/new/prism-source \
  -Pquenderin.diffusionLibDir=/absolute/new/android-diffusion/jniLibs
cd ..
python3 scripts/verify_diffusion_android_package.py \
  --libraries /absolute/new/android-diffusion/jniLibs \
  --package android/app/build/outputs/bundle/release/app-release.aab
```

Output: `android/app/build/outputs/bundle/release/app-release.aab`. Without the
existing signing properties this is **unsigned**. Check with `jarsigner -verify`
and `keytool -printcert -jarfile` and match the registered upload fingerprint.
The CI Android job compiles the release bundle and actual native runtime without
credentials; this does not upload a Play release. API 36, AGP 8.10.1 and Gradle 8.11.1
are the 0.4.0 build configuration. Keep the existing 16 KB native linker alignment.
[Current target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878)
require API 36 for updates after 31 August 2026.

### 4. Play Console (your account)
- Open the existing `ai.quenderin.app` record and upload the signed `.aab` to an
  existing Alpha track. For this task, do not launch a device or simulator;
  report that runtime validation has not been performed.
- **Data safety form:** review against the public privacy policy. Network activity includes
  user-selected Hugging Face downloads, optional model search, and public release metadata
  from quenderin.org when model selection is opened. Those catalog/download
  requests carry no chats or files. In versions with the optional Step 5 workflow,
  an approved request sends its prompt and selected conversation to the user's
  configured CUDA host. Review the actual destination and consent behavior
  separately; a local-chat disclosure alone does not describe this workflow.
  Declare the **`dataSync`** foreground-service type used for model downloads.
- **Content rating (IARC):** file **Mature 17+** — an unrestricted local LLM can emit mature text.
- **Privacy policy URL:** `https://quenderin.org/privacy` (already hosted + in-app).
- Promote only after device validation and the console's production-access gates
  pass. The September record of 7 opted-in testers is historical, not current
  proof of production eligibility; check the current Dashboard before promotion.

---

## iOS (App Store)

### 1. Prepare the committed project

```sh
xcodegen generate --spec apple/QuenderinApp/project.yml
python3 scripts/generate_muse_artifacts.py --check
python3 scripts/check_catalog_parity.py
```

Commit both `project.yml` and the generated Xcode project when versions change.
Cloud regenerates and rejects project drift.

Both XcodeGen plist templates must use `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)`. Changing the build settings alone does not override
a hardcoded plist version: Cloud build 17 exported 0.3.0 despite the 0.4.0 build
setting. The signed-export verifier now requires the version and minimum build
declared by both targets in `project.yml`, while allowing Cloud's higher counter.

### 2. Use the existing Xcode Cloud workflow
Open [Quenderin Xcode Cloud](https://appstoreconnect.apple.com/teams/f68608a6-96f8-4330-b123-b99c104eec71/xcode-cloud/products/4F96019F-D3C2-4ECE-AA57-12D901AC24A3/groups).
Reuse **Bonsai 2 App Store**, explicit `QUENDERIN_RUNTIME=prism`, and its iOS
`Quenderin` / macOS `QuenderinMac` App Store Archive actions. Select the reviewed
pushed commit and record its full SHA. The post-clone hook builds the pinned
framework before package resolution; post-build hooks verify the signed exports,
source patch, compiled capability, catalog, versions and distribution-team signature.
A green build and completed App Store Connect preparation are required before
selecting that exact build in each platform's version. TestFlight distribution
is optional. For each submission select **Automatically release this version**.

### 3. App Store Connect (your account)
- **Privacy policy URL:** `https://quenderin.org/privacy` (paste into App Information).
- **Apple Standard EULA:** opt in (App Information → one click; "Submit for Review" stays grey otherwise).
- **Age rating:** **17+** (mature local-LLM output).
- **App Review notes (Guideline 4.2):** explain the ordinary device-sized models and optional large models, "be on Wi-Fi," and
  that onboarding *is* the first-use experience by design (it's not an empty app).
- **App privacy:** "Data Not Collected."

---

## What stays out of git (and why)

`keystore.properties`, `*.jks`, `*.keystore`, `*.p12` are gitignored. The Android signing key and the
iOS distribution certs are the two things that, if leaked, let someone ship a malicious update under
your identity — they belong in your password manager / Apple's keychain, never the repo. Everything the
build needs to *find* them is an absolute path in the gitignored properties file.

---

## Cross-references
- `docs/SHIP_READINESS.md` — the full "needs you" ledger (questionnaires, accounts, the closed items).
- `docs/DEVICE_VERIFICATION.md` — capture the real tok/s (incl. the CPU-vs-GPU A/B) before listing.
- `android/INTEGRATION.md` — the native build + GPU/Vulkan opt-in.
