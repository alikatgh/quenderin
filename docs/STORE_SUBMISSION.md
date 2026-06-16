# Store submission checklist (App Store + Play Store)

The apps build, run, and do real on-device inference. Shipping them is the last mile — and it
**requires your accounts and identity**, which is why it can't be automated from this repo:

- **Apple Developer Program** — $99/yr (required to ship to the App Store / TestFlight).
- **Google Play Console** — $25 one-time.

Quenderin's offline, on-device design makes the privacy paperwork the *easy* path on both
stores — lean into it. The one real prerequisite to create first is the **legal pages**.

---

## 0. Do this first — legal pages (both stores require them)

A ready-to-publish privacy policy is now drafted at **`docs/legal/privacy-policy.md`** — fill in
the date + support email, host it (GitHub Pages or any static URL), and paste that URL into App
Store Connect, Play Console, **and** an in-app About/Privacy row. Both stores reject without a
reachable privacy-policy URL.

For the App Store's EULA requirement, opt into **Apple's Standard EULA** in App Store Connect →
App Information (one click — no custom terms file needed). Play does not require a separate terms
page. The policy is short because the app collects nothing: on-device inference, no account, no
analytics/telemetry; the only network call is the user-initiated Hugging Face model download (no
user data sent — there are no servers).

### Content safety (Generative-AI policy) — IMPLEMENTED in code ✅

- **"Report response"** is wired onto every AI chat message + agent answer (iOS context-menu,
  Android long-press) and opens a pre-filled `mailto:`. ⚠️ **Change the target email** before
  publishing — it currently defaults to a personal address: `SupportContact.reportEmail`
  (QuenderinKit) / `SupportContact.REPORT_EMAIL` (quenderin-core).
- A **content disclaimer** ("AI-generated on-device · may be inaccurate or objectionable") shows
  beneath both screens.
- Still **file the 17+ / Mature 17+ age rating** at submission (questionnaire only, no code).

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
      Wi-Fi — please be on Wi-Fi. No account or login. No data leaves the device. The in-app
      'agent' performs only local calculator / unit-conversion / date math — it does NOT control
      the device, other apps, or the screen."
      > ⚠️ **Do NOT** describe ADB / autonomous device-control in store copy or review notes — that
      > is a separate **desktop** product. The store apps cannot do it, so claiming it is
      > inaccurate-metadata (App Store 2.3.1 / Play Deceptive Behavior) grounds for rejection.
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

## 2b. Generative-AI content policy (App Store 1.2 / Play AI-Generated Content)

Both stores require apps that surface model-generated text to (a) **disclose** the content is
AI-generated, (b) give users a **way to report/flag** objectionable output, and (c) apply some
**content-safety filtering**. All three ship in-app — no backend needed:

- [x] **Disclosure** — `SupportContact.aiDisclaimer` ("Responses are AI-generated on-device and
      may be inaccurate or objectionable.") renders beneath both the chat and agent screens on iOS
      (`ChatView`/`AgentView`) and Android (`ChatScreen`/`AgentScreen`).
- [x] **Report mechanism** — a "Report response" action on every AI message (iOS context-menu;
      Android long-press) opens a pre-filled `mailto:` to the support address via
      `SupportContact.reportMailto(...)` / `reportMailtoUri(...)`. Model text is percent-encoded so
      arbitrary output can't corrupt the URL/URI (covered by `SupportContactTests` + `CoreVerify`).
- [x] **Safety filtering** — `SafetyBlocklist` gates unsafe agent actions on both platforms (the
      agent loop halts with `BLOCKED` on flagged content).
- [ ] **Before publishing:** change `SupportContact.reportEmail` / `REPORT_EMAIL` from the
      placeholder to a dedicated, monitored support address (it ships in the app binary).

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
