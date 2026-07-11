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
- **Data safety**: Data collected: NONE. Data shared: NONE. Encrypted in transit:
  N/A (no collection). Deletion request: N/A. The only egress is the user-initiated
  Hugging Face model GET. Declare the `dataSync` foreground service type
  (model download) where asked about FGS permissions.
- **Government app**: No. **Financial features**: None.
- **Health**: None.
- **Generative AI**: Yes, app generates AI content; in-app reporting present
  (long-press any AI message → report via email). Safety: on-device model, no
  server; first-launch consent screen states outputs can be wrong.

## Closed testing (the 12-tester / 14-day gate)
1. Create release on track **Closed testing → Alpha**: upload
   `android/app/build/outputs/bundle/release/app-release.aab`.
2. Release name `0.2.0 (2)`, notes: "First Android build: on-device AI chat,
   5-language UI, offline after model download."
3. Testers tab → create email list "quenderin-testers" (12+ Google-account emails)
   OR enable "anyone with the link". Copy the **opt-in URL** and send it out.
4. Testers: open opt-in link → Accept → install from Play. They should open the
   app a few times across the 14 days (Play measures engagement).
5. Day 15+: Dashboard → "Apply for production access" → questionnaire → then
   promote the release to Production.

## GitHub release (parallel channel)
Signed APK (`:app:assembleRelease`) attached to `v0.2.0` tag — lets anyone
sideload without Play. Play App Signing re-signs the Play channel with its own
key, so the GitHub APK can't cross-update a Play install (different signature) —
document that in the release notes.
