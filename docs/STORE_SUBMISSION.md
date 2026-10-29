# Store submission checklist (App Store + Google Play)

Privacy and copy review: **28 October 2026**, for the **0.6.0** update. This is
source-based submission guidance, not a record of published store answers or a
legal export classification. Reuse the existing app records and signing setup in
[`RELEASE.md`](RELEASE.md); current artifact and validation evidence belongs in
[`SHIP_READINESS.md`](SHIP_READINESS.md) and the release record.

For this update, the user requires no local model-weight downloads and no
simulator or physical-device runs. Use host fixtures and hosted compilation, and
report the remaining inference and rendered-UI gaps. A build or source check does
not establish successful provider authentication, inference, or consent UI.

## 1. Public policy and accurate listing copy

- [ ] Publish and read back **https://quenderin.org/privacy** from
      `docs/legal/privacy-policy.md` and `website/privacy.html`; verify the app
      and both store listings use that URL. A source edit is not deployment proof.
- [ ] Preserve existing legal contact/controller details; do not invent a legal
      entity, address, account access, retention promise, or review credential.
- [ ] Reconcile the final binary, listing, review notes, privacy answers, and Apple
      privacy manifest. Its user-content, email-address and device-ID entries
      cover optional destinations and conservatively declare account linkage;
      recipient retention and purposes still need current store answers.
- [ ] Review the existing EULA selection and age-rating questionnaires against the
      final features. Do not infer a rating or change legal answers from this file.

Suggested factual description:

> Use installed local models for on-device AI. Optional connections let you chat
> directly with DeepSeek using your own API account, access sessions on your
> trusted computer through your Remote Harness server, or send a separate text
> conversation to a Step 5 CUDA host. These connections send data to the selected
> destination. Local chats and memory are kept separate.

Do not use blanket claims such as “no data leaves the device,” “no account,”
“everything is offline,” or “no data collected” for the whole app. No model count
or tested-inference claim should be added without the current catalog and actual
runtime evidence. Describe remote tool execution as happening on the selected
computer; the native client is not local ADB or autonomous phone control.

## 2. Source data-flow inventory

| Feature | Data sent and recipient | Choice and local retention |
| --- | --- | --- |
| Local inference and Hy-Memory | Local processing; no automatic upload to the optional conversations below. | Approved memory and local chats use their existing local stores. |
| Direct DeepSeek validation | API key to `https://api.deepseek.com/models`; no conversation or paid inference in the check. | User chooses to connect. Saved key uses device-only, non-synchronizing Apple Keychain or Android Keystore encryption. |
| Direct DeepSeek chat | API key, new text, completed prior turns and returned reasoning when present, model/thinking/output settings to `https://api.deepseek.com/chat/completions`. No tools or image/file attachments in this UI. | Separate cloud-conversation consent and Send. Separate local history includes answers, reasoning, incomplete turns and usage. Remove key/connection keeps history; no per-chat deletion control in the inspected screens. |
| Remote Harness account and transport | Email/password to configured HTTPS server login; enrollment sends generated device ID, device name, platform, public identity and version. Tokens authenticate/refresh; relay handles routing/connection metadata. | User authorizes existing server account/device. Password is not saved as a credential; identity/tokens have separate protected local storage. |
| Remote Harness sessions | Task text, session/command IDs, time-zone context, model choices and approval decisions through Noise to the verified computer. Computer returns workspace/session/history/tool/bot data and may use its own providers/tools. | User selects and trusts computer; tasks execute there. Separate saved drafts/history/recovery records. Foreground recovery may reconnect; Disconnect disables it but keeps records and authorization and does not stop a running task or erase remote copies. |
| Step 5 | Current text and prior messages in its separate conversation to configured host. Backend check sends no conversation. | Consent plus Send; endpoint and conversation stay in memory. Clear does not erase host copies. HTTPS or literal-loopback HTTP is allowed; an external tunnel/proxy's security must be verified separately. |
| Model/network metadata | Selected public file and optional search term to Hugging Face; release-catalog request to `quenderin.org`; ordinary request metadata visible to recipients. | No conversation attached. Release metadata is cached locally. Recipient logging/retention is not established by client source. |
| Android in-app content report, in versions with the Report control | User-selected editable excerpt, reason, optional note, source feature, random report ID, platform and app version to the developer's Google Apps Script inbox. The inbox adds receipt ID and received time; Google also processes ordinary connection information. | Explicit Send report. No automatic whole-conversation, attachment, memory, API-key or diagnostics upload, and no account/device ID in the report. Developer manually reviews stored reports; no automatic expiry. Access/correction/deletion requests use the existing support contact. Receiver is deployed and synthetic-verified; Android integration and hosted runtime verification remain pending. |
| Support/report email | Content the user sends and normal email sender/delivery information to the existing support mailbox. | `mailto:` prepares a message in another app; opening it does not establish a submitted report. |

Trace references: Apple `DeepSeekView.swift`, `DeepSeekController.swift`,
`DeepSeekProvider.swift`, `DeepSeekHistory.swift`, `DeepSeekCredentials.swift`,
`RemoteHarnessView.swift`, `RemoteHarnessClientAccount.swift`,
`RemoteHarnessClientGateway.swift`, `RemoteHarnessClientStorage.swift`, and
`RemoteHarnessClientController.swift` in `apple/QuenderinKit/Sources/QuenderinKit/`;
Android equivalents in `android/app/src/main/kotlin/ai/quenderin/app/` and
`android/quenderin-core/src/main/kotlin/ai/quenderin/core/`. Apple sends its client
time-zone identifier with remote prompts; Android sends `UTC`. Remote and
DeepSeek history directories are excluded from app-managed backups. These
protections do not establish recipient deletion or zero retention.

## 3. Privacy-label recommendations and unresolved answers

These are category recommendations from the source inventory. The owner must
confirm recipient practices and the exact store questions before saving final
answers. Do not automatically publish the old “Data Not Collected” / “No data
collected or shared” answers.

| Observed data | Apple category candidate | Google Play category candidate | Supported purpose / remaining determination |
| --- | --- | --- | --- |
| Prompts, chat history and reasoning sent to DeepSeek or Step 5; task text sent to computer | User Content → Other User Content for generic free-form AI input | Messages → Other in-app messages for chat; App activity → Other user-generated content for task text outside chat | App Functionality. Confirm recipient retention; optional feature use does not imply ephemeral handling. |
| Server account email | Contact Info → Email Address | Personal info → Email address | App Functionality for authentication. Account management only if the actual account relationship meets that purpose's definition. |
| Generated enrolled device identifier | Identifiers → Device ID | Device or other IDs | App Functionality and securing trusted device access. Confirm server retention and identity linkage. |
| API/account identifiers, tokens, public identity, device name and other operational records | Evaluate User ID or Other Data Types where the retained field meets the definition | Evaluate User IDs, Device or other IDs, or the applicable type | App Functionality. A credential is not proof of a particular label category; establish what recipients retain without recording credential values. |
| Apple model search terms | Search History if collected under Apple's definition | No Android search transmission identified: its picker filters the bundled catalog locally | App Functionality. Confirm Hugging Face handling for Apple; do not copy this category into Android solely from shared documentation. |
| Android explicitly submitted report excerpt, reason and note | Not part of this Apple candidate | App activity → Other user-generated content; Messages → Other in-app messages for submitted chat text | Optional, non-ephemeral collection for App Functionality and offensive-content review. Random per-report IDs are not account/device identifiers. |
| IP addresses, traffic/connection records, support messages | Category follows actual use; Customer Support for retained support requests | Applicable ID, diagnostics, or content category follows actual use | Confirm recipients' logs and purposes. IP visibility alone does not establish location use or diagnostic collection. |

Apple's [app privacy details](https://developer.apple.com/app-store/app-privacy-details/)
distinguish local processing from retained off-device access. Feature opt-in does
not alone satisfy its optional-disclosure criteria. For data that qualifies as
collected, recommend **App Functionality**; treat authenticated content as linked
unless verified recipient protections establish otherwise. Recipient retention,
identity linkage, additional purposes and tracking remain owner determinations.

Google's [Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
requires assessing off-device transmissions, including ephemeral processing in
the form. Optional use supports an optional-collection answer where all users can
decline it. Evaluate user-initiated-sharing and end-to-end-encryption exclusions
per flow; neither exempts server-readable account authentication or direct DeepSeek
processing merely because Remote Harness encrypts session payloads. Confirm all
recipients before answering encryption-in-transit and deletion questions. Do not
claim comprehensive data/account deletion from local key removal or Disconnect.

DeepSeek's [Open Platform terms](https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html)
apply to API use and distinguish downstream end-user processing from the general
consumer privacy policy. No API zero-retention, no-training, fixed storage
location, or deletion guarantee has been established here. Confirm the applicable
account agreement and provider practices before resolving those store answers.
Self-hosted server/host retention, logs, backups, downstream providers and
de-identification also depend on the operator and configuration.

### Source-verified Android form preparation, 28 October

At `281430c8582f532a7d82869b2f796d2a3e48a5af`, the reporting inbox establishes
**Yes, data is collected**. Reports are optional and retained until the developer
handles them; no ephemeral-processing claim applies. Direct provider messages,
server-readable account email and enrolled device IDs also require their
applicable collection declarations. Evaluate sharing exclusions per disclosed,
user-initiated flow; collection and sharing are separate questions.

**Encryption in transit: Yes** is supported for app-controlled off-device routes.
Harness origins require HTTPS, including self-hosted origins, and its redirects
are disabled. DeepSeek, reporting, release metadata and model downloads use HTTPS.
Step 5 permits HTTP only to literal device loopback addresses (`127.0.0.1`/`::1`);
other cleartext networking is blocked. This does not certify a user's server's
downstream forwarding or retention.

**Account creation: No** is supported by the actual Android experience. Harness
asks for an account already configured by the server administrator, logs in and
enrolls this device. It offers no account creation or external creation link.
Device revocation and Disconnect are not account deletion. Google's
[account-deletion trigger](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en)
therefore does not arise from this flow; no special self-hosted-server exemption
is asserted. A deletion-request answer for collected reports can use the
published support contact and receipt route when it is operational; local key
removal does not delete provider records.

These answers were prepared from source and official policy, not saved or
published in Play Console. Apple recipient/retention determinations remain
separate; Android has no identified Hugging Face search request to declare.

## 4. Disclosure, consent and AI safety verification

- [ ] Verify destination/data disclosure before each relevant first transmission:
      API-key validation, direct cloud conversation, remote account enrollment,
      remote computer trust/task execution, and Step 5. The source has dedicated
      controls; signed rendered behavior has not been established by this audit.
- [ ] Apply [Apple 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing):
      disclose third-party AI destinations and obtain explicit permission before
      personal data is sent. A hosted privacy page does not replace in-app consent.
- [ ] Apply Google's [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en)
      to third-party AI as well as other recipients. Verify in-app disclosure and
      affirmative consent wherever its prominent-disclosure rule applies.
- [ ] Verify reporting and restricted-content handling across **all** AI surfaces.
      Google's [AI-Generated Content policy](https://support.google.com/googleplay/android-developer/answer/13985936?hl=en)
      requires reporting/flagging without leaving the app. On 28 October 2026,
      the Google Apps Script receiver was deployed and verified with one synthetic
      report plus an identical retry returning the same receipt; see the nonsecret
      [deployment record](../services/content-report-receiver/deployment.json).
      Android client integration and hosted runtime checks remain pending: verify
      a Report control on local chat, agent, DeepSeek, remote and Step 5 output,
      editable excerpt/reason/optional note and destination disclosure before
      explicit Send report, truthful received/unavailable/ambiguous-send states,
      and unchanged-ID reconciliation for identical manual retries. Verify the
      matching public privacy disclosure after publication. The receiver alone,
      existing email actions and `SafetyBlocklist` do not establish completed
      in-app reporting, comprehensive filtering, Google approval, or a released
      Android app. Keep email support separate from in-app report delivery.
- [ ] Determine whether any account-creation/deletion requirement applies to the
      final app. Current remote setup signs into an existing server account;
      Disconnect and device revocation are not account deletion.

## 5. Apple encryption inventory and classification

The source is **not OS-only cryptography**. In addition to HTTPS, Apple
Keychain/CryptoKit and platform protections, the linked Remote crypto runtime
uses Snow with **`Noise_IK_25519_ChaChaPoly_SHA256`**: X25519, ChaCha20-Poly1305 and
SHA-256 implemented through Snow's Rust default resolver. Inventory sources:
`native/remote-crypto/Cargo.toml`, `src/lib.rs`, `src/resolver.rs`, and the native
Apple/Android bindings. Record the exact linked release artifact as well.

- [ ] Complete the export assessment with this inventory and actual distribution
      territories, including any required declarations/documentation. Do not
      infer “proprietary” merely from using Noise, or infer exemption merely from
      using published/standard algorithms.
- [ ] Reconcile `ITSAppUsesNonExemptEncryption` with the supported classification;
      do not set it to `false` simply to suppress the upload question. Exemption
      and legal classification remain unresolved here.

Apple's [encryption guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
includes linked libraries in the determination. Use its
[export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
and [documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)
for the final answers; this inventory does not decide a legal exemption.

## 6. Existing-record submission checks

- [ ] Apple identifier remains `ai.quenderin.Quenderin`; Android application ID
      remains `ai.quenderin.app`. Refresh live version/build counters and app/track
      state using `RELEASE.md`.
- [ ] Use the existing hosted Apple workflow and Android release workflow and
      verify the selected signed artifact, native engines, crypto runtime and
      catalog/provenance checks. Do not substitute source fixtures for inference.
- [ ] Verify Play target SDK, signing/upload certificate and current track
      requirements against the actual artifact and console.
- [ ] Use screenshots that match the released features and identify the evidence
      as device, cloud simulator, or previously retained material accurately.
- [ ] App Review notes distinguish local inference, optional direct DeepSeek,
      Remote Harness server/computer prerequisites, and Step 5. Give reviewers
      real access or truthful limitations through an authorized private route;
      never place passwords/API keys in this document or invent a demo account.
- [ ] Retain explicit passed/failed/blocked/not-run evidence for privacy answers,
      reporting, consent, encryption classification, signed builds and submission.
      Uploaded, submitted, approved and public are separate states.
