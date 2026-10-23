# Native connections and remote-agent delivery checklist

Quenderin will provide three explicit execution destinations in its native
SwiftUI and Kotlin/Compose apps: on-device models, DeepSeek's API, and a remote
DeepSeek Harness on the user's computer. Every conversation identifies its
destination, model, workspace and tool execution location. Changing a destination
never silently transmits an existing local conversation or attached documents.

Created: 23 October 2026. Baseline: `fb9389d82fc8e8b3486897af3f4585c17d928fcc`.
DeepSeek source: `4abdd1f1794d1fe9e732d2737acc410a2fb7c9a6`,
[PR #170](https://github.com/alikatgh/quenderin/pull/170).
Merged to `main` as `3c096da43fcb6414655946f41476647bf8da3b78`.
Remote foundation: [PR #171](https://github.com/alikatgh/quenderin/pull/171), merged
as `94ee6e0766081d3fbf75b4cdb5423e6d8e84b0f5`.
Native fragments: [PR #173](https://github.com/alikatgh/quenderin/pull/173), merged
as `843d36f7fe19d7685d78262ca54ae9366445b770`.
Android export repair: [PR #172](https://github.com/alikatgh/quenderin/pull/172),
merged as `8c50911ac7d4627c87524c1a35dc26fbab4ba4ac`.
Secure-link owner: [PR #174](https://github.com/alikatgh/quenderin/pull/174),
merged as `f7bc727eabdf89777f57dfc162bb893413c9e1d4` after all 18 CI jobs
and the separate secret scan passed at source
`004661bda9b06eaeed6c50075756d6eb5d480688`.
Linked real-crypto probes: [PR #175](https://github.com/alikatgh/quenderin/pull/175),
source `f91b138a0d27fa0e4abb70969e55716c6a21240c`, merged as
`765f1e6be0bbbcb494e0309808fdcab8d25c1850` after all 18 CI jobs, crypto
host checks and secret scan passed.
Secure Control JSON: [PR #176](https://github.com/alikatgh/quenderin/pull/176),
source `6ef4362a603fed34e3a025bd5246a5d3314248c0`, merged as
`b1637ae914a0f4f45789efed7154cf58ab61cd9b` after all 18 CI jobs, crypto
host checks and secret scan passed.
Android discovery: [PR #177](https://github.com/alikatgh/quenderin/pull/177),
source `d937e79bd058f415eb0565b5def0880448a38aa6`, merged as
`518af0679d3157809a5f3adc9f828b230df07a39` after all 18 CI jobs, crypto
host checks and secret scan passed.
Current mission: operate a DeepSeek Harness on the user's computer through a
complete native task/session interface. Store submission is deferred by the user.
The native journey source is merged through
[PR #178](https://github.com/alikatgh/quenderin/pull/178) as
`ae22b9de73eed009a3eb7cd3b8879315179a1acd`. Its tree exactly matches tested
source `4db5179`. It adds SDK packaging, origin-scoped enrollment, full identity
confirmation, native Apple/Android session interfaces and a pinned Host approval
companion. A live relay/Host target has not been supplied. The separate
official-runtime verification work continues in
[PR #179](https://github.com/alikatgh/quenderin/pull/179).
This file is the delivery checklist; checked items require recorded evidence.
An implemented contract is not evidence of a connected remote session or a store
release. Work proceeds from the top, with independent preparation in parallel.

The immediate completion sequence is:

1. Integrate enrollment, actual native crypto SDK and the complete session flow.
2. Independently review trust, credential recovery, approvals and history recovery.
3. Pass synthetic controller/network/Host journeys and compile both real apps
   with the actual generated SDKs on bounded public hosted runners.
4. Publish the reviewed passing source to `main` with secret scans.
5. Verify a user-operated relay/Host separately, then address rendered/signed
   native validation through an authorized route. Existing no-device/no-simulator
   constraints remain in force. Store submission follows later.

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

## 2. First-class native DeepSeek provider — source implemented

Acceptance: a fresh install can open a separate DeepSeek conversation, consent
to transmission, securely validate/save its API key, choose a supported model and
reasoning effort, stream a reply, cancel safely and reopen saved history. Existing
local chats are never imported automatically. The first interface is text only
with local tools disabled; Flash's image capability is recorded for later work.
Fake-transport evidence, signed secure-storage evidence, live inference and
rendered native interaction are separate checks.

- [x] Add provider setup, secure credential entry, connection validation and
  actionable authentication/quota/network errors.
- [x] Add Apple Keychain and Android Keystore-backed credential storage; profiles
  hold opaque references, never secret values.
- [x] Add a dedicated streaming Chat Completions transport on each platform.
- [x] Add a versioned capability catalog and deliberate refresh policy.
- [x] Support `deepseek-flash` (default, text/images) and `deepseek-v4-pro`
  (optional text reasoning) using refreshed official capability evidence.
- [x] Implement Off/Low/High/Max reasoning and faithful `reasoning_content`,
  tool-call ID and result preservation across turns.
- [x] Handle split/truncated streaming frames, context/output limits, usage,
  cancellation, 401/402/429/5xx and bounded safe retries.
- [x] Enforce direct-client execution limits; provider compatibility must not imply
  support for ignored Responses API controls such as `max_tool_calls`.
- [x] Expose destination/model/effort/usage in native conversation UI.
- [x] Permit DeepSeek setup and use before any local model download.
- [x] Keep remote Harness account authentication distinct from direct API keys;
  Host credentials are not copied to the phone.
- [ ] Verify local tools disclose any resulting transmission to DeepSeek.
- [x] Test the provider with fake transports, including actual pinned OkHttp
  follow-up behavior, cancellation admission and uncertain credential writes.
- [ ] Validate signed Keychain/Keystore persistence, rendered native interaction
  and bounded authorized live inference. Source checks do not complete this gate.

Checked items above record implemented source and synthetic verification. Flash
image support is capability metadata; the initial composer sends text only.
Local tools remain disabled, so their disclosure journey is still unchecked.
Hosted checks at the exact source above pass the Swift suite (644 tests, six
skipped), Android core checks, Android APK/unsigned AAB build and iOS SDK compile.
The [full CI run](https://github.com/alikatgh/quenderin/actions/runs/39899498601)
passed all 18 jobs, including desktop packaging; the separate secret scan passed.
The reviewed source is merged to main through PR #170.
No native simulator/device journey, signed store build or real API call is claimed.

The reviewed API contract and dated catalog live in
`shared/deepseek-provider-contract.json`. Both native suites must execute the
same request/SSE/model cases in `shared/deepseek-provider-fixtures.json`; the CI
guard rejects missing, duplicate or unexpected successful-case markers. Limits
are 120 seconds, 8 MiB request/response, 1 MiB event/text, 65,536 SSE events,
4,096 output tokens, one active request per session and zero automatic retries.
These application limits do not establish a provider invoice ceiling. Development
uses fakes without real keys; no funded provider, relay or notification service
is activated by publishing this source branch.

## 3. Complete first remote DeepSeek journey

Acceptance journey: connect -> choose computer -> choose workspace -> open/create
session -> send -> observe text/tools -> approve/deny -> stop -> reconnect to the
same session, on Apple and Android, without a local model download.

Candidate compatibility baseline, refreshed from upstream source on 23 October:

| Component | Pinned inspection target | Execution evidence |
| --- | --- | --- |
| Remote source | `9a60e783ec1ceaff6116b0462a2863f07f602a55` | Source inspected; no native interoperability yet |
| Host plugin | `ds-harness-remote` 0.5.17 at that revision | Not installed or connected by Quenderin |
| Harness development API | `0.2.1-rc.1` in plugin dev dependencies | Candidate only; not a tested support range |
| Wire envelope | Protocol version 1 | Native carrier fixtures pass hosted Swift/Kotlin checks; no live Host connection |
| Encryption suite | `Noise_IK_25519_ChaChaPoly_SHA256` | Locked Snow/UniFFI host tests and actual generated Swift/Kotlin runtime probes pass; platform linking pending |

The [plugin manifest](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/package.json)
and [plugin MIT notice](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/LICENSE)
were checked. No upstream implementation is copied in the DeepSeek increment.
The repository root has no `LICENSE` at this pin; license coverage of the separate
server and each reused package must be resolved before copying or distributing
them. The [server documentation](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/apps/server/README.md)
describes a separately deployed single-account relay, not a Quenderin-hosted
multi-account service. Pinning an inspection target does not establish support.

- [ ] Pin supported Harness/Remote revisions and maintain a compatibility matrix.
- [ ] Verify applicable MIT and dependency notices before reusing code.
- [ ] Implement native server enrollment, discovery and connection lifecycle.
- [x] Isolate current `harness.remote.*` / Session V3 carrier details behind the
  Quenderin adapter; reject retired RPCs such as `sync.from`.
- [ ] Implement workspace/session lists, creation, selection, history and streams.
- [ ] Add native composer, timeline, model/effort selection and interactive questions.
- [ ] Present Host approvals without starting a second local agent loop.
- [ ] Implement Host-acknowledged stop and truthful disconnected/unknown states.
- [ ] Preserve drafts, reading position, search and favorites with Host provenance.
- [ ] Verify the complete journey against an actual pinned Host when authorized.

Carrier source preparation uses 39 shared request/frame fixtures in
`shared/remote-harness-carrier-fixtures.json`. The adapters keep raw RPC results
opaque until the appropriate operation parser, register streams before sending,
bind callbacks to a connection generation and workspace/session, and preserve
uncertain mutation outcomes without automatic replay. Approval decision dispatch
remains blocked until a Host extension supplies the required exact-action/run/
expiry binding. A stop receipt alone cannot confirm that execution stopped.
These are fake decrypted-port coordinators, not an enrolled or encrypted network
connection. Authentication, WebSocket transport, durable journal and
native UI integration remain work to do.

Source checks: Kotlin compiles with all existing core files and passes all 39
fixture executions plus 23 behavioral groups. Swift source parsing and seven
Python evidence-guard tests pass. Fresh independent review findings are resolved.
The exact foundation source `e7baa288e898c823e0b83cab465682b25b67b27c`
passed [all 18 CI jobs](https://github.com/alikatgh/quenderin/actions/runs/39904655968),
including hosted Swift compilation/XCTest, and the separate secret scan.

The isolated [remote crypto preparation](../native/remote-crypto/README.md) has
no app/network activation. Its reviewed lock and
[locked host run](https://github.com/alikatgh/quenderin/actions/runs/39904655943)
pass nine Rust tests, clippy and runtime probes using the actual generated
Kotlin/JNA and Swift bindings against the same library. Upstream synthetic golden
bytes are checked without vendoring their contents. Platform linking, secure
identity storage and a real Host journey remain required.

The next source increment adds the separate DSHF plaintext fragment layer before
per-fragment Noise encryption. It uses the pinned 17-byte header, 49,152-byte
chunks and 4 MiB message ceiling. Native receivers cap concurrent assemblies at
eight and declared allocation at 8 MiB, expire incomplete messages after 120
seconds and reject identifier reuse. Authenticated connection generations scope
all state, including delayed retirement. Forty-eight original shared cases cover
literal nonuniform byte positions, boundaries, interleaving, replay, malformed
frames, expiry, exhaustion and replacement generations. Kotlin executes all 48;
the exact-marker guard, 13 Python tests and Swift parsing pass. Fresh independent
review is complete. At source `a4e6ec678a7a4f7a9bd0464bb6bb5e893bef60e6`,
[hosted Swift and Android core checks](https://github.com/alikatgh/quenderin/actions/runs/39907251522)
execute all 48 cases exactly once; Swift runs 669 tests with six skipped and no
failures. This layer is not yet wired to a Noise session or network socket.
The complete fragment source run passes all 18 CI jobs and the separate crypto
host and secret-scan workflows before its merge through PR #173.

The next secure-link owner implements the native business-port seam around
injected Noise and decoded packet ports. It checks the exact suite/prologue,
opaque UTF-8 identities, empty handshake, 10-second deadline and counter
advancement. Whole fragment batches are serialized within an eight-MiB/256-message
queue. Failed mandatory retirement blocks replacement until the adapter confirms
cleanup of that exact generation. Swift uses MainActor; Kotlin enforces its
constructor thread before state access, avoiding a reproduced coordinator/link
monitor deadlock. The future adapter must dispatch both owners on that thread.
Twenty-eight original shared scenarios pass Kotlin host execution, including a
bounded two-thread regression and a prepared mutation whose accepted-then-failed
handoff remains outcome unknown. Seventeen Python evidence-guard tests, Swift
parsing and fresh independent review pass. At source
`004661bda9b06eaeed6c50075756d6eb5d480688`, hosted Swift runs 670 tests
(six skipped, no failures), and Swift/Kotlin each execute all 28 cases exactly
once. All 18 CI jobs and the separate secret scan passed before PR #174 merged.
These fake-provider tests establish no real Noise,
JSON/Base64URL, WSS, enrollment, identity-vault or Host integration.

Native crypto packaging will reuse UniFFI's documented
[Swift module/XCFramework](https://github.com/mozilla/uniffi-rs/blob/7bc621ee9d0d15371d792612707ba5ed4111f950/docs/manual/src/swift/module.md)
and [Gradle/JNA AAR](https://github.com/mozilla/uniffi-rs/blob/7bc621ee9d0d15371d792612707ba5ed4111f950/docs/manual/src/kotlin/gradle.md)
integration. Generate bindings from the same locked library metadata; preserve
the generated C header and use `module.modulemap` in XCFramework headers. The
host JNA JAR probe does not establish Android AAR loading, ABI/16 KiB alignment,
minimum-OS behavior or signed app linking. Those remain separate build gates.

The next hosted integration increment compiles the production secure-link,
fragment and coordinator sources against the actual generated UniFFI bindings
and the locked Rust library. Its peer transport and journal are explicitly
memory-only, while both Noise roles use real cryptography and ephemeral in-memory
test keys. It checks encrypted multi-frame describe/prompt traffic, correlation,
exact bytes/counters, tampered handshakes/tags and retirement. Local Kotlin type
compilation and Swift parsing pass. At source
`f91b138a0d27fa0e4abb70969e55716c6a21240c`, the
[hosted crypto run](https://github.com/alikatgh/quenderin/actions/runs/39911672366)
passes nine Rust tests, clippy, both original generated-binding probes and both
linked probes using the pinned Kotlin 2.0.21 and included Linux Swift compiler.
Each linked probe emits its success marker only after all scenarios pass.
Hosted Apple and Android core regressions and all 18 CI jobs pass before merge.
This does not create an enrolled Host,
network connection, durable journal or native platform binary.

The secure Control JSON codec source now wraps the typed seam using the exact
`secure.handshake` and `relay` envelope types, inclusive 64 KiB/1 MiB UTF-8 caps
and canonical unpadded Base64URL through platform libraries. It rejects duplicate
fields and unsafe numeric spellings; metadata IDs are bounded and NUL-free.
These are deliberate native restrictions on upstream's more permissive decoder.
Envelope extensions fail; payload extensions are discarded. Generation remains
outside all wire metadata. Forty-one original shared cases (150 steps), 50
combined Python gate tests, Swift parsing and fresh independent review pass.
The linked probes now serialize and parse every handshake/relay direction;
hosted Swift executes all 41 cases exactly once within 671 tests (six skipped,
no failures). At the exact source above, both actual-Rust linked probes through
JSON pass in [run 39914626417](https://github.com/alikatgh/quenderin/actions/runs/39914626417),
along with all nine Rust tests, clippy and the original binding probes. All 18
CI jobs pass before PR #176 merges. No socket or authentication flow is activated.

First-run inspection then exposed an Android discovery blocker: its authenticated
context required a persisted conversation binding, which correctly requires a
workspace. The fix adds a separate ephemeral transport binding, preserving
origin, Host identity/full pin and a draft/profile scope reference. Discovery can
describe and open `workspace/follow`; unrelated operations fail before dispatch,
journaling or slot reservation. Saved profiles/conversations retain their strict
workspace requirement. Kotlin host checks pass 104 foundation fixtures plus 16
behavior groups, 39 carrier fixtures plus 28 groups and 28 secure-link cases.
The actual generated-binding/JNA linked source compiles after integration with
the Control JSON source. Fresh independent review passes. At source
`d937e79bd058f415eb0565b5def0880448a38aa6`,
[all 18 CI jobs](https://github.com/alikatgh/quenderin/actions/runs/39920672622),
the secret scan and [crypto host job](https://github.com/alikatgh/quenderin/actions/runs/39920672609)
pass. Both actual-Rust linked probes pass through Control JSON with the adjusted
Android binding. PR #177 is merged; platform/device and live Host evidence remain
separate requirements.

The inspected self-hosted enrollment path uses account password login at
`/api/v1/auth/login`, client registration at `/api/v1/devices/register`, device
discovery under `/api/v1/devices`, and relay control at `/ws/v1/connect`.
The included single-account server has no hosted OAuth/signup flow. Account
tokens last eight hours; device access lasts one hour and refresh has a fixed
30-day lifetime. Refresh is single-use: replay revokes the device's tokens.
Before any refresh request, durably mark the attempt; commit the returned pair
atomically, and require reauthorization after an uncertain result rather than
replaying it. A new socket for the same device replaces the old one. These are
pinned source findings, not an existing Quenderin deployment.
See the [server handlers](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/apps/server/src/server.ts)
and [credential store](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/apps/server/src/store.ts).

Both upstream peers automatically trust a first-seen account-authorized identity.
Prepinning one peer does not deny unknown peers. Explicit bilateral human pairing
still requires a Host policy/UI change; it cannot be established by a mobile-only
confirmation. Keep that gate open and negotiate its support before enabling the
approval journey. Remote-service credential bundles need their own origin/device/
role-scoped secure format, separate from the direct DeepSeek API-key format.

### Native application journey source — merged and compiled

The merged source connects the earlier carrier/Noise work to actual native
entry points, account/device enrollment, bounded REST/WebSocket transports,
workspace/session/model selection, a text/tool timeline, bound approvals, Stop,
and isolated draft/session recovery. It also adds real generated SDK packaging
and unsigned hosted Apple/Android app-link checks. Missing SDKs report
unavailable; production never substitutes fixture cryptography.

The [Host companion](../native/remote-host/README.md) is pinned to Remote 0.5.17
at the revision above. It requires explicit public identity pins, rejects legacy
approval and alternate privileged RPC routes, and binds a decision to the exact
device/workspace/session/turn/action/event with a finite lifetime. The native
apps keep Create/Send/Model read-only until that capability is authenticated;
history and Stop remain available.

Pre-publication evidence: Android controller journey 51 checks; production pinned
OkHttp adapter 48 checks; private-backup tests 2; Host policy 28 tests including
the 12 shared canonical digest cases; SDK receipt/package tests 31. Hosted Swift
tests pass **682 tests, six skipped, zero failures**, including the complete
synthetic controller journey. The [Apple SDK job](https://github.com/alikatgh/quenderin/actions/runs/39981265354/job/120508855517)
passes real five-target SDK generation and unsigned iPhone, simulator-SDK and Mac
app compilation. Android's
[actual SDK/app packaging check](https://github.com/alikatgh/quenderin/actions/runs/39981265354/job/120508856149)
passes at `4db5179`, including exact Noise/JNA library bytes and ELF/ZIP 16 KiB
alignment verification. These are unsigned hosted checks. The
[full CI run](https://github.com/alikatgh/quenderin/actions/runs/39981265305)
passes all 18 jobs at `4db5179`, alongside the separate secret scan. The
[patched Host run](https://github.com/alikatgh/quenderin/actions/runs/39973923220)
passes source preparation, actual bundle compilation and three bridge/controller
integration tests with a synthetic Gateway. The
[real-crypto hosted job](https://github.com/alikatgh/quenderin/actions/runs/39968738735)
passed nine Rust tests, both generated-binding probes, both linked carrier probes,
and both production backend probes at `26df619`. An isolated actual official
[Harness runtime fixture](../native/remote-host/runtime-fixture/README.md) is
source-prepared and wired after the existing patched Host tests in the same
bounded public Ubuntu job. Its lock/source/process/environment guard checks
pass; the first hosted real Gateway/Agent/approval journey is pending and is
not yet execution evidence. Cold persistence reads, stop/recovery and live
native interoperability remain separate gates. Fresh independent reviews cover the integrated source and material
fixes before publication.

The initial companion targets macOS/Linux Hosts. Native Windows Host trust,
durable Host command deduplication, Host execution/spending ceilings, interactive
questions and later file/terminal parity remain separate unchecked work. Android
leaves approval actions outside its supported canonical numeric range unavailable
remotely. Host-restart approval recovery may require answering on the computer.
No provider call, relay activation, native-device/simulator run or store submission
has occurred in this increment.

Publication classification: source pushes run the existing checks plus bounded,
read-only public standard Ubuntu/macOS compilation jobs. The repository's public
visibility was refreshed on 23 October. GitHub's current
[standard-runner policy](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
includes these public-repository runners without minute charges. The new jobs use
no provider/app credentials, funded service, cache/artifact upload, signing,
deployment, or store action; each has a finite timeout and superseded-run
cancellation. Store and real-provider activation gates remain separate.

## 4. Device trust, approvals and recovery

- [x] Reuse the fixed upstream Noise suite through maintained implementations;
  establish native interoperability with upstream golden vectors and real linked
  Swift/Kotlin backend probes (recorded above).
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
- [x] Distinguish stop requested, receipt, confirmed stopped and outcome unknown
  in both native controllers, with synthetic journey/regression coverage.
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

- [x] Repair the existing dependency-audit failure and restore relevant CI
  (PR #170; later merged source also passed all 18 jobs).
- [ ] Refresh Apple's submitted 0.5.0 (22) status, build counters and messages.
- [ ] Update the existing Xcode Cloud workflow's source/branch selection; preserve
  Prism provenance, payload, signing and deployment-metadata gates.
- [ ] Verify included Cloud capacity and effective spending controls before runs.
- [ ] Recover the matching Android private upload key or perform an explicitly
  authorized official reset; do not repeat disproven password/store searches.
- [x] Replace the hardcoded Android export source with a validated immutable
  source input and verified provenance (PR #172); this is not a new signed AAB.
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
