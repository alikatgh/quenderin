# DRAFT Google Play listing — Quenderin

**Pending Albert's Play Console review against the exact release bundle.**
Package `ai.quenderin.app`. The source candidate is `0.6.3` (version code `8`).
Confirm the version code and track in the
[Android Play update checklist](../../docs/ANDROID_PLAY_UPDATE_CHECKLIST.md).

## App name (30 chars max)
```
Quenderin: Offline AI Chat
```

## Short description (80 chars max)
```
Offline AI chat on your phone, with optional online connections.
```
(64 chars)

## Full description (4000 chars max)
```
Quenderin runs compatible language models on your phone. Download a model
sized for your device, then use local chat offline without a Quenderin account.
The app keeps local and remote conversations separate. Model files and approved
memories stay on your device.

• DeepSeek is optional. Connect with your own API key and choose to send text
  from a separate conversation to DeepSeek under your provider account.
• My computer is optional. Sign into an existing account on your configured
  Remote Harness server, then choose and verify a trusted computer. Tasks you
  send and the tools they use run on that computer.
• Step 5 is optional. Approve the connection and choose to send a separate
  text conversation to your configured CUDA host.
• To flag an AI response, use Report in the app. You can edit the excerpt,
  choose a reason and add a note. Selecting Send report sends those details
  to the Quenderin developer's inbox for review.

Downloads, release metadata, optional connections and reports use the
internet. Remote services and hosts handle data sent to them under their own
terms or settings. AI responses can be wrong or outdated. Check important answers.
```

## Graphics
- App icon 512×512: `brand/playstore-512.png` (no alpha ✓)
- Feature graphic 1024×500: `appstore/play/feature-graphic-1024x500.png`
- Phone screenshots: `appstore/play/screenshots/` (captured from arm64 emulator, Pixel 7 profile)

## Store settings

- Category: Productivity. Tags: AI, productivity.
- Confirm pricing, ads, in-app purchases, and the public support email.
- Confirm the privacy policy URL is `https://quenderin.org/privacy`.

## App content review

- **App access.** Explain how to download a compatible model for local chat
  without a Quenderin account. DeepSeek needs the user's API key, My computer
  signs into an existing Remote Harness server account and needs a trusted
  computer, and Step 5 needs a prepared CUDA host. Confirm any reviewer access
  instructions for these optional routes.
- **Data safety.** Review the final bundle and console preview against the
  [source data-flow inventory](../../docs/STORE_SUBMISSION.md) and
  [privacy policy](../../docs/legal/privacy-policy.md). Cover model downloads
  and release metadata, optional DeepSeek authentication and chat, Remote
  Harness sign-in and device enrollment plus computer sessions, Step 5 text,
  and reports. Confirm each recipient, purpose, retention, deletion route,
  and whether the collection is optional. Review collection and sharing
  separately.
- **Generative AI and reporting.** AI responses come from local models or
  optional remote destinations. Verify the in-app Report flow in the release
  bundle. An explicit Send report sends an editable excerpt, reason, optional
  note, source feature, random report ID, platform and app version to the
  developer's Google Apps Script inbox for manual review. Reports have no
  automatic expiry. Support email is a separate flow.
- **Foreground services.** Review the merged release manifest and the
  `dataSync` declaration for WorkManager model downloads. Confirm the demo
  matches the release behavior.
- **Questionnaires.** Review the content-rating and target-audience answers
  against the exact release, including its open-ended AI output.

## Closed testing

Use the existing **Closed testing → Alpha** track. Confirm the live draft,
upload certificate and highest uploaded code before signing and uploading.
Preserve the tester group and share the existing Play opt-in link. Follow the
[Android Play update checklist](../../docs/ANDROID_PLAY_UPDATE_CHECKLIST.md)
for bundle validation, tester availability, and production access.

## GitHub release channel

See the [historical GitHub release notes](GITHUB_RELEASE_NOTES.md) for the
separate APK channel and signing compatibility with Play installs.
