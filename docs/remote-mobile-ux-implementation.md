# Native remote mobile improvements and Stop parity

Date: 26 October 2026. Status: source implemented, verification in progress; no store submission.

## Scope and source

Adopt the useful mobile-control ideas from [dsh-mobile-maxxing 0.5.0,
revision 650279c](https://github.com/kuraneko1/dsh-mobile-maxxing/tree/650279c1b0b93a6fc0e80cb56cca34bbb208d0c1):
attention-aware notifications, device-local presentation settings, readable code,
session navigation and multilingual/input regression coverage. Keep native SwiftUI
and Compose, the existing pinned-Host connection and authoritative history.
This work supplements `deepseek-bot-integration-plan.md`; it does not activate
MAX or add another agent loop. No upstream implementation is copied; preserve
upstream MIT notices if source or fixtures are reused later.

Remote UI source starts at main `abc2af0d9fd9c872861d2fadec14c7e35b384bb1` in
`codex/remote-mobile-ux-20261026`. OpenCode's independent Stop fix starts at
`e89cfc906bccb7f2322aba09217a41f2b24cf37e` in its existing
`codex/max-mobile-bindings-20261025` checkout; its pre-existing ancestry needs its own review
and must not be smuggled into a source release by this assignment.

## Owners

- Codex coordinator: shared attention contract, fixtures, documentation,
  independent review, integration and permitted hosted verification.
- Android worker: Remote Harness core/app UI, scoped drafts, presentation
  preferences, safe Markdown, session copy and foreground reconciliation.
- Apple worker: corresponding native Remote UI/preferences/lifecycle and tests.
- Existing OpenCode CLI: **only** Stop/settlement/persistence parity described
  below. Its terminal session is reused; no replacement app/session is required.

Platform workers must not modify ChatModel, ConversationCoordinator, MAX, build
workflows or each other's platform. OpenCode must not modify remote UI/contracts,
parsers, model runtimes, filters, engine protocols or release configuration.
All workers preserve others' edits and return exact revisions and test evidence.

## Remote implementation checklist

The checked items below describe source implementation; hosted/native evidence
is recorded separately at the end of this document.

- [x] Android drafts are bound to origin, pinned Host, workspace and session;
  migrate the existing selected draft without silently transferring it elsewhere.
  Bound storage; capacity or write failure preserves all existing drafts.
- [x] Scoped pending IME updates and Send cannot target a session selected after
  the callback was created. A -> B -> A and restart restore the correct drafts.
- [x] Both remote histories reuse native assistant Markdown/code rendering.
  Unsafe URL schemes stay inert; exact raw tool text/code remains copyable.
  Large details do not displace Stop or approval controls.
- [x] Add a native Copy session ID action. No unauthenticated bare-ID routing
  or automatic destination switching is introduced.
- [x] Store presentation preferences on this device only. Text sizing and code
  wrapping must not write Host settings, alter execution permission or add a
  model call. Unimplemented delivery controls must not appear enabled.
- [x] Foreground recovery is coalesced and bounded, reuses Host pin checks and
  authoritative history, preserves drafts and never resends uncertain mutations.
  Healthy active streams are not torn down on every foreground transition.
- [x] Define matching Swift/Kotlin attention-event policies: exact destination,
  current connection generation, bounded event identity/deduplication, expiry,
  historical-event suppression, and opt-in foreground/background presentation.
  Notifications are hints; opening an approval revalidates current Host evidence.
- [x] Add representative CJK/punctuation/code and keyboard/lifecycle fixtures.
  Preserve original transcript bytes; never rewrite code to repair Markdown.
- [x] Independent review and final source checks pass at the integrated revision.
- [ ] Hosted Swift/Kotlin and native app compilation pass for that revision.
- [ ] Rendered/signed native journeys and actual push delivery are verified later
  through a separately authorized route; October's no-device/no-simulator rule
  remains in force.

### Notification delivery boundary

The existing Host stream can provide attention events while connected. System
push delivery when the app is suspended/terminated needs a separately reviewed
APNs/Android delivery path and device enrollment/revocation. Do not claim that a
local policy or foreground banner proves background delivery. No new relay,
provider account, paid fallback or push service is activated by this source work.
Default payloads contain generic copy and opaque identifiers, never credentials,
questions, file paths, transcript excerpts or reasoning. No approval is executed
from a notification payload. Reconnect/history correctness cannot depend on push.
The new attention policy is currently a tested-contract foundation, not connected
to an OS notification surface. Delivery preferences and banners are not enabled
by these files. The actual stream adapter must negotiate and validate the event
before setting its policy input's authentication flag; it defaults to false.

## OpenCode assignment: Stop settles one owned partial

Work only in `/Users/s_avelova/Documents/projects/quenderin/.worktrees/max-mobile-bindings-20261025`.
Baseline `e89cfc9`; branch `codex/max-mobile-bindings-20261025`. Make a separate
local commit for this assignment. A second worktree attempt hit ENOSPC and Git
removed the failed checkout; reuse this already-existing checkout instead.

Implement the user's supplied Stop parity plan, treating its algorithm as a
proposal to verify rather than a reason to bypass existing ownership rules.
An explicit Stop must retain generation ownership until the existing turn has
settled all accepted pre-Stop text exactly once. A concurrent Send is a no-op
during settlement. Navigation still abandons the partial and invalidates late
callbacks. Idle Stop retains queued-admission rejection. Repeated Stop cancels
the engine once. Do not claim cancel latency is below 500 ms without measurement.

Allowed production files:

- `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ChatModel.kt`
- `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ConversationCoordinator.kt`
- `apple/QuenderinKit/Sources/QuenderinKit/ChatModel.swift`
- `apple/QuenderinKit/Sources/QuenderinKit/ConversationCoordinator.swift`
- Narrow paired ChatSettlement/ConversationCoordinator tests in the same modules.

Add a content revision only for actual transcript changes. Persistence must
observe a consistent completed-message/revision snapshot and record saved
revision only after durable save success. Do not invoke an engine callback while
holding a lock that the callback needs. Check navigation ordering carefully:
Stop followed by New/Back must not persist an abandoned partial accidentally.

Required paired fixtures:

1. A flushed repeated-paragraph wall stops and settles to `P` on both platforms.
2. A buffered `part ` + `ial` tail survives Stop as `partial`.
3. Send during settlement is a no-op; Send after settlement appends normally.
4. Zero-token Stop leaves the same empty bubble with no empty-response notice.
5. Stop then navigation abandons the partial; stale settlement never writes it.
6. Persist during settlement receives exactly one corrective save when content
   changes; reopen shows collapsed text. Unchanged text preserves one-save tests.
7. Save failure does not advance saved revision; retry preserves durable data.
8. Existing idle-Stop, queued-admission, failed-send, repeated-persist, Stop/Back/New
   and filtered-backend regressions stay green; frozen tests are not weakened.

Keep engine/filter/capability semantics and MAX disabled state unchanged. Commit
the narrow increment locally, report exact diff and verification, then wait for
the coordinator's independent review. Do not push ancestry, merge, start CI or
release independently. No local native builds, Swift runtime harnesses, model
weights, SDK installs, simulator/device runs or credential access. Bounded JVM
and source checks may use managed scratch; clean generated output after use.
Current disk pressure allows source edits only until the coordinator restores a
bounded verification route. Do not free space by deleting existing user files.

## Verification and release record

### OpenCode checkpoint review, 26 October

`73de70e87bc7ecc2fc1d725ee7c43e39c331780e` is a local six-file checkpoint,
not a verified release. Independent source review found these required corrections:

1. A superseded Android generation must not clear the current generation's Stop flag.
2. A zero-callback stopped turn must ignore a non-streaming return received after Stop.
3. The final Android transcript event must remain valid when the main-thread UI
   consumes it after settlement closes the generation revision.
4. Stop, interim save, then navigation must overwrite the saved partial with the
   shorter completed transcript on both platforms.
5. The Swift actor test fixture must satisfy the synchronous nonisolated cancel
   requirement without an unsafe cancellation counter.
6. Add cancellation-error cases; an explicit Stop must preserve its accepted
   partial even when the engine ends through its error channel. Preserve normal
   unstopped error handling.

OpenCode owns these narrow corrections and deterministic buffered-tail,
post-Stop-token, repeated-Stop, queued-delivery and overlapping-generation tests.
It must keep the existing production/test ownership, make a local checkpoint,
and return evidence before any push. Source parsing is not a compiled test.
The coordinator queues tasks in the existing CLI session without automatically
resuming inference; no billing setting is changed.

The earlier `e89cfc9` Apple and Android hosted jobs were confirmed successful in
[run 40254737571](https://github.com/alikatgh/quenderin/actions/runs/40254737571).
That evidence does not cover `73de70e` or subsequent corrections.

### Remote mobile verification

- Passed: five Python attention-gate tests; 57/57 shared attention cases executed
  exactly once in the Kotlin runner and passed the evidence checker.
- Passed: 259 Android remote-controller journey checks against synthetic
  account/relay/crypto and 47 captured official-runtime frames. Compilation first
  found a duplicate test variable; renaming that new variable fixed the issue.
- Passed: 12 pure Kotlin Markdown presentation checks, including exact CRLF code
  copying, Unicode pagination, and bounded malformed-input fallback.
- Independent attention-policy source review found no concrete defect; matching
  Swift execution is still required.
- Platform review found draft/recovery/receipt and formatting-budget defects;
  all identified source corrections and focused regressions are implemented.
  Android and Apple corrections passed repeat source review. A final held-receipt
  case asserts exact UTF-8 preservation for a Unicode-equivalent subsequent edit.
- Hosted compilation and rendered/native interaction remain pending.

Local source/JVM checks, hosted compilation, actual native interaction,
provider inference and store availability are separate evidence categories.
Use synthetic fixtures for development. Before any permitted source push,
inspect triggered workflows and the exact outgoing ancestry, run the secret
scan, obtain independent review for state/concurrency/security changes, and
record the tested revision. Store submission remains deferred.
