# Q-549 — Legacy `AgentService` vs the governed capability path: analysis & migration options

**Status:** design analysis (no code change). The finding is real but the fix is an architectural
migration, not a mechanical swap — this doc scopes it so it can be greenlit and done as a focused effort
rather than rushed into the security-critical device-driving path.

## The finding

> Q-549 (P1): the dashboard drives the device through the legacy `AgentService`
> (`src/services/agent.service.ts`), not the fail-closed governed path (`createGovernedAgent` /
> `CapabilityRunner`, `src/services/capability/`).

## The two agents are different execution models — not two implementations of one thing

| | **Legacy `AgentService`** (dashboard, WS `start`) | **`createGovernedAgent`** (CLI `quenderin`, capability spine) |
|---|---|---|
| Model | Continuous **observe → decide → act** loop over a live screen | **Planner picks discrete capabilities** from a typed list |
| Unit of action | a raw `click(x,y)` / `type` / `scroll` on a UI element | a `Capability` (`fs.move`, `app.tap`, `mac.ui.click`, …) with a `plan()` preview |
| Action count / goal | many (dozens of taps) | few (each a meaningful, approvable step) |
| Reversibility | none — you cannot un-tap a button | `RunSession` undo for reversible capabilities |
| Safety today | `assertGoalSafe` (goal blocklist) + per-action `checkSafety` (element/coord blocklist, incl. touch-slop Q-550) + pause/intervene + hard-stop kill switch (Q-523) + `maxSteps` + wall-clock cap + mission metrics | per-run **approval (fail-closed)** + persisted **consent** + **audit ledger** + **bulk brake** + **undo** + dry-run |

**Why the dashboard doesn't already use the governed path:** the governed model asks for approval of each
*discrete mutating capability*. A continuous UI-automation loop performs dozens of fine-grained taps per
goal; per-tap approval is unusable, and undo is meaningless for a tap. So the dashboard uses a *different,
appropriate* safety model (blocklist + pause + kill-switch + caps), not an inferior one. The finding's
implicit "just call `createGovernedAgent`" does **not** hold as a drop-in.

## What the dashboard agent genuinely LACKS vs the governed path

Feature-by-feature — which governance features fit a continuous device agent, and which don't:

1. **Per-action approval (fail-closed)** — *partial fit.* Per-*tap* approval is unusable. But a
   **per-run** "approve this mission's plan/goal before it drives your device" gate, and/or approval
   gates on *high-consequence* actions (an action whose target element trips a softer "confirm" list),
   would fit and would close the biggest gap. The blocklist already *refuses* the worst; there is no
   *approve-to-proceed* step for the merely-risky.
2. **Audit ledger** — *good fit, portable.* The dashboard logs mission-level metrics but not a per-action
   ledger (what was tapped, when, decision). A `CapabilityRunner`-style ledger of device actions is
   additive and low-risk, and would give the same "flight recorder" the governed path has.
3. **Bulk brake** — *good fit, portable.* `maxSteps`/wall-clock bound runtime but not *change volume*.
   A "you've performed N device actions this mission — continue?" brake mirrors the capability runner's.
4. **Consent store** — *fit.* Which device/automation surfaces are enabled could be a persisted grant
   (like the capability consent toggles) rather than implicit in "the daemon is running".
5. **Undo** — *no fit.* Device taps aren't reversible; skip.

## Recommended path (incremental, lowest-risk first — NOT a rewrite)

Do **not** replace `AgentService` with `createGovernedAgent`; the loop model is right for the surface.
Instead, port the governance features that fit, smallest-blast-radius first, each behind a test:

- **Step 1 — Audit ledger (additive, safe).** ✅ **DONE (2026-07-06).** `AgentService.actionLedger` is a
  bounded (`InMemoryAuditLedger(500)`) flight recorder; every executed action is recorded with its
  decision (allowed / failed / blocked / error) + the goal, secret-redacted. Read-only (adds no gate) and
  surfaced at token-gated `GET /api/agent/ledger`. No behavior change. Tests: recording (allowed +
  safety-blocked) and the route (401 / entries).
- **Step 2 — Bulk brake (additive, one gate).** After N device actions in a mission, emit a
  `bulk_confirm` event and pause until the user approves continuing (reuse the WS pause/intervene
  channel that already exists). Mirrors `passesBulkGuard`.
- **Step 3 — Per-run approval mode (opt-in).** A settings flag that requires the user to approve a
  mission's goal (and, later, a soft-confirm list of higher-consequence actions) before the loop drives
  the device. Fail-closed when enabled.
- **Step 4 (optional, larger) — unify the ledger/consent types** so the dashboard agent and the
  capability spine share ONE governance vocabulary (the real "consolidation"), without merging their
  execution loops.

Steps 1–2 are safe, testable, and independently shippable. Step 3 is a real UX/security decision (default
on or off? which actions are "high-consequence"?) and needs the owner's call. Step 4 is the largest and
should follow 1–3.

## Why this is deliberately not coded here

Rewiring the device agent's safety model is security-critical and user-facing. A rushed change at the tail
of an audit sweep is exactly where a regression (an approval gate that dead-locks the loop; a ledger that
serializes the hot path) would land. Each step above deserves its own change + test. Greenlight the step(s)
you want and they can be implemented in a focused pass.

*Recorded 2026-07-06 as part of the R21–R31 audit fix-sweep. See `docs/BUG_JOURNAL.md`.*
