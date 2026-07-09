# Cross-platform agent-loop parity audit

**Date:** 2026-07-08
**Scope:** the three hand-ported "twin" governed agent loops —
- macOS/iOS Swift — `apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift` (reference / product)
- Android Kotlin — `android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentLoop.kt`
- Windows/Linux/CLI TS — `src/services/capability/capabilityAgent.ts`

**Method:** three per-platform behavior maps (one reader each) → behavior-by-behavior diff → each
divergence categorized DRIFT-BUG / INTENTIONAL / PLATFORM-CONSTRAINT / BENIGN. (The map phase ran as a
workflow; the diff + fixes were completed inline after the workflow hit an infrastructure stall — the
cached maps were salvaged from its journal.)

---

## What MATCHES across all three (the shared spine is intact)

- **Goal re-anchor** ("CROWN JEWEL") — appended to the transcript tail every turn, byte-identical text
  on all three (`GOAL (still): … Actions taken so far: N. Decide the single best next action.`).
- **Decision parsing + precedence** — `answer > plan > tool`, strict all-or-nothing plans, first-balanced-
  object extraction. Enforced by the shared parity vectors (`scripts/check_agent_parity.py`, 19/19 green).
- **Stall guard** — signature compare, nudge on the 1st repeat, halt `stalled` on the 2nd.
- **Parse-failure guard** — nudge once, halt `planError` on the 2nd consecutive failure.
- **Plan (`.plan`) execution** — per-step safety gate before anything runs; unknown tool ⇒ whole plan rejected.

## CONFIRMED DRIFT — fixed this pass (TS was behind the native twins)

Both were later-added reliability guards that flowed to iOS + Android but never back to the desktop
`CapabilityAgent` (which powers Windows/Linux). Neither needed a new halt reason.

| Drift | macOS / Android | TS (before) | Fix |
|-------|-----------------|-------------|-----|
| **Zero-action guard** | On an ActionIntent goal, an answer with 0 tool calls is nudged once, then halts honestly | **Absent** — accepted a bare "Done" over no work as `answered` | Ported `ActionIntent` (identical patterns) + the guard → nudge, then `planError` |
| **Anti-narration preamble line** | "Use {answer} ONLY for the completed final result — never for narration…" | **Absent** | Added the same line (TS vocabulary: "…use a capability first") |

New: `src/services/capability/actionIntent.ts` (twin of Swift/Kotlin `ActionIntent`), the guard in
`capabilityAgent.ts`, and tests (`tests/action-intent.test.ts`, 3 new cases in `capability-agent.test.ts`).
520 TS tests green, typecheck clean.

## INTENTIONAL / PLATFORM divergences — on the record, NOT drift

- **Recipes + dynamic planning** — macOS/iOS only, by design (a UX layer; see
  `docs/audits/2026-07-08-dynamic-planning.md` and `memory:dynamic-planning-scope`). The shared spine is
  the re-anchor, which IS twinned.
- **`needsPermission` halt + the "all attempts refused ⇒ withhold" fabricated-success guard** — present on
  iOS/Android, deliberately NOT on TS. **ATTEMPTED 2026-07-08 and REVERTED — this is a genuine intentional
  difference, not drift. Do NOT re-attempt without a product decision.** The faithful native port (add a
  `needsPermission` halt + refused-attempt tracking, withhold any answer when every attempt was refused)
  was implemented and immediately broke **3 existing tests across 2 surfaces** — `dashboard-tasks.test.ts`
  (fail-closed: no renderer / disconnect mid-approval) and `platform-capabilities.test.ts` (a user *declines*
  on Windows). Those tests encode a DELIBERATE TS behavior: on an all-refused run the loop returns the
  model's own **honest** answer (e.g. "Okay, I did not open it.") as `answered`, rather than a structured
  `needsPermission` banner. The native guard can't distinguish an honest "I couldn't" from a fabricated
  "done" — it fires on all-refused regardless — so porting it would override honest decline answers on those
  surfaces. The test ripple was the signal; reverted. If this is ever revisited it's a cross-surface product
  decision (what should a *user decline* show?), not a parity bugfix.
- **Sampling / GBNF grammar** — the Swift loop carries Qwen3 sampling recipes + grammar-constrained decoding;
  Android/TS decode through their own engine seam. Platform-constraint, not drift (the anti-narration line
  matters *more* where the grammar makes narration a legal `{"answer"}` — i.e. Swift — but is good guidance
  everywhere, hence the port).

## Verdict

The shared reliability spine is consistent across all three platforms. Two genuine drift bugs (TS missing
the zero-action guard + anti-narration line) are fixed and tested. One residual TS gap (made-but-refused
fabricated-success) is a documented intentional-scope item, not silent drift.
