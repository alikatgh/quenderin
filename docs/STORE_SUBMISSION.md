# Store submission checklist (App Store + Play Store)

The apps build, run, and do real on-device inference. Shipping them is the last mile — and it
**requires your accounts and identity**, which is why it can't be automated from this repo:

- **Apple Developer Program** — $99/yr (required to ship to the App Store / TestFlight).
- **Google Play Console** — $25 one-time.

Quenderin's offline, on-device design makes the privacy paperwork the *easy* path on both
stores — lean into it. The one real prerequisite to create first is the **legal pages**.

---

## 0. Do this first — legal pages (both stores require them)

There are **no in-app or hosted privacy/terms pages yet.** Both stores reject without a
**privacy policy URL**; the App Store also needs a terms/EULA (or uses Apple's standard EULA).

The good news: the honest policy is short, because the app collects nothing.
- **What to state:** inference runs entirely on-device; no account; no analytics/telemetry; the
  *only* network call is downloading the model you choose, fetched directly from Hugging Face
  over your own connection (no user data is sent to us — we have no servers).
- **Where to host:** the parked GitHub Pages site (STATUS.md item 3 — needs the `workflow`
  token scope granted to enable the Pages deploy), or any static URL. Link it in both store
  listings and from an in-app "About / Privacy" row.

---

## 1. iOS — App Store

**Identifiers:** bundle prefix is `ai.quenderin` (`apple/QuenderinApp/project.yml`); pick the
full id (e.g. `ai.quenderin.app`) and register it in your Developer account.

- [ ] Paid Apple Developer Program active; signing Team selected on the app target.
- [ ] Ship the real engine: run `apple/build-xcframework.sh` so the archive links llama.cpp
      (Metal) — verify a **Release** build/run on a device first (see `DEVICE_VERIFICATION.md`).
- [ ] App Store Connect → new app record (name, primary language, bundle id, SKU).
- [ ] **Privacy "Nutrition Labels" → "Data Not Collected."** True here, and a real
      differentiator — say it loudly in the description. (Caveat for accuracy: the model
      *download* is a network request to Hugging Face; it transmits no user data, so the
      "not collected" answer stands.)
- [ ] **Export compliance:** uses only standard OS crypto (HTTPS + SHA-256 integrity checks)
      → typically exempt; answer the encryption questions accordingly (set
      `ITSAppUsesNonExemptEncryption = false` in Info.plist to skip the per-build prompt).
- [ ] Screenshots: 6.7" + 6.5" (+ 5.5" if you support older) and iPad sizes if Universal.
- [ ] **App Review notes** — reviewers need context for an on-device LLM: "Inference is fully
      on-device. On first launch the app downloads a model (~0.4–9 GB) from Hugging Face over
      Wi-Fi — please be on Wi-Fi. No account or login. No data leaves the device." Call out the
      autonomous device-control / agent feature and its safety gating so review isn't surprised.
- [ ] TestFlight build first (internal → external) before production submit.

## 2. Android — Play Store

**Identifier:** `applicationId = "ai.quenderin.app"` (`android/app/build.gradle.kts`).

- [ ] Play Console account; **Play App Signing** enabled (upload key + Google-managed app key).
- [ ] Ship the real engine: `android/jni/llama.cpp` present so `libquenderin_llama.so` is
      bundled; build an **app bundle**: `./gradlew :app:bundleRelease` (verify on a device first).
- [ ] **`targetSdk` is current** — Play requires within ~1 year of the latest Android. Confirm
      `targetSdk` in `android/app/build.gradle.kts` meets the current floor before upload.
- [ ] **Data safety form → "No data collected / No data shared."** Matches reality. (Same
      caveat: the model download is a network fetch from Hugging Face carrying no user data.)
- [ ] If the model download uses a **foreground service** (WorkManager long download), declare
      the foreground-service type + justify it in the listing.
- [ ] Content rating questionnaire; store listing (short/full description, feature graphic,
      phone screenshots).
- [ ] Roll out via tracks: **internal testing → closed → production.**

---

## 3. Shared assets to produce once

- [ ] App icon (all required sizes) — iOS asset catalog + Android adaptive icon.
- [ ] Screenshots from a real device (reuse the `DEVICE_VERIFICATION.md` run).
- [ ] Store copy. Lead with the differentiators that are *true*: **fully offline, on-device,
      no account, no data collected**, your choice of 11 open models.
- [ ] Privacy policy + terms URLs (section 0) linked in both listings and in-app.

> Accuracy note for both privacy forms: "we collect nothing" is correct — there is no backend.
> The only egress is the user-initiated model download straight from Hugging Face. Describe it
> plainly rather than over-claiming "no network," which the agent/computer-use features and the
> download would contradict.
