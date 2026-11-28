# Mac App Store — step-by-step (native macOS app)

**Owner decision (2026-07):** the **public macOS product** is the **native Swift** app
(`apple/QuenderinApp` → target **QuenderinMac**), distributed **only through the Mac App Store**.
It is **free** (Apple’s 30% is irrelevant for a free listing). Goal: branding + legitimacy
(users trust “Get” on the App Store), not Electron DMG downloads.

| Channel | What | Public? |
|---|---|---|
| **Mac App Store** | Native `QuenderinMac` (SwiftUI + QuenderinKit + llama.xcframework) | **Yes — only public Mac channel** |
| Electron `.dmg` | Lab / R&D (`npm run electron:build:mac`) | **No** — do not link on the website |
| GitHub Releases | Windows + Linux installers only | Yes (desktop-release workflow) |

iOS uses the same bundle id / universal-style identity where configured:
`ai.quenderin.Quenderin`. Version **0.2.0** (build **2**).

Last updated: 2026-07-09

---

## 0. Prerequisites (you)

- [ ] **Apple Developer Program** membership (you indicated you have a license).
- [ ] Mac with recent **Xcode** (15+ recommended).
- [ ] App Store Connect access for the same team.
- [ ] Privacy URL live: **https://quenderin.org/privacy**
- [ ] Support email: **quenderin@aulenor.com**

---

## 1. Build the inference framework (once per machine / when llama.cpp updates)

```sh
# from repo root — first run is long
./apple/build-xcframework.sh
# → produces llama.xcframework used by QuenderinKit
```

See `apple/QuenderinApp/INTEGRATION.md` if the path layout differs on your machine.

---

## 2. Generate the Xcode project

```sh
brew install xcodegen   # once
cd apple/QuenderinApp
xcodegen generate
open Quenderin.xcodeproj
```

Targets:

- **Quenderin** — iOS  
- **QuenderinMac** — macOS (sandbox + hardened runtime already in `project.yml`)

Version is set to **0.2.0** / build **2** in:

- `Info-macOS.plist` / `Info.plist`
- `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`)

Bump both together for every Store submission.

---

## 3. Signing (Xcode)

1. Select target **QuenderinMac**.
2. **Signing & Capabilities** → Team = your Apple Developer team.
3. Confirm **App Sandbox** + **Outgoing Connections (Client)** (entitlements file
   `Quenderin-macOS.entitlements`).
4. Bundle ID: **`ai.quenderin.Quenderin`** (must match App Store Connect record).

For CLI export, copy `ExportOptions.plist` and set `teamID` to your 10-character Team ID
(Membership details — not a secret). Method is already `app-store-connect`.

---

## 4. App Store Connect — create the Mac app (once)

1. [App Store Connect](https://appstoreconnect.apple.com) → **My Apps** → **+**.
2. Platform: **macOS** (you can also add iOS to the same app record if you want a universal
   listing later; keep bundle id consistent).
3. Name: **Quenderin**, primary language, SKU of your choice, bundle id
   `ai.quenderin.Quenderin`.
4. **Pricing:** Free.
5. **Privacy Policy URL:** `https://quenderin.org/privacy`.
6. **Category:** Productivity (matches `LSApplicationCategoryType`).
7. **Age rating:** **17+** — unrestricted local LLM output (same as iOS guidance).
8. **Encryption** — Local chat works offline after model setup. The optional **My computer**
   connection uses a separate path and protects remote session payloads with bundled Snow
   and Noise IK (X25519, ChaCha20-Poly1305 and SHA-256) outside Apple's OS crypto. The final
   App Store Connect encryption declaration and France filing or exemption determination
   remain pending with Albert for the selected build.
   [Export compliance checklist](EXPORT_COMPLIANCE.md) · [Issue #217](https://github.com/alikatgh/quenderin/issues/217)

---

## 5. Archive and upload

### GUI

1. Scheme **QuenderinMac** → **Any Mac** (or My Mac with “Release”).
2. **Product → Archive**.
3. Organizer → **Distribute App → App Store Connect → Upload**.

### CLI (reproducible)

```sh
cd apple/QuenderinApp
# fill YOUR_TEAM_ID in ExportOptions.plist first
xcodebuild -project Quenderin.xcodeproj -scheme QuenderinMac -configuration Release \
  -archivePath build/QuenderinMac.xcarchive archive
xcodebuild -exportArchive -archivePath build/QuenderinMac.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
# then upload via Transporter or:
# xcrun altool / notarytool / App Store Connect API key
```

---

## 6. Listing copy (accuracy)

The **native Mac app** provides offline local chat after model setup, local agent
capabilities that compile into the sandboxed Mac app, and optional online connections.
Do **not** paste Electron desktop “drive any app / BlueStacks” claims if those
capabilities are not in the MAS sandbox build.

Use [STORE_LISTING.md](STORE_LISTING.md) as the base; strip any desktop-only automation
claims that require full-disk Accessibility outside the sandbox.

Screenshots: Mac window of chat + model library, dark UI preferred for brand consistency.

---

## 7. Review notes (paste into ASC)

Suggested notes for App Review:

```
To review local chat, download a small open GGUF model from Hugging Face over Wi-Fi.
Once the model is installed, local chat works offline without an account.

My computer is an optional online connection to a trusted computer through a configured
Remote Harness server. It uses an existing server account and keeps remote sessions
separate from local chat. DeepSeek and Step 5 are separate optional online connections.

Generative AI disclosure: responses are produced by an on-device model and may be wrong.
In-app disclaimer + Report affordance are included.

The sandbox allows outbound connections for model downloads and optional online features.
No tracking SDKs.
```

---

## 8. Submit for Review

1. Select the uploaded build.
2. Complete **App Privacy** using the selected build's data flows.
   [Store submission checklist](STORE_SUBMISSION.md#3-privacy-label-recommendations-and-unresolved-answers)
3. **Add for Review** → **Submit**.

After approval, the Mac app is available **only** via the App Store — do not publish a
competing notarized DMG of the same product on the website.

---

## 9. Website / GitHub alignment

- [download.html](../website/download.html): macOS section points to **App Store** (or
  “coming soon” until live), **not** Electron DMG.
- GitHub Releases: Windows + Linux only (`desktop-release.yml`).
- Electron mac builds: keep for developers (`electron:build:mac`); label lab-only in README.

---

## 10. Checklist

- [ ] xcframework built
- [ ] xcodegen → QuenderinMac signs with your Team
- [ ] Version 0.2.0 (2) matches ASC
- [ ] Free price + privacy URL
- [ ] Age 17+
- [ ] Screenshots
- [ ] Review notes
- [ ] Submitted
- [ ] Website macOS = App Store only

---

## Related

- [RELEASE.md](RELEASE.md) — shared signing notes (iOS section overlaps)
- [SHIP_READINESS.md](SHIP_READINESS.md) — software vs owner gates
- [MICROSOFT_STORE.md](MICROSOFT_STORE.md) — Windows dual channel (Store + GitHub exe)
- [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md) — Electron on Win/Linux only
