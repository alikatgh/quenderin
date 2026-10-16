# Release & store submission

The signing, build and console path for native app updates. Credentials belong in
gitignored files or the platform keychain. A debug build is not a signed store release.

## Verified release memory — 16 October 2026

This is the reusable project release record, recovered from the repository's
July release history and the live store consoles. Refresh dated state before
reusing it; build success, signing, submission and availability are separate.

- Apple app **6789854363**, bundle `ai.quenderin.Quenderin`, signing team
  `9M2B2P4KSA`. Both iOS and macOS **0.3.0 (15)** are Ready for Distribution.
- Xcode Cloud team `f68608a6-96f8-4330-b123-b99c104eec71`, product
  `4F96019F-D3C2-4ECE-AA57-12D901AC24A3`, existing workflow **Bonsai 2 App Store**.
  Workflow ID: `76741952-1095-40B7-AA3D-9DA19B3682F2`. It is enabled, starts on
  pushes to `codex/bonsai2-27b-20261012`, and automatically cancels superseded
  builds. It has only iOS/macOS Archive actions, with no simulator/device actions.
  Latest successful build is 15. The native 0.4.0 candidate starts at build 16;
  verify Cloud's counter before starting it. The included 25-hour plan showed
  3h 13m used / 21h 47m available, resetting October 28. No paid upgrade is needed.
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
  project/standard signing paths, available session records and keychain metadata.
  Do not claim that recovering the public fingerprint recovered the private key.
- App Store Connect displayed an updated Paid Applications Schedule requiring
  Account Holder acceptance before updates. Review its current state before
  submission; never silently accept a new legal agreement.

The October 16 task explicitly excludes local model downloads, simulators and
physical-device runs. Host fixture checks and hosted compilation are permitted;
actual Muse inference and native UI/device behavior remain unverified. Do not
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
