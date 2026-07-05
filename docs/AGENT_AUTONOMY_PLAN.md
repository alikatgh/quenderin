# Local Autonomous Computer Usage — the internal plan

**Status:** draft 0.1 (2026-07-05). Internal engineering doc, not user-facing. The
user-facing version of this direction is the four-stage [roadmap](../website/roadmap.html);
this file is *how we build it*.

**Mission (stated by the owner, recorded in memory):** the GitHub tagline says "run LLMs
locally" but the real mission is **local autonomous computer usage** — an AI that does real
work on *your* machine, with the same guarantee as chat: nothing leaves the device. Local
LLMs are the foundation; autonomy is the destination and the paid tier.

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

1. **Unify the blocklist** into `shared/safety-blocklist.json` + parity vectors +
   `scripts/check_safety_parity.py` (CI). Both platforms load the same list. *This is the
   prerequisite and it's pure cleanup — do it first.*
2. **Introduce `Capability`** alongside `AgentTool` (don't break existing tools; adapt them
   as T0 capabilities with `.none` blast radius).
3. **Ship one real T1 capability: `fs.read`** — "read this file the user explicitly selected."
   Consent-gated, read-only, audit-logged. On desktop it reads a path the user picked via a
   file dialog (never a path from LLM output). This exercises the entire spine — consent,
   preview, ledger — with zero write risk.
4. **The audit ledger**: a local append-only JSON the user can open, one row per action.
5. **A capabilities pane in Settings**: list every capability, its tier, its grant state,
   revoke buttons. (Reuses the settings pattern we just built.)

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
