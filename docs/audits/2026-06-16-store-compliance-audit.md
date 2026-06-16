# Store Compliance Audit — Quenderin Native Apps

**Date:** 2026-06-16
**Scope:** Quenderin native **iOS** (SwiftUI + QuenderinKit) and **Android** (Kotlin/Compose, `ai.quenderin.app`) store apps.
**Question:** Can these native apps pass App Store + Google Play review?
**What the apps do:** Offline, on-device LLM. Onboarding → device-aware model picker → user-initiated download of ONE GGUF (0.4–9 GB) from HuggingFace → llama.cpp inference fully on-device → chat + a pure-logic agent loop (calculator / unit-convert / date math). No account, no backend, no analytics/telemetry. Only network call is the model download.

> The "autonomous computer/device usage" (ADB device control) lives in the SEPARATE desktop Electron app. It is **NOT** in these store apps. The store apps have no AccessibilityService, no device automation, no screen capture of other apps. This audit is against the shipping store code only.

---

## Top Verdict

| Store | Can submit today? | What blocks it |
|-------|-------------------|----------------|
| **iOS** | **NO — blocked** | (1) No `PrivacyInfo.xcprivacy` privacy manifest → App Store Connect upload validator auto-rejects the binary. (2) No privacy-policy URL → the App Store Connect record cannot be submitted for review (hard field). |
| **Android** | **NO — blocked** | (1) No `<service>` element declaring `android:foregroundServiceType="dataSync"` → `MissingForegroundServiceTypeException` crash on every Android 14+ device during the model download (the app's primary setup step). (2) No privacy-policy URL → the Play Console listing / Data Safety form cannot be completed. |

**Neither store can be submitted today.** Each has exactly **2 hard blockers**, all of which are documented gaps with cheap, well-scoped fixes (no architectural change required). The underlying app design — fully offline, no data collection, minimal permissions, no device automation — is genuinely clean and review-friendly. The blockers are submission-mechanics and one Android runtime crash, not design problems.

**Counts:** 4 blockers · 6 major · 8 minor (deduplicated across stores; see grouped tables below).

> **Resolution status (updated 2026-06-16 — commits `8a53180`, `27a09a3`, `e423d3e` on `main`).**
> **Code-side: done + CI-green.** iOS `PrivacyInfo.xcprivacy` added (blocker cleared); Android FGS
> `<service foregroundServiceType="dataSync">` declared (blocker + the API-34 crash);
> `ITSAppUsesNonExemptEncryption=false`; `models/` backup-exclusion; privacy policy drafted at
> `docs/legal/privacy-policy.md`; **Report/Flag affordance + AI-content disclaimer shipped on iOS +
> Android** (the major Generative-AI items); `BackgroundModelDownloader` marked non-shipping (#9);
> and the Android app module is now gated by a CI `assembleDebug` job. All seven CI jobs pass.
> **Remaining = account/hosting only (no code):** host the privacy policy + paste the URL, change the
> support email from the default, file **17+ / Mature 17+**, opt into Apple's Standard EULA, complete
> the Data-Safety form. The one remaining *blocker* is the privacy-policy URL — the text is written,
> it just needs hosting.

---

## Gaps by Store and Severity

### iOS — App Store Review Guidelines

#### Blockers

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **`PrivacyInfo.xcprivacy` privacy manifest absent** | ASRG 5.1.1; Apple Privacy Manifest policy (mandatory for all new submissions/updates since 2024-05-01) | `find` over `apple/` returns zero `PrivacyInfo.xcprivacy` (re-confirmed this session). App uses 3 required-reason API categories: disk-space `volumeAvailableCapacityForImportantUsageKey` + `attributesOfFileSystem` (`DiskSpace.swift:24-28`); file-size via `attributesOfItem` `.size` (`OfflineReadiness.swift:52-53`, `Preflight.swift:66`); writes to `.applicationSupportDirectory` (`OnboardingModel.swift:127`). Apple's upload validator rejects binaries missing the manifest or using required-reason APIs without a declared reason. | Add `apple/QuenderinKit/Sources/QuenderinKit/PrivacyInfo.xcprivacy` (or in the app target): `NSPrivacyTracking=false`, `NSPrivacyTrackingDomains=[]`, `NSPrivacyCollectedDataTypes=[]`, `NSPrivacyAccessedAPITypes` with disk-space reason **E174.1** (display to user) and file-attribute reason **3B52.1** (file the app writes). Also confirm `llama.xcframework` ships its own manifest or is covered. |
| **No privacy-policy URL** (also a Play blocker — see cross-cutting) | ASRG 5.1.1; App Store Connect requires a privacy-policy URL for every app | `docs/STORE_SUBMISSION.md:13-25`: "There are no in-app or hosted privacy/terms pages yet. Both stores reject without a privacy policy URL." No URL in any Swift source. `RootView`/`ChatView`/`AgentView` have no Settings/About/Privacy row. | Host a short static policy (GitHub Pages per `STORE_SUBMISSION.md:24`): on-device inference, no account, no telemetry, only network egress is the user-initiated HuggingFace download, no user data transmitted. Fill the URL in App Store Connect (hard gating field). Add an in-app About/Privacy row (best practice). |

#### Major

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **`UIBackgroundModes` not declared while `BackgroundModelDownloader` uses a background `URLSession`** | ASRG 2.5.4; Apple QA1941 | `BackgroundModelDownloader.swift:31` creates `URLSessionConfiguration.background(withIdentifier:)` with `sessionSendsLaunchEvents = true`. Neither `Info.plist` (1-30) nor `project.yml` (1-27) declare `UIBackgroundModes`. Shipping path `QuenderinApp.swift:21` wires the **foreground** `URLSessionModelDownloader`, so this is latent — but the background class is in the bundled framework (visible to static analysis) and the `handleEventsForBackgroundURLSession` app-delegate hook is absent. | If background download is intended for production: add `UIBackgroundModes` (`fetch`, or use `BGProcessingTaskRequest`) and implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` / `.backgroundTask`. If foreground is the shipping path: mark `BackgroundModelDownloader` clearly as non-shipping to avoid reviewer/static-analysis confusion. |
| **No EULA / Terms — Standard EULA not opted in** | ASRG 5.1.1; App Store Connect → App Information → EULA | `STORE_SUBMISSION.md:17` covers only the privacy gap, not EULA. App Store Connect's "Submit for Review" stays greyed out until a custom EULA URL or Apple's Standard EULA is selected. | One click: select "Use Apple's Standard End User License Agreement" in App Information. No code change. |

#### Minor

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **`ITSAppUsesNonExemptEncryption` key missing** | ASRG 2.5.4 / 2.5.8; US EAR §742.15(b) exemption | `Info.plist` (1-30) has no key. App uses only OS TLS + CryptoKit SHA-256 — exempt. `STORE_SUBMISSION.md:44` documents the fix but it's not done. Without it, every TestFlight/production upload triggers the manual export-compliance questionnaire and sits in "Missing Compliance." | Add `<key>ITSAppUsesNonExemptEncryption</key><false/>` to `Info.plist` (or `project.yml` properties). One line; clears the prompt permanently. |
| **Guideline 4.2 — app is a near-empty shell until a 0.4–9 GB download completes** | ASRG 4.2 (Minimum Functionality) | `RootView.swift:20-35` gates all post-onboarding UI behind `if case .ready = onboarding.phase`. On a 9 GB model this can be 30–60 min on Wi-Fi; no demo/cached mode before ready. | Risk is low — the onboarding (probing → recommended → downloading → loading → ready in `OnboardingModel.swift`) is purposeful, not blank. Mitigate with complete App Review notes (download size range, "be on Wi-Fi," onboarding IS the first-use experience by design) per `STORE_SUBMISSION.md:47-49`. Optional read-only demo/cached-conversation mode. |

#### Compliant (iOS)

- **2.5.2** — GGUF files are read-only tensor data (model weights), not executable code; consumed by bundled llama.cpp like a CoreML `.mlpackage`. Not in scope for "download and execute code."
- **1.2** — single-user offline generator; no sharing/feed/comments/server → 1.2 multi-user moderation requirements do not apply.
- **5.1.1** — no unnecessary `NSUsageDescription` strings; no AVFoundation/CoreLocation/Contacts/Photos usage. Lean and correct.
- **5.1.2** — "Data Not Collected" nutrition label is accurate and supportable (no analytics/crash/ads SDKs; `ConversationStore` is local-file only).
- **2.1** — deployment target iOS 16 meets the current new-submission floor.
- **Export compliance** — only standard OS crypto (TLS + SHA-256); exempt under EAR §742.15(b).

---

### Android — Google Play Developer Program Policies

#### Blockers

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **No `<service>` declaring `foregroundServiceType="dataSync"`** | Google Play Foreground Service Policy; Android 14 (API 34) FGS-type enforcement; `targetSdk 35` makes it mandatory at the OS level | `AndroidManifest.xml` has **zero `<service>` elements** (re-confirmed this session; manifest ends after the single `<activity>`). `ModelDownloadWorker.kt:65-71` correctly passes `ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC` at runtime and `FOREGROUND_SERVICE_DATA_SYNC` is declared (`manifest:9`), but WorkManager 2.9.1 does **not** auto-inject `android:foregroundServiceType` into the merged manifest. On API 34+, `setForeground()` with an undeclared type throws `MissingForegroundServiceTypeException` — crashing the app during its primary setup step (the model download). | Add to `AndroidManifest.xml`: `<service android:name="androidx.work.impl.foreground.SystemForegroundService" android:foregroundServiceType="dataSync" tools:node="merge" />` and add `xmlns:tools` to `<manifest>`. Also declare DATA_SYNC under Play Console → App Content → foreground service types. |
| **No privacy-policy URL** (also an iOS blocker — see cross-cutting) | Google Play User Data policy (privacy policy required in Play Console field AND in-app, for all apps) | `STORE_SUBMISSION.md` §0: no hosted/in-app policy. No `privacy` reference in `OnboardingScreen.kt`, `ChatScreen.kt`, `AgentScreen.kt`, `MainTabs.kt`. Play Console submission cannot complete without it. | Host the same short static policy; link in the Play Console listing field and an in-app About/Privacy row. |

#### Major

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **No user mechanism to flag/report AI-generated content** | Google Play Generative AI Policy (effective Dec 2023): apps generating AI content must let users flag harmful/inappropriate output to the developer — applies regardless of on-device vs cloud | `ChatScreen.kt` (114 lines) renders `MessageBubble` (58-59) with no long-press/overflow/flag action. `AgentScreen.kt` (121 lines) renders `AgentStepRow` (69) + final-answer `Surface` (70-76) with no report action. | Add a long-press / overflow "Report this response" on AI bubbles in `ChatScreen` and on agent answers in `AgentScreen`. A `mailto:` or in-app form to a developer address satisfies the policy — no automated moderation pipeline required. |
| **`SafetyBlocklist` gates agent tool inputs but not chat output** | Google Play Generative AI Policy ("implement safeguards to minimize the risk of outputting policy-violating content"); Inappropriate Content policy | `AgentLoop.kt:49-54` applies `SafetyBlocklist.isBlocked()` to `decision.input` / `decision.name` only. `ChatScreen.kt:76-93` → `chat.send(text)` returns model output with no filter. `SafetyBlocklist.kt:9-17` covers financial/destructive/credential keywords — no hate/violence/CSAM categories. An unconstrained user-chosen GGUF can emit policy-violating chat text unguarded. | Add an output-side keyword/regex check in `ChatModel`/inference result path (on-device is fine — no cloud call needed). Expand `SafetyBlocklist` categories for both chat and agent paths. ("Minimize risk" language → keyword filter suffices; not a full pipeline.) |

#### Minor

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **`android:allowBackup="true"` with no backup-exclusion rules** | Play Data Safety form accuracy; Android backup best practice | `AndroidManifest.xml:14` — `allowBackup="true"`, no `dataExtractionRules` / `fullBackupContent`. `ModelDownloadWorker.kt:51` stores 0.4–9 GB GGUF at `filesDir/models`. Google Drive backup silently skips (25 MB cap); ADB backup would attempt multi-GB archives. | Add `res/xml/backup_rules.xml` with `<exclude domain="file" path="models/" />`; reference via `android:dataExtractionRules` (API 31+) and `android:fullBackupContent` (API ≤30). Decide whether conversation history is backed up and reflect it in the Data Safety form. |
| **Data Safety form: HuggingFace network access must be disclosed accurately** | Play Data Safety form policy | `WorkManagerModelDownloader.kt` enqueues a GET to HuggingFace (URL from `ModelCatalog`). Carries no user data, but `INTERNET` permission visible in the manifest could prompt a reviewer mismatch with "no data shared." | Answer "No data collected" / "No data shared" (both accurate — it's a GET of a public file). Add a store-description note: "The only network activity is downloading your chosen model from HuggingFace on first setup. No user data ever leaves your device." |

#### Compliant (Android)

- **Target API** — `targetSdk 35` / `compileSdk 35` / `minSdk 28` exceeds the current Play floor (`build.gradle.kts:23,27,29`).
- **Permissions** — exactly 5, each justified: `INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`. No `SYSTEM_ALERT_WINDOW` / `QUERY_ALL_PACKAGES` / contacts / camera / mic / accessibility.
- **Device & Network Abuse** — no AccessibilityService, no `SYSTEM_ALERT_WINDOW`, no ADB / screen capture / inter-app control in the Android source. Agent tools are arithmetic/unit/date only.
- **FGS runtime type-selection** — `ModelDownloadWorker.kt:65-71` correctly selects `FOREGROUND_SERVICE_TYPE_DATA_SYNC` on API 34+. (The gap is the missing manifest `<service>`, the blocker above — runtime code itself is correct.)
- **Content rating** — text-only, no sharing/violence/sexual/ads/IAP → expected Everyone / PEGI 3 via IARC (note the unrestricted-LLM rating caveat under cross-cutting).

---

### Cross-cutting (both stores)

#### Blocker

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **Privacy-policy URL missing — both stores require one before review** | ASRG 5.1.1; Play User Data policy | `STORE_SUBMISSION.md:16-17`. No `privacy_policy_url` in any store-metadata file; none in `Info.plist`/`AndroidManifest.xml`. | Host one short static page; link in App Store Connect, Play Console, and an in-app About/Privacy row. Honest policy is short (on-device, no data, single HuggingFace GET). Do this before the first submission attempt on either store. |

#### Major

| Item | Policy ref | Evidence | Fix |
|------|-----------|----------|-----|
| **LLM/chat output entirely unmoderated — blocklist gates only agent tool calls** | ASRG 1.2 (objectionable AI content); Play AI-Generated Content policy | `SafetyBlocklist.swift:1-3` docstring scopes it to "keywords an autonomous agent must NEVER act on." `AgentLoop.swift:63-68` runs the check inside the `.useTool` branch only; `.finalAnswer` (59-61) and direct chat completions return verbatim, unfiltered. | Minimum viable: (1) one-time onboarding disclaimer ("runs an open-source model locally; output is not filtered"); (2) a Report/Flag affordance (a `mailto:` link satisfies the checklist); (3) optional lightweight output-side keyword check that surfaces a warning banner (preserves the offline value). |
| **Age rating must be filed 17+ (iOS) / Mature 17+ (Android)** | ASRG 1.2 + Age Rating questionnaire (Unrestricted Web Access / Mature Themes → 17+); Play IARC (unrestricted AI text → Mature 17+) | `AgentLoop.swift:59-61` returns raw LLM output. An unrestricted GGUF (Mistral/LLaMA/etc.) can produce sexual/violent/extremist text on direct prompting. Both stores treat this as a Mature signal regardless of intent. | File 17+ at submission: answer "Unrestricted Web Access"/"Mature Suggestive Themes" (App Store Connect) and "unrestricted user-directed text" (IARC). Filing lower and having a reviewer discover the capability is grounds for removal. A lower rating becomes defensible only if an output filter is added later. |
| **README markets "Offline, Autonomous Computer Usage" / ADB device control the store apps don't have** | ASRG 2.3.1 (Accurate Metadata); Play Deceptive Behavior | `README.md:1-5` ("autonomous driving… for your desktop and mobile OS… drive Android and Desktop interfaces autonomously"); `README.md:35,40-43` ADB view-hierarchy + `adb shell input tap`. `STORE_SUBMISSION.md:49` even instructs the submitter to "Call out the autonomous device-control / agent feature" — describing a capability the store apps lack (`AgentTool.swift`, `AgentToolsExtra.swift`, `AgentScreen.kt`: only echo/calculator/units/date). | (1) Write store-specific copy describing what the apps actually do (offline chat + pure-math agent). (2) Scope all device-control mentions to the desktop Electron product. (3) **Fix `STORE_SUBMISSION.md:49`** — remove the "call out device-control" instruction so review notes don't claim a non-existent feature. (Severity major because the review-notes instruction is live, actionable danger even though the README itself isn't reviewed.) |

#### Compliant (cross-cutting)

- **Data collection disclosures** — "Data Not Collected / No Data Shared" is accurate on both stores (`STORE_SUBMISSION.md:38-41,58-62`); no analytics/backend/account.
- **`SafetyBlocklist` on agent tool calls** — correctly gates both tool name and input before execution on both platforms, Swift/Kotlin parity (`AgentLoop.swift:63-68`, `SafetyBlocklist.swift:12-20` / `SafetyBlocklist.kt:9-17`). (Gap is chat-output coverage, tracked above.)
- **Agent tools are pure on-device logic** — no device automation/accessibility/screen capture; `AgentTool.swift` docstring explicitly notes iOS sandboxing forbids driving another app.
- **No accessibility/overlay/package-query permissions** on Android — Device & Network Abuse clean.

---

## Prioritized Remediation Order

**Phase 1 — Unblock submission (do these first; without them neither store accepts an upload):**

1. **Host the privacy policy** and fill the URL in App Store Connect + Play Console (+ in-app About/Privacy row). *Unblocks both stores. Fast — the honest policy is short.*
2. **Android `<service>` FGS-type fix** — add the `SystemForegroundService` `tools:node="merge"` entry + `xmlns:tools`. *Unblocks Android; prevents an API 34+ crash during the model download.*
3. **Add `PrivacyInfo.xcprivacy`** to the iOS app/QuenderinKit target with the two required-reason codes (E174.1, 3B52.1). *Unblocks the iOS upload validator.*

**Phase 2 — Clear the major rejection risks before submitting:**

4. **Add a Report/Flag affordance** in chat + agent UIs (both platforms) — satisfies the Generative AI flag-mechanism requirement.
5. **File age rating at 17+ / Mature 17+** on both stores (questionnaire only, no code).
6. **Add an onboarding disclaimer + minimal output-side keyword filter** for chat (covers ASRG 1.2 + Play AI-content "minimize risk").
7. **Fix `STORE_SUBMISSION.md:49`** and write store-specific copy / App Review notes that do NOT claim device control; scope ADB language to the desktop product.
8. **iOS EULA** — opt into Apple's Standard EULA (one click).
9. **Decide on `BackgroundModelDownloader`** — either wire `UIBackgroundModes` + the delegate hook, or mark it non-shipping.

**Phase 3 — Cleanup / friction reduction (won't block, but file before first upload):**

10. **`ITSAppUsesNonExemptEncryption=false`** in `Info.plist` (kills the per-upload export prompt).
11. **Android backup rules** — exclude `models/`; confirm conversation-history backup stance in the Data Safety form.
12. **Data Safety / store-description note** — clarify the single HuggingFace GET carries no user data.
13. **App Review notes** for iOS 4.2 — download size range, "be on Wi-Fi," onboarding is the first-use experience by design.

**The app's architecture is genuinely review-friendly** (offline, no data collection, minimal justified permissions, no device automation, targetSdk current). Every blocker is submission-mechanics or one Android manifest line — none requires redesign. After Phase 1 + the questionnaire items in Phase 2, both stores are submittable.
