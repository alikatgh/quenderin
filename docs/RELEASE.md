# Release & store submission

The one playbook for shipping the native apps. The **code** is software-complete (see
`docs/SHIP_READINESS.md`); this is the signing + build + console path that needs *your* accounts,
keystore, and a physical-device sanity check. Nothing here is committed-secret — credentials live in
gitignored files.

> Before you submit, capture real on-device numbers (`docs/DEVICE_VERIFICATION.md`) — the store
> listing and the default-model copy should reflect measured tok/s, not estimates.

---

## Android (Google Play)

### 1. Make an upload keystore (once)
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
- Create the app → upload the `.aab` to **internal testing** first (install on your S23, smoke-test).
- **Data safety form:** "No data collected / No data shared" — accurate; the only egress is the
  user-initiated HuggingFace model GET. Declare the **`dataSync`** foreground-service type.
- **Content rating (IARC):** file **Mature 17+** — an unrestricted local LLM can emit mature text.
- **Privacy policy URL:** `https://quenderin.org/privacy` (already hosted + in-app).
- Promote internal → production when the smoke-test passes.

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
