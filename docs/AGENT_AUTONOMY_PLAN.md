# Local Autonomous Computer Usage — the internal plan

**Status:** draft 0.1 (2026-07-05). Internal engineering doc, not user-facing. The
user-facing version of this direction is the four-stage [roadmap](../website/roadmap.html);
this file is *how we build it*.

**Mission (stated by the owner, recorded in memory — sharpened 2026-07-05):** the GitHub
tagline says "run LLMs locally" but the real mission is **local autonomous computer usage**,
meaning literally: *the user tells Quenderin what to do, and Quenderin operates the computer*
— plans the steps, moves the files, does the chore — with a **local model** as the brain.
The competitive frame is **Claude Cowork / cloud computer-use agents**: same "you say it, it
does it" product, with the one guarantee they structurally cannot offer — the entire session
(your files, your screen, your intent) never leaves the machine. Local LLMs are the
foundation; this agent is the destination and the paid tier.

**Mission surface (sharpened 2026-07-05):** the target is **anything possible inside macOS**
— say a thing, Quenderin does it on your Mac, locally. That is reached NOT by one "run any
script" hole (unbounded blast radius; can't be previewed, consented, or made reversible; fails
App Store review and every principle in §3) but by a **growing library of governed, typed
capabilities** over macOS's real automation surfaces — AppleScript/Apple Events (Calendar,
Mail, Notes, Reminders, Finder, Safari, Messages, and System-Events UI-scripting of ANY app),
Accessibility, and shell. Same Shortcuts model: breadth of safe actions, never an escape hatch.
First macOS capabilities shipped on the TS spine — `mac.calendar.today` (T1 read),
`mac.reminders.add` (T2 write, approved), both AppleScript-injection-safe (escapeAppleScriptString
+ execFile). The `MacAutomation` seam is where the library grows.

**The product bet, stated honestly:** local models are weaker than cloud frontier models, so
we do NOT win by out-reasoning Claude. We win on the chores people won't upload their
filesystem for, by making the *harness* carry the intelligence: narrow deterministic
capabilities, previews before writes, per-run approval, undo, a ledger, a kill switch. A
bounded chore ("organize this folder", "rename these by date") needs reliability and trust,
not genius — and reliability and trust are architecture, which we control.

---

## 1. The lodestar: Apple bought Workflow, not "an AI that clicks things"

In 2017 Apple acquired **Workflow** and shipped it as **Shortcuts**. The lesson isn't the
automation — it's the *shape* of the automation that both users and platform reviewers
trust:

1. **Composable, named actions.** A workflow is a visible list of discrete steps, each with
   a name and inputs. Not a black box that "does stuff."
2. **OS-mediated consent.** Every capability that touches something sensitive (photos,
   location, a specific app) prompts through the OS permission system, once, visibly.
3. **The user can read the plan before it runs.** Preview, edit, dry-run.
4. **Reversibility and legibility over cleverness.** Shortcuts is deliberately *not* an
   agent that improvises with your filesystem; it's a set of audited primitives you compose.

Our differentiator on top of that: **the planning is done by a local LLM, and no step ever
phones home.** So the north star is: *the agent proposes a Shortcuts-style plan of named,
consented, reversible actions; a local model fills in the reasoning; the user stays in the
loop; nothing leaves the device.*

This is also the App Store survival strategy. A free-roaming Accessibility-driven agent on
mobile is an instant rejection (and a genuine malware vector). Composed, consented, mostly
desktop-scoped actions are reviewable.

---

## 2. Where we actually are today (honest inventory)

| Piece | File(s) | State |
|---|---|---|
| Agent loop (plan → tool → observe) | `apple/.../AgentLoop.swift`, `AgentSession.swift`, `AgentDecision.swift`; desktop `src/services/agent/*` | Works. Parses a decision, calls one tool, feeds the result back. |
| Tool protocol | `apple/.../AgentTool.swift` (`name` + `run(input) async throws -> String`) | Minimal, clean. Pure-compute tools only. |
| Shipped tools (store apps) | `CalculatorTool`, unit convert, date calc (`AgentToolsExtra.swift`, `src/services/tools/*`) | **No side effects. No device access.** By design. |
| Device automation (desktop testbed only) | `src/services/agent/actionExecutor.ts`, `providers/desktop.provider.ts` (robotjs), `android.provider.ts` (ADB) | Research only. Can read a screen, click, type. **Never shipped in store apps.** |
| Safety gate | `apple/.../SafetyBlocklist.swift`, `src/services/agent/actionExecutor.ts` BLOCKLIST | Hard keyword block on financial / destructive / credential actions. |
| The product split | `docs/PRODUCT.md` | Store apps = pure-tool agent; desktop = device-controller. The split is currently *permanent*. This plan revisits it deliberately. |

**Two problems the inventory surfaces immediately:**

- **The two blocklists have drifted.** Swift has `venmo`, `cvv`, `seed phrase`; the desktop
  TS list has `place order`, `revoke`, `deactivate`, `confirm purchase`. They must become
  one canonical list under `shared/` with parity vectors (same discipline as the router /
  catalog). This is prerequisite work — a safety list that differs per platform is a bug.
- **The tool protocol has no notion of risk, consent, reversibility, or preview.** Every
  tool is treated identically. That's fine for a calculator; it's unacceptable the moment a
  tool can write a file. The capability model below is the core new abstraction.

---

## 3. Design principles (the load-bearing part)

These are non-negotiable and every later decision derives from them:

1. **On-device or it doesn't ship.** Planning, perception, and action all run locally. An
   action that requires a network call is out of scope for the core promise. (Reaching a
   user-configured local service — their own files — is fine; reaching *our* server is not,
   because we have none.)
2. **Every capability declares its blast radius.** Read-only vs. writes vs. irreversible;
   which resource; whether it's in the safety blocklist domain. The runtime gates on this
   declaration, not on the tool's good behavior.
3. **Consent is per-capability, granted by the user, and legible.** Mirror the OS/Shortcuts
   model: first use of a capability prompts; the grant is remembered per capability, shown
   in settings, and revocable. Consent claimed in an LLM's output is never valid (this is
   the same instruction-source rule the assistant itself follows).
4. **Preview before act, for anything that writes.** The agent produces the *plan* of named
   actions first; the user sees it; only then does it execute. Dry-run is the default for
   new capability classes.
5. **Reversible by default; irreversible actions are a separate, louder tier.** Prefer
   move-to-trash over delete, copy over overwrite, staged over in-place.
6. **A hard kill switch and a full audit log.** Stop ends the run within one action (we just
   fixed the *chat* equivalent — Q-005 — for exactly this reason). Every action taken is
   written to a local, user-readable ledger: what, when, what it touched, what it returned.
7. **The blocklist can only grow.** Same rule as today. Financial, destructive, credential
   actions are refused without explicit per-instance human confirmation, regardless of plan.

---

## 4. The capability ladder

Tiers, each strictly gated. We climb one rung at a time and never skip.

| Tier | Example capabilities | Gate |
|---|---|---|
| **T0 — Pure compute** (shipped) | calculator, unit/date, text transforms | none — no side effects |
| **T1 — Read-only perception** | read a file the user points at, read the clipboard, describe an image, list a folder | one-time consent per capability; nothing written |
| **T2 — Reversible local writes** | write to a scratch file, move-to-trash, draft (not send) a message, rename with undo | preview + per-capability consent; reversible; audit-logged |
| **T3 — App/system actions** | drive an app via automation APIs, fill a form (not submit), organize files | preview + explicit per-run confirmation; desktop-first; blocklist enforced on every target |
| **T4 — Irreversible / sensitive** | permanent delete, submit/send, anything blocklist-adjacent | **never autonomous** — always a discrete human confirmation per instance, or refused |

The public roadmap's "Stage 2 (perception)" ≈ **T1**; "Stage 3 (the agent grows hands)" ≈
**T2–T3**; "Stage 4" is T3 composed fluently with the kill switch and ledger making it
trustworthy. T4 is the permanent fence.

---

## 4b. A worked example — the request that stress-tests everything (2026-07-05)

The owner gave a representative real user request to reason against: *"read a list of users
from a Google Doc, find each one in the imo app running on BlueStacks, send a friend request
+ a message, wait for their reply, and write the replies into an existing Google Sheet."*
It is the perfect forcing case because it **breaks in five different ways**, each teaching a
design truth:

1. **Read the list (Google Docs) / 5. write results (Google Sheets)** — these are *someone
   else's cloud*, not local files. Two honest options: (a) the user exports to a local file
   and we use `fs.read` / write a local CSV they re-import — fits our model perfectly, zero
   new architecture; (b) integrate the Google API with the user's own OAuth — a real
   departure that adds network + auth but where the *AI* still never sees a vendor. We start
   with (a); (b) is a "connectors" project, opt-in per service, never the default.
2. **Find each user in imo on BlueStacks (steps 2–3)** — this is **GUI-driving a third-party
   app**, the T3 tier we keep in the desktop testbed. One genuine insight: BlueStacks speaks
   **ADB**, and our Android provider already drives Android via ADB (uiautomator view-tree +
   `input tap`), so this is UI-tree-driven, not pixel-driven — far more tractable than
   driving a physical phone screen. BUT: reliably grounding "tap the Add-Friend button in an
   arbitrary chat app" is a **vision/grounding task, and small local models are weakest
   exactly here.** This is the hard edge of the harness-over-model bet: folder ops are fully
   harness-able (deterministic); driving imo is irreducibly model-heavy. Honest limit.
3. **"Get the answer from the users"** — you send, then a *human* replies minutes-to-days
   later. That is a **durable, resumable, polling, long-lived task** — a completely different
   execution model from our synchronous bounded loop. Needs a "watch & resume" daemon
   (the desktop testbed's `backgroundDaemon` gestures at it). New architecture.
4. **Sending friend requests + templated messages to a LIST** — textbook **bulk outreach**,
   almost certainly against imo's ToS (client automation), and the exact shape our safety
   architecture exists to gate. Not financial/destructive/credential, so the blocklist
   doesn't catch it — but "message N strangers" needs its own high-friction gate: explicit
   per-recipient-batch confirmation, rate-limiting, and product framing that this is for
   *your own contacts/community*, not growth-hacking. This likely stays desktop-only and
   is NOT a marketed store-app capability.

**The privacy claim, corrected by this example.** The task sends data to Google and imo — so
"nothing leaves the machine" is imprecise. The TRUE, defensible claim is **"no AI middleman":
the model reasoning over your doc, your contacts, and your plan runs locally; a cloud agent
would stream all of that to its vendor's datacenter, ours streams it to no one.** Google and
imo see what you already gave them; no AI company gets a copy. Market this precisely — the
whole project is honesty-first, and "nothing leaves the machine" next to a flagship demo that
messages people via imo is a credibility landmine.

**Where this sits:** ~T3, plus two capability *classes* we don't have (app-GUI-driving,
opt-in cloud connectors) and one execution model we don't have (durable watch-and-resume).
The realistic **smallest real version** to build toward: read a local CSV → drive
BlueStacks-imo via ADB with per-recipient approval + rate limit → append results to a local
CSV. That strips the two cloud integrations and the async-wait (poll-once, or a manual
"collect replies" second run), keeps it on the local-file + local-ADB spine we already have,
and is honestly demoable. Everything past that (Google connectors, background watch, reliable
GUI grounding) is named, sequenced work — not a weekend.

---

## 4c. How we go 100x better than cloud Cowork (the competitive thesis, 2026-07-05)

We do NOT win on model IQ — a cloud frontier model out-reasons a local one per step, and
that's the honest limit (§4b: grounding is model-heavy, our weak spot). We win on the axes a
LOCAL, governed agent structurally dominates, and for real chores these matter more than raw IQ:

1. **Instant kill switch.** A cloud agent's "stop" halts the remote brain but can't un-fire an
   action already dispatched to your machine. Ours checks a LOCAL signal between every step and
   simply doesn't run the next one — no round-trip, immediate, mid-task. (Shipped: AbortSignal
   through `CapabilityRunner.execute`/`executePlan` and `CapabilityAgent.run`; a plan halts
   between steps with the done work still ledgered.)
2. **Total legibility.** Every action — and every REFUSED action — is on a local, append-only
   ledger the user owns. A cloud agent's reasoning is a remote black box; ours is a file you read.
3. **Reversibility, incl. whole-task undo.** Writes never overwrite/delete; each records its
   inverse. And an entire agent run is transactional: `RunSession` records every undoable
   mutating action, so "undo this task" reverses them all LIFO (shipped for mac.reminders.add /
   mac.notes.create; any capability that declares `undo()` plugs in). Stop + this + the ledger =
   "stop, review, roll back" — the trust loop a cloud agent can't offer for local changes.
4. **Consent + preview.** Nothing mutating runs without a per-run yes over a truthful preview
   (fail-closed). The plan is read before it runs — Shortcuts-grade, model-agnostic.
5. **Privacy = no AI middleman.** The model reasoning over your files/screen/intent is local;
   a cloud agent streams all of it to its vendor. This is the moat for compliance buyers.
6. **Works offline; zero marginal cost; no rate limits.** No tokens billed per action, no
   throttling, no outage — it's your CPU.

**The strategy that follows:** keep making the harness carry reliability (verification of its
own actions, retrieval of known-good sequences, rate-limits on bulk actions) so a weak model
becomes a TRUSTWORTHY agent, and keep widening the governed capability library so "anything"
grows. Trust + breadth + privacy, compounding — that's the 100x, not a smarter model.

---

## 5. Platform strategy

**Desktop first.** macOS and Linux have real automation surfaces (Apple Events/AppleScript,
Accessibility with user grant, shell, filesystem) *and* the user-trust context for them
(it's their computer, they installed a dev tool). The Electron testbed already proves the
mechanics. T1–T3 land on desktop.

**Store apps stay bounded — but the fence moves from "T0 only" to "T0–T1".** `docs/PRODUCT.md`
currently makes the pure-tool agent permanent on mobile. That's too conservative now:
read-only, consented perception (T1 — "read this PDF I'm sharing", "what's in this image")
is store-reviewable and genuinely useful. T2+ device automation stays desktop-only, as
today. This is a *deliberate* revision of PRODUCT.md, not a drift — update it in the same
change that ships T1 on mobile.

**Monetization tie-in (recorded in memory):** T0–T1 are free (funnel + credibility). The
paid "Pro" tier is T2–T3 autonomy on desktop — the capability cloud agents structurally
cannot offer, because ours never leaves the machine. That's the pitch to
compliance-sensitive buyers (legal/medical/finance).

---

## 6. The technical spine: a `Capability` abstraction

Today's `AgentTool` (`name` + `run`) is too flat. Proposed evolution — a `Capability` that
*declares* what `run` will do, so the runtime can gate before calling it. Shape (Swift; the
Kotlin twin mirrors it, parity-vectored):

```
protocol Capability: Sendable {
    var id: String { get }                 // stable, e.g. "fs.read", "fs.trash"
    var tier: CapabilityTier { get }        // T0…T4
    var blastRadius: BlastRadius { get }     // .none | .read(Resource) | .write(Resource) | .irreversible(Resource)
    var requiresConsent: Bool { get }        // T1+ → true
    /// A human-readable preview of what running with `input` WOULD do — no side effects.
    func plan(_ input: String) async throws -> ActionPreview
    /// Execute. The runtime guarantees consent + preview + blocklist already passed.
    func run(_ input: String) async throws -> String
}
```

The **runtime** (an evolution of `AgentLoop`) enforces, in order, before any `run`:
1. Blocklist check on the resolved target (unified shared list).
2. Tier/consent check — is this capability granted? If not, prompt (never auto-grant).
3. `plan()` → show `ActionPreview` → require confirmation for T2+.
4. Execute, append to the **audit ledger**, honor the kill switch between actions.

`plan()` is the Shortcuts "you can read the steps before running" property, made mandatory.

---

## 7. Milestone 0 — what to build first (one sprint, fully verifiable)

Deliberately small, desktop-first, and testable on *this* machine — no device farm needed:

1. ✅ **Unify the blocklist** (done 2026-07-05) — `shared/safety-blocklist.json` is canonical;
   `scripts/check_safety_parity.py` enforces exact set-equality across the Swift/Kotlin/TS twins
   in CI. The three lists had drifted (desktop carried 7 keywords the twins lacked, missed 16 of
   theirs — audit Q-014); now one 34-keyword list. The desktop matcher was upgraded to
   camelCase/underscore-aware word-boundary tokenization so it can safely carry the full
   vocabulary (`pin`/`bank`) without firing on `spinner`/`bankruptcy` while still catching
   `confirm_transfer_btn`. All three suites green.
2. ✅ **Introduce `Capability`** (done 2026-07-05) — refines `AgentTool` on both twins
   (`Capability.swift` / `Capability.kt`) with `CapabilityTier` (T0–T4), `BlastRadius`,
   `ActionPreview`, and a T0 default so the four shipped tools (echo, calculator, unit, date)
   became capabilities with a one-word conformance change and zero behavior change. Also lands
   the safety spine's decision function, `CapabilityGate.assess()` — PURE, no side effects:
   blocklist → consent → preview, returning `.blocked` / `.needsConsent` / `.allowed`. It
   already composes the unified blocklist from step 1. Verified: Swift 256 tests, Kotlin
   CoreVerify ALL PASSED (a synthetic T1 capability exercises the consent path ahead of `fs.read`).
3. ✅ **`fs.read` core** (done 2026-07-05) — `FileReadCapability` on both twins. The security
   property lives in the `grantedFiles` seam: only user-picked files enter the map, so the
   model can NAME a granted file but can never mint a path (tested: an existing on-disk path
   from "model output" resolves to nothing). Read-only, 64 KB-capped, strict-UTF-8, exact/
   case-insensitive name resolution with deliberately NO fuzzy matching. **Not yet registered
   in the app's tool list** — per the advertised-but-unimplemented rule it registers together
   with the attach UI + capabilities pane (step 5), which also swaps the app to
   `FileAuditLedger` + `UserDefaultsConsentStore`.
4. ✅ **The audit ledger + runner** (done 2026-07-05) — `AuditEntry`/`AuditLedger` (in-memory +
   JSONL file impl; a crash-torn last line is skipped, prior entries survive — tested), and
   `CapabilityRunner`: the single enforcement point (gate → refuse/run → ledger). `AgentLoop`
   now routes every `Capability` through it on both twins, so every agent action — including
   refused ones — gets a ledger row. T0 behavior unchanged (suites pin it).
5. ✅ **The user-facing surface** (done 2026-07-05) — the loop is closed end to end:
   - **Attach** (paperclip + chips on the Agent screen, `.fileImporter`) — the ONLY door into
     `fs.read`'s granted map; `AttachedFilesStore` keeps the UI mirror and the lock-protected
     snapshot the agent reads.
   - **Settings → Agent**: every capability with its tier in plain words ("reads what you
     attach"), consent toggles for T1+ (T0 shows "Always on"), and the activity feed — the
     last 10 ledger rows including refusals, with "Show the full ledger in Finder".
   - **`AgentToolkit`** is the ONE list both the app's AgentSession and the pane read, so the
     pane can never drift from what the agent actually has. The app now runs on
     `UserDefaultsConsentStore` + `FileAuditLedger`.
   - End-to-end test: attach → refused (no consent) → grant → reads the file → ledger rows
     `[needsConsent, allowed]`. **Milestone 0 is complete.**

**Milestone 0 shipped 2026-07-05 — all five steps.** The safety spine (one blocklist,
declared blast radius, gate → run → ledger, user-owned consent) is real, tested, and carries
its first genuine capability.

## Milestone 1 — documents-as-text in chat ✅ (shipped 2026-07-05)

Roadmap Stage 2's first deliverable, no engine work needed. Both twins:
- **`AttachedDocument`** on `ChatMessage`: the bubble shows chips + the typed text; the model
  gets `engineText` (labeled document + message), recomposed into every windowed history pass
  so follow-up questions keep the document in context, and counted by the token budget.
- **`DocumentTextExtractor`**: extraction AT ATTACH TIME (what the model sees is fixed on
  send) — strict UTF-8 with a visible refusal for binary, 24 KB cap with a truncation marker.
- **Chat attach UI (Apple)**: paperclip + pending chips in the composer, chips on sent
  bubbles; a documents-only send ("summarize this") is legitimate. Android core is at full
  parity (send/persistence/extractor); the Compose attach UI rides the Android UI backlog.
- **Persistence, backward-compatible on both formats**: optional `documents` in the JSON rows
  (Apple), extra escaped fields per row in the TSV (Android) — pre-Milestone-1 transcripts
  decode unchanged, verified by tests.

## Milestone 2 — the workspace: the first WRITE ✅ (shipped 2026-07-05)

The first true "operate the computer" slice — the Cowork-class core loop (grant → plan →
approve → act → undo), both twins:

- **The workspace** (`WorkspaceStore`): ONE folder the user grants via the folder picker
  (folder button on the Agent screen; chip + revoke). One at a time on purpose — a small
  local model reasoning about one bounded directory is predictable.
- **`fs.list` (T1)**: the perception half of "organize this folder". No input arguments a
  model could get creative with.
- **`fs.move` (T2 — the first write)**: "«file» to «subfolder»", plain names only (paths and
  `..` rejected on shape), **never overwrites**, creates the destination folder, and records
  every move in the **`UndoJournal`** ("Undo last move" on the Agent screen plays the inverse).
- **The per-run approval gate** (`CapabilityRunner.approve`): a mutating action requires the
  user's yes for THIS run — standing consent is not enough. **Fail-closed**: a surface with no
  approver wired refuses every write. On the Agent screen it's a confirmation dialog fed by
  `ApprovalBroker`; dismissing without answering counts as NO. Ledger decisions now include
  `needsApproval` and `declined`.
- T2's undo model resolved as designed in §9: move-back + no-overwrite + create-don't-replace
  = "reversible enough" for v1; a transactional undo stack stays future work for T3.

Verified: Swift 276 tests / Kotlin CoreVerify ALL PASSED — including fail-closed, declined,
collision-refusal, and hostile-path cases. Android Compose UI rides the existing backlog.

## Milestone 3 — plan preview: one approval for the whole plan ✅ (shipped 2026-07-05)

The Cowork UX: the model proposes `{"plan":[{"tool":…},…]}`, the user sees the numbered
previews and approves ONCE, the runner executes sequentially. Both twins:

- **`AgentDecision.plan([ToolCall])`** — parity-vectored (3 new vectors: parses, strict
  one-bad-item-kills-the-plan, answer>plan>tool precedence; `check_agent_parity.py` green
  at 14/14 on both platforms). Kotlin gained a depth-1 `extractArray` matching its
  top-level-only key discipline.
- **`CapabilityRunner.executePlan`** — all-or-nothing pre-flight (blocklist + consent +
  preview per step BEFORE anything runs; a blocked step refuses the whole plan without ever
  reaching approval), ONE aggregate approval when anything mutates (fail-closed), sequential
  execution with per-step ledger rows, honest stop-on-failure ("stopped after step N of M").
- Run log + exporter render plan steps; the preamble teaches the model the plan shape.

Verified: Swift 279 tests / Kotlin CoreVerify ALL PASSED (incl. one-approval-for-two-moves,
declined-plan-changes-nothing, blocked-step-never-reaches-approval, scripted end-to-end).

**Post-M3 additions (2026-07-05):** `fs.rename` + `fs.trash` shipped on the same spine, both
twins (trash = the workspace's VISIBLE Trash/ folder, not the system trash — identical
semantics everywhere, undo moves it back, nothing is ever deleted). PDF text extraction
shipped on Apple via PDFKit (page-by-page, cap-aware, textless scans refused honestly);
**Android's extractor remains text-only** — a dependency-free PDF parser doesn't exist, so
that gap is recorded here and rides the Android backlog. The public roadmap/dev-log now
tell the Stage-3 story. Remaining: the Android Compose UI catch-up (standing chip).

## Milestone 4 — operate an APP, not just files (2026-07-05)

The reusable core under every "drive an app" task (the imo/BlueStacks forcing example, §4b),
built where device automation belongs: the **desktop** TypeScript app, over the hardened ADB
`AndroidProvider`. The desktop had ADB muscle but NO governance — so the real work was
**porting the Capability spine to TypeScript** (`src/services/capability/`: capability.ts,
runner.ts, safety.ts) and putting app-driving behind it, identical invariants to the
Swift/Kotlin twins.

- **`app.observe` (T1)** — read the current screen's tappable elements. Perception half.
- **`app.tap` (T2)** — tap BY VISIBLE LABEL, never coordinates (the fs.move principle: the
  model names what it sees, can't fabricate a pixel). Resolves label → element → center;
  ambiguous/unknown labels refuse. **Defense in depth**: the resolved element is re-checked
  against the blocklist, so a button reading "OK" that is `confirm_payment_btn` is refused
  even after approval.
- **`app.type` / `app.key` (T2)** — type into the focused field / press back·enter·home.
- All T2 → per-run approval, **fail-closed** (no approver ⇒ refused). A friend-request plan
  [tap → type → enter] runs under ONE aggregate approval — the Cowork loop, on a real app.
- The safety blocklist got ONE canonical TS home (`capability/safety.ts`); ActionExecutor
  imports it; `check_safety_parity.py` repointed. Still 34/34 across all four surfaces.

Verified: 255 TS tests (9 new, driven by a fake ADB provider — no emulator needed), lint
clean, safety-parity green. **Desktop-only** by design (§5): app-driving never ships in the
store apps. Wired into a **governed agent loop** — `CapabilityAgent` (capabilityAgent.ts), the TS twin
of the native AgentLoop but over capabilities through the runner: a local model proposes a
tool / plan / answer (same JSON shape + answer>plan>tool precedence + strict-plan +
first-object H13 guard as `AgentDecisionParser`), everything mutating goes through the gate.
Proven end to end by a scripted planner driving the fake imo screen: propose friend-request
plan → ONE approval → tap "Add friend" → type → enter → answer. Distinct from the legacy
`AgentService` raw-action research loop, which stays the testbed; this is the path that ships.
The production ASSEMBLY is now wired: `createGovernedAgent(deps)` (desktopAgent.ts) builds the
whole governed loop from injected seams — `llmPlanner` adapts the real LlmService into the
planner (plainChat, no tool preamble); mac/device seams add the capability library; consent,
ledger, approver, session, bulk-threshold, and the kill-switch signal all plug in. Proven end
to end with a fake model driving real AppleScript templates through the real runner, then
undoAll(). The ONLY production-only surfaces left: swap the fake LLM for LlmService, the fake
mac for OsascriptAutomation, and wire the Electron approval dialog to `approve`. Nothing else
changes — that's the spine paying off. It also has its FIRST real user invocation: `quenderin do "<goal>"` (CLI) — the real LlmService
plans, a terminal y/N prompt is the approval dialog, Ctrl+C is the kill switch, undo is offered
at the end, all governed. So the whole stack is runnable on a Mac today from the command line;
the Electron GUI is now a nicer front-end for a loop that already works, not a prerequisite.
Remaining: the Electron approval dialog (a prettier `approve`) + the Android Compose catch-up.

**Post-M4 gap-fill — file hands for the CLI agent (2026-07-05):** the flagship chore class
("organize my downloads") literally *couldn't run* on `quenderin do` — `fs.*` existed only in
the Swift/Kotlin apps, so the desktop TS agent had app-driving and mac.* but **no file
capabilities at all**. Closed it with `fileCapabilities.ts`: `fs.list`/`fs.read` (T1) +
`fs.move`/`fs.rename`/`fs.trash` (T2), same structural safety as the native twins — a granted
**workspace** folder, plain names only (no paths, no `..`), **never overwrite**, and Trash is
a *visible subfolder* (never a real delete). Every write implements `undo()` so it plugs into
the session rollback — a move + a rename in one run both reverse LIFO through `undoAll()`.
Wired into `createGovernedAgent` (a `workspace?: () => string | null` seam) and exposed on the
CLI as `quenderin do --workspace <dir>`, which also lets the file half run **off macOS** (the
first cross-platform slice of the agent). Verified: 320 TS tests (11 new — temp-dir
round-trips, no-overwrite, path-traversal rejection, session rollback), lint + both parity
guards green.

**Post-M4 — the review pillar surfaced (2026-07-05):** the trust loop is stop · **review** ·
undo · consent · preview. Every action was already *persisted* to `~/.quenderin/agent-ledger.jsonl`,
but nothing could *read it back* — the one pillar with no CLI. Added `quenderin history`: a
local, private, tamper-evident log of exactly what the agent did to this machine (newest-first,
per-decision glyphs — ✓ ran / ✗ blocked by safety / ✗ you declined / ○ skipped — with input +
outcome), which a cloud agent structurally can't offer. Renderer is pure (`ledgerView.ts`,
entries → string, no clock/fs) so it's unit-tested headless; the command is a thin reader over
`FileAuditLedger`. Verified: 326 TS tests (6 new), lint + parity green.

**Post-M4 — the lodestar delivered: run the user's Shortcuts (2026-07-05).** §1 says the win is
"Apple bought Workflow, not an AI that clicks things." `mac.shortcuts.run` (T3) invokes one of
the user's EXISTING, self-authored Apple Shortcuts **by name**, behind per-run approval — so
"anything possible in macOS" is reached through the user's own automation library (home control,
file ops, API calls, device toggles), NOT a "run arbitrary script" hole: it can't create or edit
a shortcut, only call one that already exists. Paired with `mac.shortcuts.list` (T1) so the model
names what it can see (the fs.list → fs.move / app.observe → app.tap discipline). Optional text
input via `"<name> | <text>"`, escaped through `escapeAppleScriptString`; the shortcut's output is
captured back. No undo (a shortcut's effects are arbitrary and it says so in the preview), and a
blocklisted name (e.g. "Pay Rent") is refused at the gate like any other input. This is the single
highest-leverage capability for the mission — one typed, governed door onto the whole Shortcuts
surface. Verified: 335 TS tests (9 new — approval gating, injection break-out, blocklist refusal,
input passing, output capture, missing-shortcut), lint + parity green.

**Post-M4 — undo made durable across sessions (2026-07-05).** The trust loop's `undo` only worked
*inside the run that made the changes* (`RunSession` is in-memory). The biggest remaining trust gap:
crash, or say "no" then change your mind, or realise an hour later it mis-filed something → no
recourse. Closed with `quenderin undo`: each `do` run that leaves reversible changes persists a tiny
journal (capability name + input, + the workspace dir for fs.* actions) to `~/.quenderin/agent-undo.json`;
a FRESH process reloads it and `replayUndo` rebuilds each capability *by name* from the same
factories the agent uses, reversing them LIFO through the exact same `undo()` the live session would.
Best-effort (a failed reversal is reported, the rest still roll back); the journal is validated
row-by-row on load (on-disk = untrusted) and cleared after a successful undo so it can't double-apply.
Proven end to end: process A moves a file + writes the journal, process B (nothing but the journal)
moves it back. This is transactional undo of your local machine, an hour later, in a new session —
something a cloud agent structurally cannot offer. Verified: 348 TS tests (11 new), lint + parity green.

**Verification:** all of steps 1–2, 4 are pure logic → unit tests + parity, runs in CI
today. Step 3's consent/preview/ledger flow is testable headless (inject a fake file
picker). No new inference or device dependency. Feature-flagged off by default until the
pane exists.

**Explicitly NOT in Milestone 0:** any write, any app automation, any mobile change, any T2+.
Prove the safety spine on the safest possible capability first.

---

## 8. How this maps to the audit

The 2026-07-04 audit's agent-relevant findings feed straight into this:
- **Q-014** (blocklist substring false +/-) and the two-list drift → solved by the unified
  shared blocklist + parity in Milestone 0.
- **Q-024** (no agent cancel/stop) → the kill-switch principle (§3.6); do it as part of the
  runtime, same shape as the chat Q-005 fix we just shipped.
- **Q-D02** (desktop agent UI vs native) → the capabilities pane + preview UI is the chance
  to make the agent surface first-class, not an afterthought.
- **Q-222 / Q-264** (hostile JSON in agent decisions) → the runtime's `plan()`/consent gate
  is where we harden decision parsing, since that's now security-critical, not cosmetic.

---

## 9. Open questions (decide before T2)

- **Undo model for T2 writes** — do we implement a real transaction/undo stack, or lean on
  move-to-trash + copy-don't-overwrite as "reversible enough"? (Leaning latter for v1.)
- **How the local model expresses a plan** — structured tool-call JSON (what we have) vs. a
  richer plan DSL. Start with what exists; revisit if multi-step plans need it.
- **Consent granularity** — per capability, or per (capability × resource scope)? Start
  per-capability; tighten if a capability's blast radius is too broad to grant wholesale.
- **The PRODUCT.md revision** — get explicit owner sign-off that T1 (read-only perception)
  is allowed in store apps before shipping it there.

---

## 10. The one-line summary

Build a **Shortcuts-shaped agent whose brain is a local model**: named, consented,
reversible, previewable actions, an append-only audit ledger, a hard kill switch, and a
blocklist that only grows — climbing the capability ladder one verifiable rung at a time,
desktop-first, with nothing ever leaving the machine. Start by proving the safety spine on
`fs.read`.
