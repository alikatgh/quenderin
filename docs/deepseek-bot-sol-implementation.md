# Sol 6.1 implementation brief: native DeepSeek Bot integration

Updated: 24 October 2026. This is the execution brief for the next engineer/agent.
Read it with the [product plan](deepseek-bot-integration-plan.md) and the existing
[native delivery checklist](native-connections-roadmap.md). The checklist remains
the authority for completion evidence; this brief explains how to implement the
remaining work without reopening settled architecture.

The foundation evidence below describes the first published increment. The
current continuation attaches its passive Host route and native read-only Bot
state; see the continuation status at the end before starting new work.

## Mission and working agreement

Deliver persistent DeepSeek bots through Quenderin's existing **My computer**
destination, with native SwiftUI and Kotlin/Compose interfaces. Reuse the Host's
DS Bot and Harness services. Keep one execution owner on the computer and one
connection owner in each native client.

The user has authorized implementation and source delivery, wants useful work
delegated to GPT-6.1 Sol with xhigh reasoning, and has deferred store submission.
Never request or publish credentials. Preserve all unrelated work. Existing
project constraints prohibit local model-weight downloads and simulator/device
runs; use host fixtures and authorized hosted compilation. Do not substitute a
local native build for missing hosted evidence.

Work in independently reviewable increments. Finish each increment's observable
acceptance checks, obtain a fresh read-only review for consequential changes,
and publish only the exact reviewed source when its execution triggers are safe.
An implemented parser, successful compilation and a live native journey are
different evidence. Keep those labels throughout the work.

## Starting point and delivered boundary

The inherited native remote implementation is source `85e38aa8dacc2cc128f3823466393100ff181461`,
merged in PR #181. Its final documentation baseline is
`1fb1b4416a0ad102141c8a20b5d98e1495eb046f`. The earlier source evidence and
remaining live gaps are recorded in the native roadmap; do not report that
historical CI as a fresh run of later changes.

The first published increment adds a **source foundation for a read-only Bot roster**:

- A shared versioned extension contract and synthetic valid/invalid fixtures.
- A pure Host-side projection of explicitly supplied, already-materialized data.
- A distinct native `plugin.route.call` request/result path, separated from the
  existing Harness session-call envelope and mutation journal.
- Capability, workspace, input-size and connection-lifecycle checks on both cores.
- Focused tests and integration into existing verification recipes.

That first increment does **not** install DS Bot, load a runtime, advertise or mount
the new endpoint, add a Bot screen, save a new cache, or change provider/session
data. At that foundation revision, the Host companion still refused this route. That was the
activation boundary, not a claim that the user can already operate DS Bot.

The current continuation wires the pinned Host adapter and proves its lifecycle
before offering the feature in the apps. Full DS Bot startup remains an
operator-owned process; the passive store/channel fixture does not certify the
complete plugin entry point or its agent, connector and scheduler lifecycle.

Implemented API map:

| File | Public seam |
| --- | --- |
| `native/remote-host/quenderin-bot-read-policy.mjs` | `validateBotReadRequest`, `projectBotReadSnapshot`, `handleBotReadRequest`, `validateBotReadResponse`; pure materialized-data functions, no mounted route |
| `native/remote-host/quenderin-bot-runtime.mjs` | `mountBotRead`, `mountedBotRead`, `botSessionWritable`; live materialized ownership, revision and lifecycle boundary |
| `native/remote-host/tools/prepare_bot.py` | Hash-checked store/channel preparation for the pinned already-operated Bot runtime |
| `apple/QuenderinKit/Sources/QuenderinKit/RemoteHarnessBotRead.swift` | `RemoteHarnessBotRoster` and `RemoteHarnessBot` validated display DTOs |
| `apple/QuenderinKit/Sources/QuenderinKit/RemoteHarnessCoordinator.swift` | `readBotRoster`, `supportsBotRead`; existing completion vocabulary preserved |
| `android/quenderin-core/src/main/kotlin/ai/quenderin/core/RemoteHarnessBotRead.kt` | `RemoteHarnessBotRead`, `RemoteHarnessBotRoster`, `RemoteHarnessBotSummary` |
| `android/quenderin-core/src/main/kotlin/ai/quenderin/core/RemoteHarnessCoordinator.kt` | `readBotRoster`, `botReadSupported`, typed `RemoteHarnessOutcome.botRoster` |

The Host projector validates materialized values and bounds their serialization.
It cannot measure whitespace discarded by a prior JSON parser; the installed
transport must bound original wire bytes separately. Native raw-result handling
must enforce original UTF-8 result size as well as its parsed/canonical form.

## Repository and ownership

Active worktree at preparation time:

```text
/Users/s_avelova/Documents/projects/quenderin/.worktrees/android-remote-discovery-20261023
branch: codex/deepseek-bot-read-contract-20261024
```

Use this existing worktree after checking its current status and owner. The root
checkout has unrelated AGENTS, artwork, Wrangler and worktree changes. Do not
reset, clean, relocate or stage those files. Do not assume an old branch name or
HEAD from this document is still current when starting a later session.

```sh
git status --short
git branch --show-current
git log -1 --format='%H %s'
git diff --stat
```

Primary ownership during the next increment:

| Workstream | Files/responsibility | Dependency |
| --- | --- | --- |
| Integrator | Shared contract/fixtures, release gates, roadmap, this brief, final review | Approves the contract before parallel client edits |
| Host worker | `native/remote-host/`, exact upstream patch/provenance and isolated runtime fixture | Must prove the passive endpoint and authoritative identity |
| Apple worker | `apple/QuenderinKit`, then the existing SwiftUI view | Uses the same frozen contract; does not build another transport |
| Android worker | `android/quenderin-core`, then app façade/Compose view | Uses the same contract and existing owner thread |
| Fresh reviewer | Read-only exact integrated diff and acceptance checks | Does not edit, delegate or publish |

Use the configured Sol 6.1 xhigh workers with self-contained tasks and explicit
file ownership. Avoid a second delegation layer. Share test results and short
file/line findings rather than rereading full logs or cloning the same sources.

## Protocol that must stay stable

The machine-readable definition is
[`shared/remote-harness-bot-read-contract.json`](../shared/remote-harness-bot-read-contract.json).
Its new names are **Quenderin extensions**, not stock DS Bot endpoints.

```json
{
  "method": "plugin.route.call",
  "params": {
    "route": "api/bot",
    "body": {
      "endpoint": "quenderin-roster",
      "payload": { "schemaVersion": 1, "workspaceId": "workspace-a" }
    }
  }
}
```

The method is admitted only after the authenticated describe response advertises
both `plugin.route.v1` and `quenderin.bot.read.v1`, in addition to the existing
Harness carrier requirements. The workspace must match the coordinator's
authenticated local binding. A discovery binding with no workspace is not a
wildcard. A later renegotiation or disconnect clears support; a stale describe
response must not restore it.

The success result uses the upstream route wrapper:

```json
{
  "status": 200,
  "json": {
    "ok": true,
    "value": {
      "schemaVersion": 1,
      "workspaceId": "workspace-a",
      "revision": 7,
      "readOnly": true,
      "bots": [
        {
          "id": "bot-a",
          "name": "Researcher",
          "sessionId": "session-a",
          "model": "deepseek-flash",
          "permission": "read-only"
        }
      ]
    }
  }
}
```

`readOnly` describes the Host's writer state and can be false; this operation
never mutates in either case. `model` and `permission` are required keys whose
values can be null. Missing values are not invented defaults. This first DTO
omits instructions, memory, credentials, management objects and group state.

Keep exact keys, safe lexical integers and the declared UTF-8 bounds. Validate
100 bots maximum, unique bot/current-session IDs, exact workspace identity and
redacted errors. Swift's normal String equality can merge canonically equivalent
Unicode strings: identity comparisons and duplicate detection must use exact
UTF-8. Do not silently normalize an identifier.

The outer route result is **not** a Harness Gateway result. Preserve existing
`harness.remote.call` unwrapping, approval consumption, mutation journaling,
Stop receipts and history recovery. Reuse the coordinator's pending capacity,
deadline and stale-connection checks. Never automatically retry a mutation to
make a Bot operation appear reliable.

## Exact next increment: attach a genuinely passive Host read

### A. Pin and prove the runtime combination

Use the inspected revisions until a deliberate compatibility change is justified:

| Source | Pin |
| --- | --- |
| Remote plugin | `9a60e783ec1ceaff6116b0462a2863f07f602a55` / 0.5.17 |
| DS Bot | `1bebe826f74e9a72cabafd3b80602b05af867b38` / 0.2.1 |
| Existing official Harness fixture | `1600d8a1e140dcde43a1a0941940a0480712c011` / 0.2.1-rc.1 |

DS Bot documents testing with rc.2, while the Quenderin fixture pins rc.1.
Prove the exact combination; do not change the Harness lock just to satisfy a
package's wildcard peers. If rc.2 is necessary, isolate that change and run the
existing official approval/Stop/cold-history tests before adding Bot behavior.
Preserve Apache-2.0 and applicable NOTICE for copied Bot source and MIT notices
for adapted Remote/Harness source.

### B. Use the real closure; do not invent a runtime service

At the Bot pin, `apply(ctx, config)` calls `createRuntime()` and discards its
return. `createRuntime()` returns `rt`, but no verified Cordis service exposes
it as `ctx.get('ds-bot')`. The real seam with access to it is
[`channel.install(rt)`](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/channel.js#L134-L147).

Normal endpoints first call `rt.refresh()`. `state` additionally bootstraps,
catalogs models and loads secrets. These are not passive reads. A new endpoint
must branch **before** that shared preamble and consume only already-published,
authoritative materialized state. If unavailable, return a fixed not-ready
failure. Never call load/refresh/bootstrap or resolve an Agent to make it ready.

Full runtime startup is a separate issue: it installs all modules, can migrate
state, resume work, load secrets through the connector effect, resolve capability
agents and check for updates. `github:false`, `memory:false` and
`updateCheck:false` do not prove passive startup. Choose and test one explicit
policy before activation:

1. Read an already-mounted, user-operated Bot runtime, with its startup effects
   understood and separately authorized; the new request itself stays passive.
2. Add a specifically reviewed passive-only runtime entry that never installs
   the execution/secret/connector/scheduler modules. This is more work; do not
   label the ordinary entry passive.

Do not read a user's state or credential files directly from the phone. The
future adapter must resolve the current part and validate bot/session/workspace
membership against Host authority before passing the projection its input.
The pure sanitizer cannot establish that provenance by itself.

### C. Activate only the narrow route

- Extend `native/remote-host/tools/prepare_host.py` with exact source/hash-checked
  transformations. The existing outer method list deliberately excludes the
  route. Add only the new request schema, never the whole upstream Bot enum.
- Add original hashes for every new upstream seam to the relevant manifest;
  reject dirty, linked or mismatched source before mutation. Do not replace
  upstream files with broad copied versions.
- Prefer Remote's in-process shared Fetch handler with the authenticated Remote
  Peer. Keep browser cookies on the Host. Do not introduce an unrestricted HTTP
  forwarding mechanism or enable the loopback fallback without reviewing it.
- Advertise `quenderin.bot.read.v1` only when the correct runtime adapter is
  mounted and the route can enforce this version. A missing provider must keep
  the capability absent; readiness failures must remain bounded.
- Exclude `state`, `send`, all admin/secret/install/update operations and arbitrary
  URLs. Preserve the exact-action `quenderin/approval` path; upstream's ordinary
  Bot approval endpoint must not become a bypass.
- Update the existing runtime source guard, allowed companion membership and
  alias closure deliberately. Do not disable guards to permit a new module.

Useful fetched-source hashes for rechecking those exact revisions:

| File | SHA-256 |
| --- | --- |
| Bot `ds-bot/index.js` | `19839b15bda4ae5a09abb3f49588ea4e1725f09f8c90e892096081ea7c19491c` |
| Bot `ds-bot/src/host/channel.js` | `d04a16ad309b82a2bae339ed517544c15a7c2c1003fc503e2dd315d79475c802` |
| Remote `packages/plugin/src/plugin-route-bridge.ts` | `3cc309c729ad1e053e88500cad3c5d004c2b7ceba1aeb6476540df9db72a2cfc` |
| Remote `packages/plugin/src/plugin-route-dispatcher.ts` | `781ad6a071f220e3cae08a209011183a29c27857eec1d26acdb07d7eb8f704f4` |

Recompute and compare before use; these are research facts, not permission to
apply a patch to an arbitrary installed profile.

### D. Prove the path before native UI

Extend the existing isolated official-runtime fixture with a separate Bot test.
Use one synthetic, already-created bot and an adapter permitting **zero model
calls** for the read test. Assert the real authenticated route, exact current
session ownership, sanitized fields and no writes/agent starts/secret reads
caused by the request. Test unavailable and not-ready states, wrong workspace,
revocation, stale revision and unsupported endpoint.

Keep the original 47 captured Harness frames and provenance untouched. New Bot
evidence belongs in a separate fixture, captured from the actual pinned path;
do not manufacture it by renaming the existing session fixture.

The runtime fixture currently uses a complete isolated npm closure and a
disconnected, unprivileged Linux execution environment. Adding a package requires
reviewed registry integrity and lifecycle provenance, not a local `npm ci`.
Preserve source/process/environment guards and existing hard deadlines. Add the
new test to `vitest.config.mjs`; a file outside its include pattern does not run.

**Exit for this increment:** actual pinned Host dispatch reaches the passive
adapter, both native cores accept the same captured roster, a missing feature
cannot send the request, and all existing session/approval/Stop tests pass.

## Following increment: native read-only Bot screens

Use the existing connection, not a separate socket, executor or account flow.

| Platform | Integration points | Required behavior |
| --- | --- | --- |
| Apple | `RemoteHarnessClientGateway.swift`, `RemoteHarnessClientController.swift`, `RemoteHarnessView.swift` | MainActor ownership; independent roster loading/error state; negotiated refresh; discard stale callbacks |
| Android core | `RemoteHarnessClient.kt`, `RemoteHarnessClientModels.kt` | Existing owner-thread lifecycle; ephemeral roster plus bounded durable exact identity restrictions |
| Android app | `RemoteHarnessController.kt`, `ui/RemoteHarnessScreen.kt` | Dispatch through the existing `quenderin-remote-owner`; publish snapshots to Main |

Clear the roster on Host/workspace change or disconnect and refetch on recovery.
A roster error must not clear drafts/history, fail the session or disable Stop.
Display incompatible, unavailable, not-ready and disconnected states accurately.
Do not show a writable Bot composer merely because read support is available.
Navigating from a bot to its session requires current authoritative ownership;
the roster's display text never authorizes a mutation. The existing session
composer must remain view-only for a Bot-selected part. Persist the minimum
exact origin/Host-pin/workspace/session restriction so switching sessions or
relaunching cannot silently enable raw Harness prompts. This safety metadata is
separate from the ephemeral roster. Missing legacy fields decode safely; failed
writes preserve prior records and block new work.

Swift retains this restriction with its existing bounded saved-session records.
Android retains at most 128 immutable exact scopes without eviction. If a batch
would overflow, durably fill the remaining safety slots before rejecting the
whole new roster; never publish a partial roster. A saturated list requires
successful current classification before an unrecorded session becomes writable.
Supported Hosts also require current roster/session membership classification
before ordinary prompt or model changes. History, bound approvals and Stop have
their own existing authorization paths and stay available.

After this, follow product-plan phases 2–5: durable commands and typed questions,
then explicit memory/search and context continuity, then bounded teams and
schedules. Each mutation needs its own negotiated capability and tests; do not
extend the read capability to cover it.

## Verification recipes and evidence rules

Run from the task worktree. Before generated data, use session-storage and put
disposable outputs in its registered scratch. Do not delete source checkouts,
existing dependencies, user data or release artifacts during cleanup.

Small local checks permitted under the current constraints:

```sh
git diff --check
node --test native/remote-host/tests/*.test.mjs
python3 -B scripts/check_remote_harness_carrier.py
python3 -B scripts/check_remote_harness_fragments.py
python3 -B scripts/check_remote_harness_secure_link.py
python3 -B scripts/check_remote_harness_control_wire.py
python3 -B scripts/check_remote_harness_official_facts.py
python3 -B native/remote-crypto/tools/verify_build_gate.py --manifest-only
```

Pure JVM verification is a host fixture, not an Android native build. Use an
existing compiler and registered scratch (`BOT_VERIFY_SCRATCH` below); do not
download a toolchain or repurpose HOME:

```sh
kotlinc android/quenderin-core/src/main/kotlin/ai/quenderin/core/*.kt \
  android/quenderin-core/src/verify/RemoteHarnessBotReadVerify.kt \
  -include-runtime -d "$BOT_VERIFY_SCRATCH/bot-read.jar"
java -jar "$BOT_VERIFY_SCRATCH/bot-read.jar" \
  shared/remote-harness-bot-read-fixtures.json
```

Required affected hosted checks:

| Workflow | Evidence |
| --- | --- |
| `native-remote-sdk.yml` | Full Swift tests and actual unsigned Apple/Android apps linked to generated crypto SDKs |
| `remote-crypto.yml` | Rust/FFI probes and reduced real-backend Swift/Kotlin compilation closures |
| `remote-host.yml` | Pure Host tests, patched Remote bundle and existing official Harness journeys |
| `ci.yml` | Kotlin core/client/Bot verification and other existing PR regression checks |

The first three support manual dispatch. `ci.yml` currently does **not**; do not
recommend `gh workflow run ci.yml`. Before triggering runs, verify current public
repository status, standard runners, execution/storage bounds and actual triggers.
Do not create paid plans, larger runners or new deployment paths.

Two build traps must remain covered:

- The Kotlin crypto probe excludes `RemoteHarnessClient.kt` and
  `RemoteHarnessClientModels.kt`; low-level DTOs cannot depend on either.
- The Swift crypto probes use two explicit source lists. A new referenced DTO
  file must appear in both; a green Swift package test does not prove those lists.

Check missing/partial capabilities, concurrent describe responses, stale
generations, wrong workspace, exact Unicode identity, duplicate/oversized data,
timeout, duplicate result, malformed route envelope and journal count zero.
Then retain the existing approval-before-arguments, expired/duplicate approval,
Stop receipt versus confirmed stop and cold-history recovery checks.

Before any source publication, stage exact intended files and run:

```sh
git diff --cached --check
node scripts/verify_no_secrets.mjs --staged
python3 -B tools/secret_scan.py --staged
```

When extending the Swift journey fixture, wait for the request in the selected
socket's `pendingBotReads` queue before delivering a deferred response.
`botLoading` is published before asynchronous dispatch and is not an admission
barrier. `replyBotReads` deliberately throws on an empty queue. Before moving a
fake clock, complete an ordinary RPC round trip to settle preceding stream
acknowledgements. Keep the roster deadline journey's real five-second watchdog:
a stalled fake-clock test must fail and disconnect rather than occupy a runner
until its workflow timeout.

Do not mark rendered UI, signed storage, live enrollment, real inference or a
store release complete from these checks. Those remain explicit gates under the
user's current native-run restriction. No new variable-charge provider, relay,
scheduler or notification service is authorized by this brief.

## Foundation evidence

Implementation source: `ee499aaac936c8d31ce74974a9f89f50bb5bb6d8`, published to
[`codex/deepseek-bot-read-contract-20261024`](https://github.com/alikatgh/quenderin/tree/codex/deepseek-bot-read-contract-20261024).
The foundation evidence update changed documentation only; it did not change the
source tested below. At that publication the branch had not been merged; the
continuation status below records the current source-delivery state.

Completed for this increment:

- [x] Freeze the shared read contract and 22 synthetic fixture cases.
- [x] Implement the pure Host projection and matching native core operations.
- [x] Preserve the existing connection, session, approval and Stop paths.
- [x] Delegate bounded implementation to Sol 6.1 xhigh workers and integrate it.
- [x] Obtain a fresh read-only Sol review; fix its two material findings and
  recheck the affected paths. Swift now rejects a canonically equivalent but
  byte-different callback binding before parsing it. Kotlin now measures the
  original parsed object's UTF-8 bytes, including whitespace and escape expansion.
- [x] Independently audit this brief against the final APIs and workflow recipes.
- [x] Scan exact outgoing staged blobs with both repository secret scanners.

Local checks passed against this source: 82 Node Host tests; 40 Kotlin Bot cases
over the 22 shared fixtures; existing Kotlin carrier verification (39 fixtures,
28 behaviors); 130 client checks over 47 frozen runtime frames; and 21 Python
carrier/fragment/secure-link/control-wire regression tests. The reduced Kotlin
crypto source closure also compiled and passed the Bot checks. The four shared
wire checks, official capture/provenance check, crypto manifest gate, Swift
frontend parse and diff/Markdown checks passed. These are host/source checks,
not Android or Apple device runs.

Hosted checks use the same exact implementation revision:

| Run | Result and evidence |
| --- | --- |
| [Pinned remote Host integration](https://github.com/alikatgh/quenderin/actions/runs/40063003936) | Passed: 82 Host tests, patched bundle/bridge checks and existing official Harness fixture journeys, including approval and recovery. The provider in these journeys is synthetic. |
| [Remote crypto host fixtures](https://github.com/alikatgh/quenderin/actions/runs/40063006585) | Passed: 31 build-gate tests, nine Rust tests, generated Swift/Kotlin binding probes, linked Harness probes and production-backend loading probes. |
| [Native remote SDK and app linking](https://github.com/alikatgh/quenderin/actions/runs/40063009082) | Passed: 707 Swift tests with six skipped and zero failures, including the 13 new Bot tests; actual generated crypto SDKs; unsigned iPhone, simulator-SDK and Mac app builds; Android app/JVM-core build and packaged Noise/JNA/ABI/alignment verification. No simulator was booted. |

The six Swift skips are existing checks: four real local-model inference tests,
one pinned native capability check and the website asset-rendering test. All
13 new Bot tests ran and passed.

The full PR `ci.yml` suite was not run for this increment; the changed Kotlin
verifier and its existing core/client regressions were executed directly. No
model weights, local native builds, simulators, physical devices, provider calls,
signed releases, store submissions or live DS Bot runtime journeys were used.
Neither fixture success nor unsigned app linking establishes rendered UI or
operational Bot parity.

Session cleanup: the three disposable Kotlin test JARs (21,422,080 allocated
bytes) and their registered scratch directory were removed after verification.
Source worktrees and the earlier retained Host/FFI review sources remain in place.
The local session-storage ledger records their paths and retention conditions;
reassess those earlier review sources after live Host/native validation. Disk
headroom changed from 14,911,967,232 to 15,777,673,216 bytes while swap allocation
fell by 1 GiB; these are volume-wide observations, not attributed cleanup savings.

## Continuation status

- [x] Attach the passive route through the pinned official Host registries and
  authenticated Remote dispatcher, including mount/unmount and revoked trust.
- [x] Prove that reading already-created Bot state starts no model, bootstrap,
  refresh, secret, catalog or agent operation and writes no state.
- [x] Add native Bot lists, metadata, refresh and current-session history through
  the existing SwiftUI and Compose controllers. Keep unsupported/error states
  visible and ordinary Harness sessions usable.
- [x] Persist exact scoped Bot-session write restrictions across navigation and
  relaunch. Fail closed at bounded storage capacity; preserve existing drafts.
- [x] Isolate Swift roster deadlines from healthy session streams, approval and
  Stop. Preserve duplicate Android session rows without duplicate lazy-list keys.
- [x] Obtain independent Host and native reviews and resolve their findings.
- [x] Execute the integrated Swift tests on the hosted runner: 723 tests,
  six existing skips, zero failures at `b5cc7bc5607bb213c35ee67c18381bf65e65f077`.
- [x] Compile the Android app with its actual generated crypto SDK; subsequent
  test-only fixes leave its application source unchanged.
- [ ] Verify rendered/signed native interaction and a real enrolled Host.

The [pinned Host run](https://github.com/alikatgh/quenderin/actions/runs/40084776342)
passed at source `91f3bfa30a2af533c8663fa8e957fafdfac5725e`: 100 Host tests,
15 source/package guards, six process/environment guards, the patched upstream
compile/bundle, four bridge integration tests and three official runtime tests.
The latter install the pinned Bot store/channel with synthetic already-created
state through the official registries; they preserve the ordinary session,
approval, Stop and cold-history journeys. Full Bot startup, migrations, connectors
and real inference are outside this result.

The actual authenticated Bot response and its eight zero-valued effect counters
are preserved in `shared/remote-harness-bot-runtime-facts.json`, with source/run
provenance and raw-result SHA-256. Both native coordinator tests consume those
exact response bytes; the original 47 captured Harness frames are unchanged.
Primary verification of the current Kotlin source passed 210 client checks,
41 Bot cases over 22 shared fixtures and 39 carrier fixtures/28 behaviors. Swift
type checking and all 723 hosted tests now pass. The six skips remain the existing
local-inference/native-capability/asset-render checks; none of the new Bot tests
is skipped. The fixture evidence markers use bounded writes on stderr to keep
XCTest's output from splitting a success marker; the exact-once parser remains
unchanged.

Source delivery is [PR #182](https://github.com/alikatgh/quenderin/pull/182).
Its [checks](https://github.com/alikatgh/quenderin/pull/182/checks) are the current
gate for full CI, exact fixture evidence, crypto probes and unsigned native SDK/app
linking. Require those checks and independent review before merging; the PR
records the final source revision and merge state. Passing host-side tests and
SDK builds do not establish rendered UI, signed storage or a live relay journey.

The dependency lock also updates seven existing resolutions within their allowed
ranges to fix the current audit failures. Both clean hosted Node versions pass
their tests/builds; the exact lock's audit reports zero vulnerabilities. It adds
no dependency declarations, provider or service.

**Next product increment:** keep the existing read-only Bot history usable while
implementing phase 2's durable, Host-owned Bot command admission and explicit
questions/cards. Sending must not bypass Bot lifecycle via a raw Harness prompt.
Complete the real enrollment/native interaction gates under an authorized
validation route before claiming operational parity. This slice does not enable
Bot sending, memory, cards, teams, schedules or store submission.

Session cleanup removed all newly created Kotlin JARs, disposable logs, dependency
audit caches and the 29 public verification-download files after use. Captured
facts and source remain in the repository. The two earlier retained source-only
review assets (approximately 3.64 MiB and 384 KiB) and source worktrees remain;
no build output is retained for a hypothetical later review.
