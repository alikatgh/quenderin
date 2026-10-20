# Google Play listing — Quenderin (v0.2.0, versionCode 2)

Paste-ready for Play Console. App: `ai.quenderin.app` (note: Play appId differs from
Apple bundle `ai.quenderin.Quenderin` — intentional, set in `android/app/build.gradle.kts`).
Free, no ads, no IAP. Category: **Productivity**.

## App name (30 chars max)
```
Quenderin: Offline AI Chat
```

## Short description (80 chars max)
```
Private AI chat that runs fully on your phone. Offline, no account, no cloud.
```
(77 chars)

## Full description (4000 chars max)
```
Quenderin is an AI that runs entirely on your device — no account, no cloud, no
tracking. After a one-time model download, every token is generated locally via
llama.cpp; nothing you type ever leaves your phone.

• Chat with an on-device language model — pick from a curated catalog sized to
  your device, or bring any GGUF from Hugging Face
• A private, governed computer-use agent: give it a goal, it plans and uses
  on-device tools — every action that changes something asks you first
• Works fully offline after the download — on a plane, off the grid, anywhere
• Interface in English, Russian, Korean, Japanese, and Chinese
• No sign-in, no ads, no telemetry — conversations stay on the device
• Long-press any AI response to report it — reports go straight to the developer

Quenderin is honest about the trade-offs: small on-device models can be wrong or
outdated, and the app says so plainly. It is a private alternative to cloud AI,
not a replacement for a qualified professional.
```

## Graphics
- App icon 512×512: `brand/playstore-512.png` (no alpha ✓)
- Feature graphic 1024×500: `appstore/play/feature-graphic-1024x500.png`
- Phone screenshots: `appstore/play/screenshots/` (captured from arm64 emulator, Pixel 7 profile)

## Store settings
- Category: Productivity. Tags: AI, productivity.
- Contact email: use the Play Console account email (public on listing).
- Privacy policy URL: `https://quenderin.org/privacy`

## Declarations (App content page)
- **Privacy policy**: URL above.
- **Ads**: No.
- **App access**: All functionality available without special access (no login).
  NOTE: reviewer needs no credentials; chat requires the in-app model download —
  say so in the "any other instructions" box if asked.
- **Content rating (IARC)**: category "Utility/Productivity/Communication or other".
  AI questions: the app GENERATES open-ended AI content → answer Yes to
  "unrestricted AI-generated content"; expect Mature 17+ / IARC 16/18 equivalents.
  Everything else (violence, sexuality, gambling, drugs as FEATURED content): No.
- **Target audience**: 18+ only (do NOT tick any child ages — avoids Families policy).
- **News app**: No. **COVID-19 tracing**: No.
- **Data safety**: Review the live form against the exact release. Local chats,
  approved memories and local image workflows stay on-device. In 0.5.0, optional
  Step 5 sends the separate text conversation to the user's configured CUDA host
  after explicit consent and Send. Do not reuse the old blanket "NONE / only model
  download egress" answers. Assess Messages → Other in-app messages, optional
  collection for app functionality, and Google's user-initiated sharing exception
  separately. Remote requests require HTTPS; HTTP is limited to literal loopback.
  Host retention is not guaranteed ephemeral and local Clear does not delete host
  copies. See [the privacy policy](../../docs/legal/privacy-policy.md) and
  [Google's current definitions](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
  Verify the actual console preview before submission. Declare the `dataSync`
  foreground service type (model download) where asked about FGS permissions.
- **Government app**: No. **Financial features**: None.
- **Health**: None.
- **Generative AI**: Yes, app generates AI content; in-app reporting present
  (long-press any AI message → report via email). Safety: on-device model, no
  server for local inference; optional Step 5 uses the user's selected host.
  First-launch consent screen states outputs can be wrong.

## Closed testing (the 12-tester / 14-day gate)
1. Reuse the existing **Closed testing → Alpha** track, tester configuration and
   saved **5 (0.5.0)** draft. Exact console links and the registered upload
   certificate are in [docs/RELEASE.md](../../docs/RELEASE.md).
2. Attach the verified 0.5.0 / code 5 AAB signed by the matching registered upload
   key. The GitHub draft export is unsigned and must be signed before Play upload.
   Do not include 0.2.0 as a substitute for the update.
3. Preserve the existing testers and opt-in URL. Resolve release validation and
   Data safety changes, submit the update, and verify its actual review/rollout
   state. A saved draft is not an update available to testers.
4. Production eligibility is a separate Play Console gate; a beta update does
   not establish production access or completed tester participation.

## GitHub release (parallel channel)
Signed APK (`:app:assembleRelease`) attached to `v0.2.0` tag — lets anyone
sideload without Play. Play App Signing re-signs the Play channel with its own
key, so the GitHub APK can't cross-update a Play install (different signature) —
document that in the release notes.
