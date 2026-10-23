# Native connections and remote-agent delivery checklist

Quenderin will provide three explicit execution destinations in its native
SwiftUI and Kotlin/Compose apps: on-device models, DeepSeek's API, and a remote
DeepSeek Harness on the user's computer. Every conversation identifies its
destination, model, workspace and tool execution location. Changing a destination
never silently transmits an existing local conversation or attached documents.

Created: 23 October 2026. Baseline: `fb9389d82fc8e8b3486897af3f4585c17d928fcc`.
Implementation branch: `codex/native-connections-20261023`.
This file is the delivery checklist; checked items require recorded evidence.
An implemented contract is not evidence of a connected remote session or a store
release. Work proceeds from the top, with independent preparation in parallel.

| Destination | Model execution | Tool execution | Credentials |
| --- | --- | --- | --- |
| On this device | Existing local runtime | Permitted local capabilities | Existing local setup |
| DeepSeek | DeepSeek API | Permitted local capabilities | User API key in native secure storage |
| My computer | Host's provider, initially DeepSeek | Remote computer | Provider credentials stay on the Host |

```text
Native Quenderin (SwiftUI / Kotlin Compose)
  +-- Local adapter -> existing on-device runtime and capability gates
  +-- DeepSeek provider -> HTTPS -> DeepSeek API
  +-- Remote session adapter -> end-to-end encrypted connection
        -> Host Remote plugin -> DeepSeek Harness -> Host tools / model provider
```

## 1. Native connection and conversation contracts — foundation complete

Acceptance: both native cores represent all three destinations, preserve complete
provider messages and remote recovery identities, reject unsafe profiles and
cross-destination reuse, and migrate existing local transcripts without losing
content. No networking, credential capture or model download is activated by
these contracts. The existing local engine remains the local adapter.

- [x] Save the complete ordered strategy as this checklist before implementation.
- [x] Define a shared, versioned contract and canonical cross-platform fixtures.
- [x] Implement validated connection profiles with credential references only.
- [x] Define structured provider messages, tool calls/results, reasoning,
  capabilities, usage, streaming events and cancellation boundaries.
- [x] Define remote identities, session/run state, pending commands, approvals,
  acknowledgement and reconciliation states.
- [x] Define a versioned conversation envelope with complete provider history,
  remote session reference and last confirmed recovery position.
- [x] Migrate legacy local transcripts in memory without rewriting originals or
  changing their execution destination.
- [x] Require a new conversation/explicit transfer for a destination change;
  define a fail-closed matching check before dispatch.
- [x] Test round trips, migrations, unknown schema versions, malformed data,
  unsafe endpoints and cross-destination/approval identity mismatches.
- [x] Wire the contract fixtures and parity check into bounded hosted checks.
- [x] Obtain independent review, resolve findings and publish the verified
  foundation increment for online review.

Principal seams: `apple/QuenderinKit`, `apple/QuenderinApp`,
`android/quenderin-core`, `android/app` and `shared/`. Keep UI bubbles as a
projection; their user/assistant-only shape cannot replace provider history.

## 2. First-class native DeepSeek provider — next work

- [ ] Add provider setup, secure credential entry, connection validation and
  actionable authentication/quota/network errors.
- [ ] Add Apple Keychain and Android Keystore-backed credential storage; profiles
  hold opaque references, never secret values.
- [ ] Add a dedicated streaming Chat Completions transport on each platform.
- [ ] Add a versioned capability catalog and deliberate refresh policy.
- [ ] Support `deepseek-flash` (default, text/images) and `deepseek-v4-pro`
  (optional text reasoning) using refreshed official capability evidence.
- [ ] Implement Off/Low/High/Max reasoning and faithful `reasoning_content`,
  tool-call ID and result preservation across turns.
- [ ] Handle split/truncated streaming frames, context/output limits, usage,
  cancellation, 401/402/429/5xx and bounded safe retries.
- [ ] Enforce client/Host execution limits; provider compatibility must not imply
  support for ignored Responses API controls such as `max_tool_calls`.
- [ ] Expose destination/model/effort/usage in native conversation UI.
- [ ] Permit DeepSeek setup and use before any local model download.
- [ ] Keep remote Harness account authentication distinct from direct API keys;
  Host credentials are not copied to the phone.
- [ ] Verify local tools disclose any resulting transmission to DeepSeek.
- [ ] Test the provider with fake transports, then bounded authorized live calls.

## 3. Complete first remote DeepSeek journey

Acceptance journey: connect -> choose computer -> choose workspace -> open/create
session -> send -> observe text/tools -> approve/deny -> stop -> reconnect to the
same session, on Apple and Android, without a local model download.

- [ ] Pin supported Harness/Remote revisions and maintain a compatibility matrix.
- [ ] Verify applicable MIT and dependency notices before reusing code.
- [ ] Implement native server enrollment, discovery and connection lifecycle.
- [ ] Isolate current `harness.remote.*` / Session V3 carrier details behind the
  Quenderin adapter; reject retired RPCs such as `sync.from`.
- [ ] Implement workspace/session lists, creation, selection, history and streams.
- [ ] Add native composer, timeline, model/effort selection and interactive questions.
- [ ] Present Host approvals without starting a second local agent loop.
- [ ] Implement Host-acknowledged stop and truthful disconnected/unknown states.
- [ ] Preserve drafts, reading position, search and favorites with Host provenance.
- [ ] Verify the complete journey against an actual pinned Host when authorized.

## 4. Device trust, approvals and recovery

- [ ] Reuse the fixed upstream Noise suite through maintained implementations;
  establish native interoperability with upstream golden vectors.
- [ ] Add explicit Host confirmation and QR/fingerprint comparison for enrollment.
  Upstream's account-authorized first-use pinning alone is not bilateral pairing.
- [ ] Version-gate any required Host changes for pairing, scopes and deduplication.
- [ ] Bind approvals to Host/device, workspace, session/run, exact action, expiry
  and approval ID; reject stale, duplicate and mismatched approvals.
- [ ] Persist command identifiers before sending and require Host deduplication
  before claiming retry safety for mutations.
- [ ] Reconcile lost acknowledgements against authoritative Host state.
- [ ] Recover using current history snapshots and reopened streams; deduplicate
  events and detect gaps without replaying uncertain mutations.
- [ ] Distinguish stop requested, stop confirmed and stop outcome unknown.
- [ ] Define controller ownership when multiple devices attach to one session.
- [ ] Recover on foreground return/relaunch while Host work can continue.
- [ ] Keep any later notifications content-minimal and optional for correctness.
- [ ] Test key changes, tampering, revocation, replay, disconnects, process death,
  conflicting controllers, pending approval and cancellation races.

## 5. Secret protection and enforceable bounds

- [ ] Keep model keys out of source, bundles, logs, transcripts, screenshots,
  diagnostics, exported sessions and unencrypted backup.
- [ ] Restrict direct credential transmission to the approved TLS origin and
  reject redirects/cross-origin credential forwarding.
- [ ] Keep remote model keys on the Host and relay payloads encrypted end to end.
- [ ] Document visible routing/account/presence metadata and authentication-server
  credentials separately from encrypted business payloads.
- [ ] Redact diagnostics and reports before transmission; allow user-selected
  content only and exclude secret-bearing payloads.
- [ ] Revoke active device access and prevent reconnect after revocation.
- [ ] Set bounded runs/session, Host concurrency, tool calls, deadlines, message
  sizes, file transfers, queues, retries and connection lifetimes.
- [ ] Fail closed on missing budgets/configuration and test the independent stop.
- [ ] Use user-owned provider accounts initially. Verify approved allowance and
  provider-enforced spending ceilings before activating funded infrastructure.
- [ ] Account separately for model tokens, search/fetch, relay/TURN egress,
  notifications, storage and CI. Recheck announced 1 November search/fetch fees.
- [ ] Make terminal access a distinct Host opt-in; disclose Host-user privileges.
  Agent approvals and a working directory are not a terminal sandbox.
- [ ] Run exact staged/tree secret scans before every authorized publication.

## 6. Full feature parity, in dependency order

- [ ] Core Host/workspace/session/history/streaming journey (section 3).
- [ ] Model/effort, questions, approve/deny and stop (section 3).
- [ ] Relaunch recovery, drafts, reading position, search and favorites.
- [ ] Images, bounded file previews and downloads.
- [ ] Explicit uploads and workspace creation, after path/transfer controls.
- [ ] Terminal and authorized development previews, after privilege/security tests.
- [ ] Provider/settings management with field-level authorization and redaction.
- [ ] Automation tasks and delivery history with durable execution/cost bounds.
- [ ] DS Bot teams, group conversations and interactive cards.
- [ ] LAN/P2P/TURN with verified encrypted relay fallback.
- [ ] Codex App Server adapter, then individual ACP backend adapters with their
  actual capability restrictions and independent acceptance tests.
- [ ] Keep remote plugin/code installation outside the mobile app; expose only
  negotiated, authorized management operations.
- [ ] Call full parity complete only when supported journeys pass on both native
  platforms; classify upstream experimental features explicitly.

## 7. Hosting and operations

- [ ] Begin with a user-controlled relay/Host in an isolated private test setup.
- [ ] Verify minimal server license coverage and actual deployment prerequisites.
  The included server is single-account, single-process and relay-only; it does
  not supply multi-account OAuth/P2P/TURN or the hosted service's complete Web UI.
- [ ] Keep persistent Node/WebSocket hosting separate from the existing static
  Cloudflare Worker; do not overwrite the public website configuration.
- [ ] Choose supported user-hosted service or a separately operated Quenderin
  service for general availability using verified capacity/spending evidence.
- [ ] Before managed activation: account isolation, device revocation, scoped
  administration, abuse/egress limits, availability and backup/restore evidence.
- [ ] Version service/Host independently and preserve older-client compatibility.
- [ ] Prove recovery and disabling new remote work without losing local history.

## 8. Native and failure verification

- [ ] Shared Swift/Kotlin provider/protocol fixtures and history round trips.
- [ ] Wrong keys, revoked devices, malformed/oversized frames and replay rejection.
- [ ] Cross-origin credentials and destination isolation.
- [ ] Duplicate approvals, lost acknowledgements, process death and reconnect.
- [ ] Stop/approval races and bounded retries after ambiguous remote success.
- [ ] File traversal, symlink escape, transfer exhaustion and rendered-content safety.
- [ ] Existing local onboarding/chat/agent regression checks.
- [ ] Fresh-install remote-only journeys and old-conversation migration.
- [ ] Signed native journeys with inspected screenshots/interaction outcomes.
- [ ] Independent security/correctness review of the final integrated revision.
- [ ] Tie source, tests, runtime endpoints, effective controls and artifacts together.

Current October constraint: no local model-weight downloads and no simulator or
physical-device runs. Host fixtures and hosted compilation may proceed. Native
interaction/rendering remains unverified until a suitable native validation
route is separately authorized. Use Xcode Cloud for Apple work; prepare missing
test targets/plans/actions without silently starting prohibited runs.

## 9. Store readiness and existing blockers

These are dated repository observations, not freshly verified store states.
Refresh account-specific facts before release; use `docs/RELEASE.md`.

- [ ] Repair the existing dependency-audit failure and restore relevant CI.
- [ ] Refresh Apple's submitted 0.5.0 (22) status, build counters and messages.
- [ ] Update the existing Xcode Cloud workflow's source/branch selection; preserve
  Prism provenance, payload, signing and deployment-metadata gates.
- [ ] Verify included Cloud capacity and effective spending controls before runs.
- [ ] Recover the matching Android private upload key or perform an explicitly
  authorized official reset; do not repeat disproven password/store searches.
- [ ] Repin/validate Android export source: existing workflow hardcodes `eecf089`.
- [ ] Verify Android signed certificate, source receipt, real JNI payload and
  16 KiB alignment. Existing API 36 target needs no speculative target bump.
- [ ] Refresh Alpha/production eligibility and fulfill actual closed-test gates.
  The recorded seven testers are not proof of current eligibility; where the
  new-personal-account rule applies, 12 opted-in testers for 14 continuous days
  precede a production-access application.
- [ ] Update native disclosures, privacy policy, Apple privacy answers and Play
  Data safety for each actual destination and optional content transmission.
- [ ] Add in-app AI-content reporting using user-selected redacted content.
- [ ] Assess login/account deletion obligations if introducing Quenderin accounts.
- [ ] Assess Noise encryption export compliance for the actual shipped artifact.
- [ ] Explain native task/session execution boundaries in review notes and assess
  Apple's remote-desktop classification; approval is not guaranteed by design.
- [ ] Prepare truthful screenshots and a bounded synthetic review Host/workspace.

## 10. Authorized release and live verification

- [ ] Resolve material release controls/checks and independently review candidate.
- [ ] Merge reviewed source to main and pin the exact release revision.
- [ ] Deploy compatible reviewed Host/server support before dependent clients.
- [ ] Build/verify signed iOS/macOS artifacts in Xcode Cloud.
- [ ] Select exact processed builds; submit with automatic release after approval.
- [ ] Export/verify Android AAB from the same release source and sign with the
  registered upload key through the established credential-safe route.
- [ ] Publish Android to the existing testing track; promote only when actual
  eligibility and acceptance gates pass.
- [ ] Verify distributed versions and their actual connection journeys.
- [ ] Verify disable/stop/recovery without deleting user conversations or files.
- [ ] Record committed, pushed, built, tested, signed, uploaded, submitted,
  approved and publicly available as separate evidence states.

## Evidence and implementation log

- 23 October: roadmap saved before product edits. Implementation begins with
  section 1. Branch baseline is clean main `fb9389d`; original dirty checkout is
  preserved. No external provider, Host or store operation has been activated.
- Foundation source now defines both native cores' profiles, destination binding,
  complete provider history, bounded request/event types, versioned envelopes and
  remote approval/receipt states. Existing app storage/onboarding remains on its
  original local path until the next integration step. Supported histories can
  migrate in memory; role-incompatible legacy attachments fail with their
  original bytes retained, rather than being dropped or relabelled.
- Local host evidence: 104 canonical Kotlin fixtures, 16 additional behavior
  checks, 337 existing Kotlin core checks and 14 Python evidence-guard tests
  passed. Swift source syntax parsing passed. Staged JavaScript and Python
  secret pattern scans passed before publication.
- Independent review found two platform differences: unnamed attachments on
  Kotlin and malformed/leading-zero IPv6 forms on Swift. Both were fixed and
  regression fixtures added. Final targeted review reported no remaining
  material findings for this inactive foundation.
- Published foundation source: `2a73344e6310d5abffe14432c524868ce9d59a40`,
  [review PR 170](https://github.com/alikatgh/quenderin/pull/170).
  [Hosted CI 39894029320](https://github.com/alikatgh/quenderin/actions/runs/39894029320)
  passed the full QuenderinKit job: 624 tests, 6 skipped, zero failures, including
  23 foundation test methods and all 104 canonical fixture executions. The iOS
  app SDK build also passed; no simulator was booted or exercised. Android's
  hosted core job passed, including its existing core suite, all 104 canonical
  fixtures, 16 behavior checks and the evidence guard. The separate hosted
  [secret scan](https://github.com/alikatgh/quenderin/actions/runs/39894029240)
  passed. The broader CI dependency audit still fails on unchanged dependencies;
  that release prerequisite remains open in section 9.
- This is a source foundation, not connected inference, remote Host control,
  rendered native validation or an App Store/Play submission. Next: section 2,
  native secure credential storage and fake-transport DeepSeek streaming, before
  enabling the remote-only native setup/chat journey.
- Session storage: reused the existing source checkout (69,832,704 allocated
  bytes, up 307,200 from this task's baseline) and installed no dependencies.
  Nine verified disposable compiler outputs/logs (20,244,214 apparent bytes)
  were removed; registered scratch cleanup completed with no retained scratch.
  The source checkout remains for online/local review and is removed only on
  explicit request. Volume-wide free-space/swap changes are separate from these
  measured task paths.

### Foundation publication classification

This increment has no active provider, remote transport, credential capture,
model download, native UI entry, database migration or external action. Data
decoding/migration is in memory and does not replace existing files. Resource
exposure is bounded by the documented byte/count/depth limits and failure tests.
Approval/receipt transitions are inert contracts, not proof of Host enforcement.

Publishing the task branch starts no production/store workflow. A review PR runs
the existing public-repository standard GitHub CI and secret checks; the changed
native test jobs have finite 20/25-minute limits, no added dependency/service,
artifact retention, provider key, relay provisioning or paid activation. Website
deployment is main/path-gated; desktop publication is tag/manual-gated; Android
export is manual and the existing Xcode Cloud release branch is different.
Reverting this source increment requires no user-data rollback. Future provider,
Host, server and store activation still requires the relevant sections' controls
and exact artifact evidence.

## Pinned research and official references

- [Remote upstream inspected revision](https://github.com/liguobao/ds-harness-remote/commit/9a60e783ec1ceaff6116b0462a2863f07f602a55)
- [Remote 0.5.17 release](https://github.com/liguobao/ds-harness-remote/releases/tag/v0.5.17)
- [Current Host bridge](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/harness-remote-bridge.ts)
- [Protocol (draft; verify against code)](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/docs/protocol.md)
- [Enrollment/pinning](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/server-connection.ts#L381)
- [Terminal policy](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/terminal-policy.ts)
- [Minimal self-hosted server](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/apps/server/README.md)
- [DeepSeek models/pricing](https://api-docs.deepseek.com/quick_start/pricing/)
- [DeepSeek thinking/tool history](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Responses compatibility](https://api-docs.deepseek.com/guides/responses_api/)
- [Harness account provider](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-deepseek-account/README.md)
- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple encryption export requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [Play target API policy](https://support.google.com/googleplay/android-developer/answer/11926878)
- [Play testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Play AI-generated-content policy](https://support.google.com/googleplay/android-developer/answer/13985936)
