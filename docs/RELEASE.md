# Release & store submission

The signing, build and console path for native app updates. Never add credentials
to this record or create new credential files. Use the established project wrapper
or already-authorized signing configuration. A debug build is not a signed store release.

## Android upload-key reset and recovery — 2 November 2026

The user explicitly approved the Google Play upload-key reset to certificate
`880aca180c193bcbd670f1afddc2b0e15e95f755771805e470aa5e75384f8b6f`.
Its public certificate was reverified on November 2. The reset form is prepared
with reason **Other**; no new certificate upload, Google request receipt or
activation has yet been verified. The browser credential-change policy reserves
the certificate entry and final Request action for the user. Do not change the
release signer's accepted fingerprint until Google activation is confirmed.

The canonical signing identity is outside Git, at
`/Users/s_avelova/QuenderinSigning/upload-keystore.p12`. Its public certificate is
`/Users/s_avelova/QuenderinSigning/upload_certificate.pem`; the existing encrypted
credential loader is
`/Users/s_avelova/QuenderinSigningCredentials/signing.schema`. Both directories
are mode 0700 and their files mode 0600. A nonsecret `README.txt` beside the
keystore records this identity and its status. These are retained signing
assets, never disposable build output. Preserve their exact paths and do not
regenerate or replace them. The separate `8f45bb0c…c863d1b` identity remains an
unregistered historical replacement, not this approved identity or the original.

The user also requested durable recovery. An encrypted off-Mac backup is being
arranged; the destination decision is pending. **Independent recovery is not yet
complete.** Varlock's current credential protection is device-bound, and the
existing age SSH identity's off-Mac recovery has not been established. A copied
schema or an archive encrypted only to a Mac-only identity does not prove that
the keystore can be recovered after losing this Mac. Preserve an independent
credential recovery route and verify an actual restore before marking backup
complete. Private keys and passwords must never enter this document or Git.

A portable recovery helper is now prepared at
`.worktrees/native-final-integration-20261029/tools/android-release/backup-with-prompts.zsh`.
It uses pinned Varlock 1.23.0 and installed age 1.3.2, encrypting the existing
PKCS12 together with its actual alias/passwords in a memory-only archive. Its
private Terminal prompts collect an independent archive passphrase; preserve
that passphrase separately. Output goes to `~/QuenderinSigningBackups/` with
exclusive 0600 files, followed by authenticated decryption and a restored-key
signing check. The production helper has **not yet been run**. All **22
synthetic checks passed**, including actual age/JDK operations and real
Varlock/helper/age process cleanup after SIGTERM/SIGKILL. Independent security
review passed after the supervision fixes. This validates the helper, not an
actual production backup or off-Mac copy. Run it only in the human's own private
interactive Terminal; never enter its passphrase in chat.

## Live release checkpoint — 2 November 2026

### November 5: Apple status refreshed; no new submission

Native Chrome access briefly recovered. The live Apple Developer app grid still
shows **iOS 0.6.0 Ready for Distribution** and **macOS 0.6.0 Prepare for
Submission**. The Mac build association and rollout controls were not refreshed
in this attempt; build34 remains the last verified selection. The scoped browser
host is still unavailable. After a full fresh accessibility snapshot, Chrome
changed to another profile during the new-tab action; native input was stopped
and released without further navigation, a Cloud run or a submission.

The user reiterated release authorization. A specific exception to submit Mac
build34 with its UI journey unverified is pending; the earlier automatic review
blocked Add for Review on that missing check. The separate Cloud UI plan remains
prepared, not run by this session. Its worktree is clean at `37598755cdb01fa7c77afbf2a941340a54995577`.
The Cloud execution spend gate is **BLOCKED**: current shared remaining usage,
queued/in-flight work, worst-case compute and provider prevention of extra
charges have not been verified. The November 3 quota is historical. No plan,
billing or quota setting was changed, and no paid exception was inferred.

Android's approved upload-key reset still requires the human certificate-entry
and final Request steps, followed by Google's receipt and activation time.
Those steps were requested again as a credential handoff, not a new reset
permission request. No Google activation or new Android upload is established.

Android preparation advanced without another build: the existing successful
[export run 40812571419](https://github.com/alikatgh/quenderin/actions/runs/40812571419)
provided the unsigned 0.6.0 / code6 bundle. Its 36,395,913 bytes and SHA-256
`dcaebfa878bab1e45405489766faf4b3dcc2a824fa200fe0d92c28c2645b9519`, source
receipt and checksum were downloaded and verified. Existing ZIP/unsigned,
runtime/Noise/JNA receipt checks passed. Pinned official Google bundletool
verified the actual packaged `ai.quenderin.app` / 0.6.0 / 6 manifest, and its
temporary JAR was removed. App source `0ad249d` and latest Apple source `a6f6454`
have identical Android tree `689ad9815d366a0379569a845b7baa7f4acedc48`.
The selected unsigned candidate and small receipts are retained at
`outputs/release-060-20261030/android-candidate-0ad249d/` for signing/upload after
verified Google key activation. No signing credentials were loaded or signing
attempted; this is not an upload-ready or published bundle. Remove its local
unsigned copy when superseded or after Play acceptance and retained final
signed-artifact provenance.

### November 3: Cloud UI isolation prepared, not run

The user reaffirmed the Cloud UI route; no local-test fallback or UI-check
exception is approved. A separate nondefault plan, **Quenderin-macOS-UI-Cloud**,
now contains only the existing serial `QuenderinMacCloudUITests` target, with
all original assertions, mock options and 300-second limits. The original
combined plan remains unchanged and default. Four configuration files were
generated reproducibly with XcodeGen 2.45.4, independently reviewed with no
findings, secret-scanned and pushed to
[`codex/mac-cloud-ui-isolation-20261103`](https://github.com/alikatgh/quenderin/tree/codex/mac-cloud-ui-isolation-20261103),
commit `37598755cdb01fa7c77afbf2a941340a54995577`, based on archived source `a6f6454`.
App code, UI assertions, Release build settings, resources, signing and archive
actions are unchanged. This tests a session-interference hypothesis; it is not
a proven fix for the managed-host lock.

Live team usage showed **24h 39m used / 21m available of 25h**, resetting
November 28 at 16:02 local. No paid plan change was made. The intended next run
is **one manual Mac Test action only**, selecting only the new plan on this
exact branch/SHA, one clean Mac destination, no repetitions or automatic
retries, no post-actions and no repeat Archive. Refresh shared quota before
starting; keep the original workflow intact. **No Cloud workflow mutation or
new test run has occurred.**

Codex's browser access host remains unavailable despite the user's restored
Apple Developer window and a REPL reset. Native Chrome was attempted in an
exclusive coordinated slot, but its foreground window changed; input was
stopped and released. One PDF tab was accidentally closed, automated undo was
rejected under target uncertainty, and the user was told how to reopen it.
Original PDF metadata remains present. An unrelated session screenshot was
removed and is not quota proof. Do not repeat foreground actions under stale
window assumptions. The Mac draft remains build34, not submitted.

Source/evidence: `.worktrees/mac-cloud-ui-isolation-20261103` (no native build
output) and `outputs/release-060-20261030/cloud-ui-isolation-20261103/evidence.json`.
The two ignored XcodeGen scratch files were removed (1,915 bytes).

### Earlier November 3 submission attempt

November 3 refresh: the Mac draft still contains **0.6.0 (34)** with compliance
cleared and automatic immediate release after approval selected. Remote `main`
is still the archived `a6f6454fef670edac1f4500b9d60d7a5d6b74723`. GitHub now
also confirms Cloud34's archive Success and Mac Test Action Required. An attempt
to **Add for Review** was rejected by automatic approval review because the
required Mac UI journey remains blocked; no review package or submission was
created. The user was asked for the specific one-submission exception: submit
build34 accepting the unverified Mac UI journey, or wait for successful Mac UI
validation. The earlier local-fallback choice has not been approved and should
not be treated as the only route. Local prebuilt-product compatibility is still
unknown; available disk at this refresh was only 765,571,072 bytes, so a local
test-product allocation has not been started. Preserve existing user files.

- **iOS 0.6.0 (33) is Ready for Distribution**, verified in live App Store
  Connect on November 2. It was submitted November 1 at 17:42
  Asia/Ulaanbaatar. [Submission receipt](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/93b2adc4-81bc-426e-9e26-3a4d2cdb47d2).
  Automatic release after approval and immediate release to all users are saved.
  The selected build is from `a6f6454fef670edac1f4500b9d60d7a5d6b74723`.
  Cloud33 iOS tests passed; all 14 retained journey screenshots were reviewed.
  The UI journey uses a Debug fixture; this does not establish full-weight
  inference or physical-device performance.
- **macOS 0.6.0 (34) is selected in the draft, not submitted.** Both Cloud33 signed
  archives passed. Five Mac hosted tests passed, but the UI journey could not
  activate the app. The exact Mac result's 1-second and 60-second recording
  frames both show Apple's managed host at its password lock screen. No app
  startup defect has been established. Apple documents that XCUITest cannot
  operate in a locked Mac session. A support report is prepared; sending it
  awaits permission. Do not weaken tests, change app startup speculatively or
  repeat the same run without a supported recovery step.
  A separate manual Mac-only recovery workflow, `Quenderin macOS 0.6 recovery`
  (`53607d3e-f5cb-4369-bf71-9d471b651855`), is now saved with stable Xcode
  27.1 (27A9275) and the offered macOS 27.2 RC (26B118) host. It preserves the
  required Mac test plan, one Mac destination and signed App Store archive,
  uses only manual starts on `main`, and has no distribution post-actions.
  Independent configuration/source review found no defects; this is a single
  changed-image recovery experiment, not an established fix for the locked
  host. Cloud build **34** (`226b233c-c28d-492e-b6ef-83b124b1a3d2`) was
  started once at 14:59 local on November 2 on exact source
  `a6f6454fef670edac1f4500b9d60d7a5d6b74723`. Its signed Mac archive passed;
  five hosted tests passed and the UI launch failed again. Exact result
  metadata confirms the newer 27.2/26B118 virtual machine; recording frames at
  1s and 60s both show its password lock screen. The image change did not
  resolve the provider blocker. No app startup change or further blind retry
  was made. A bounded local fallback was proposed and awaits the user's
  explicit choice under the project instructions; installed local tools are
  Xcode 26.3 / macOS 15.6, so prebuilt-test compatibility must be checked first.
  The updated Apple support report is prepared but unsent. Included team capacity was verified
  as 25 hours, 11h 37m used and 13h 23m available, resetting November 28 at
  16:02 local. No plan or paid capacity was changed.
  Build 34 (`f5f2e511-c2dc-4fe5-a04b-03763a655a81`) is now attached to the
  Mac draft; its standard-encryption/France-No answers are saved and Missing
  Compliance is cleared. Automatic approval release and immediate rollout
  remain selected. The initial automated rejection of the draft's Delete
  control was resolved by checking Apple's official procedure: removing a
  build from an unsubmitted version retains it in the account. The build
  chooser confirmed build 33 remains available; no uploaded build was deleted.
- **France is excluded temporarily at the user's direction.** On November 2,
  App Store Connect shows 174 available countries and France as the sole
  **Not Available** country. A separate storefront download was not checked.
  Both build33 encryption answers
  declare bundled standard encryption in addition to Apple's OS encryption,
  with no France distribution. [France follow-up #217](https://github.com/alikatgh/quenderin/issues/217)
  remains open.
- **Android 0.6.0 (6) is not uploaded.** The existing closed Alpha still has
  0.2.0 (2). Data safety submission3 is Published; that receipt covers the
  questionnaire only. The registered upload certificate remains `8b38f4e5…949cf3d`.
  The original private key's location/password remains unresolved, not proven
  lost. Replacement `880aca18…84f8b6f` successfully signed and verified a tiny
  synthetic JAR through the existing encrypted Varlock loader. It is not the
  registered upload key. The user explicitly authorized its reset on November
  2; the human certificate-entry/Request steps, Google receipt and activation
  remain pending. No accepted-fingerprint change has been made.

Selected proof, artifact hashes, exact IDs and remaining gates are in
`outputs/release-060-20261030/verification.json`, `cloud33-ios/`,
`cloud33-macos/` and `cloud34-macos/`. Disposable downloaded ZIPs, extracted results and recordings
were removed after selected evidence was retained. Refresh live state before
resuming; the older dated sections below are historical.

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
No new archive, signing, store submission or public
app availability has been established. The dated October 16 store record below is
historical until refreshed in the consoles. Keep its pending reviews intact.
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
Create `android/keystore.properties` (already gitignored — `keystore.properties`, `*.jks`, `*.keystore`):
```properties
storeFile=/absolute/path/to/upload.jks
storePassword=••••••
keyAlias=quenderin
keyPassword=••••••
```
`app/build.gradle.kts` loads this and signs the **release** build automatically. With no file present,
release still *builds* (unsigned) — so CI and contributors are never blocked.

### 3. Build the release bundle
Use the pinned, patched Prism runtime, including the compiled Muse ABI. A stock
checkout or mock engine is not this release. First check disk headroom; hosted CI
is preferable when this Mac cannot fit native build output.

```sh
python3 scripts/prepare_prism_runtime.py fetch --destination /absolute/new/prism-source
cd android
./gradlew :app:bundleRelease --no-daemon --console=plain \
  -Pquenderin.runtime=prism -Pquenderin.llamaDir=/absolute/new/prism-source
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
  from quenderin.org when model selection is opened. These requests carry no chats or files.
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
