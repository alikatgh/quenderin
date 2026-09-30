# Release & store submission

The signing, build and console path for native app updates. Credentials belong in
gitignored files or the platform keychain. A debug build is not a signed store release.

> Before you submit, capture real on-device numbers (`docs/DEVICE_VERIFICATION.md`) — the store
> listing and the default-model copy should reflect measured tok/s, not estimates.

**30 September 2026 update:** Mac and iPhone are available on the App Store.
Android remains in closed testing: the console's latest release is `0.2.0` (code 2).
Source currently carries Android `0.2.1` (code 3), iOS `0.2.0` (build 3), and
Mac `0.2.0` (build 10). Verify the highest Apple uploads before assigning the next
build numbers. Latest-model discovery and bounded prompt cancellation are source
changes awaiting signed releases; use the update notes in `STORE_LISTING.md`.

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
For this published package, use the key registered in Play Console. Generating a
new key does not authorize an update; a replacement needs Google's upload-key
reset process. The following command is only for a new app's initial registration:
```sh
keytool -genkey -v -keystore upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias quenderin
# Keep upload.jks + its passwords somewhere safe (a password manager). If you lose it you can ask
# Google to reset the UPLOAD key (Play App Signing holds the real signing key), but don't rely on that.
```

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
Add the real-inference native lib first (otherwise it ships the mock):
```sh
git submodule add https://github.com/ggml-org/llama.cpp android/jni/llama.cpp   # once
cd android
./gradlew :app:bundleRelease        # → app/build/outputs/bundle/release/app-release.aab
```
Optional APK-size shrink: flip `isMinifyEnabled = true` in `app/build.gradle.kts` and test on a
device — the JNI keep rules R8 needs are already in `app/proguard-rules.pro`.

### 4. Play Console (your account)
- Open the existing `ai.quenderin.app` record and upload the signed `.aab` to an
  appropriate testing track first; install and smoke-test it on a physical phone.
- **Data safety form:** review against the public privacy policy. Network activity includes
  user-selected Hugging Face downloads, optional model search, and public release metadata
  from quenderin.org when model selection is opened. These requests carry no chats or files.
  Declare the **`dataSync`** foreground-service type used for model downloads.
- **Content rating (IARC):** file **Mature 17+** — an unrestricted local LLM can emit mature text.
- **Privacy policy URL:** `https://quenderin.org/privacy` (already hosted + in-app).
- Promote only after device validation and the console's production-access gates
  pass. This account currently needs 12 opted-in closed testers for 14 days; the
  console shows 7 opted in, so production access is not yet available.

---

## iOS (App Store)

### 1. Build the real-inference framework + project
```sh
apple/build-xcframework.sh                       # ~20–60 min first run → llama.xcframework
cd apple/QuenderinApp && xcodegen generate        # project.yml → Quenderin.xcodeproj
open Quenderin.xcodeproj
```

### 2. Sign + archive (your Apple Developer account)
- Target → *Signing & Capabilities* → pick your Team (automatic signing is fine).
- **GUI:** *Product → Archive* → *Distribute App → App Store Connect*.
- **CLI / CI (reproducible):** fill `YOUR_TEAM_ID` in `apple/QuenderinApp/ExportOptions.plist`, then:
  ```sh
  cd apple/QuenderinApp
  xcodebuild -project Quenderin.xcodeproj -scheme Quenderin -configuration Release \
    -archivePath build/Quenderin.xcarchive archive
  xcodebuild -exportArchive -archivePath build/Quenderin.xcarchive \
    -exportOptionsPlist ExportOptions.plist -exportPath build/export
  # upload: xcrun altool / notarytool, or Transporter, with an App Store Connect API key
  ```
Signing certs/profiles stay in your keychain — nothing secret lives in this repo (the Team ID isn't a secret).

### 3. App Store Connect (your account)
- **Privacy policy URL:** `https://quenderin.org/privacy` (paste into App Information).
- **Apple Standard EULA:** opt in (App Information → one click; "Submit for Review" stays grey otherwise).
- **Age rating:** **17+** (mature local-LLM output).
- **App Review notes (Guideline 4.2):** state the 0.4–9 GB model download range, "be on Wi-Fi," and
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
