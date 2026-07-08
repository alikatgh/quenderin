# World-class multi-step on a 4B — design doc

Status: approved for implementation. Drives the next implementation pass directly.

## 1. Goal

Make a multi-step agent mission on the shipped 4B (Qwen3-4B, mainstream default —
memory: agent quality is model-bound) feel like it *knows what it's doing* to a
non-technical user, without regressing the reliability guards that already exist
to keep a weak model from flailing, fabricating success, or stalling.

Two things must both be true at once:

- **WOW**: the run shows a real, honest, live-ticking plan — not a blank spinner
  followed by a wall of JSON.
- **Reliability**: nothing here may weaken the five existing guards (parse,
  stall, fabricated-success, zero-action, deliberation), and the new machinery
  must degrade to exactly today's behavior when it doesn't apply.

Target surface: `apple/QuenderinKit` (`AgentLoop.swift`, `AgentSession.swift`,
`AgentView.swift`). macOS-scoped. No Android/TS twin work required for the
backbone (see §7).

## 2. How multi-step works today, and where it breaks

(Full findings in the investigation; summarized here as the load-bearing facts.)

- **Decision precedence** `answer > plan > tool`, enforced at both the JSON
  parser (`AgentDecision.swift:36-56`) and the GBNF grammar
  (`AgentDecisionGrammar.swift:16-44`). A first-step-only `gbnfActionFirst`
  grammar blocks the `answer` production entirely to stop a weak model from
  bailing before trying anything — but only on step 1; step 2+ can still bail.
- **Fixed 6-step budget** (`AgentLoop.swift:52,97`), and every corrective
  `continue` (parse nudge, stall nudge, zero-action nudge) **burns one of the
  6 iterations**. A model that stumbles once on JSON formatting has already
  lost 15-30% of its working budget before doing real work.
- **`plan` bundles N tool calls into one iteration**, but `executePlan`
  (`CapabilityRunner.swift:188-237`) is strictly pre-flight-all-or-abort: one
  bad tool name discards the *whole* plan (`AgentLoop.swift:212-222`,
  "Plan not executed."); one aggregate approval; sequential execution with
  **no re-invocation of the model between steps** — a step that "succeeds"
  with a wrong result is never corrected mid-plan.
- **No progress memory.** The only state carried between iterations is a
  handful of scalars (`prevSig`, `lastObs`, `stall`, `parseFailures`,
  `toolAttempts`, `refusedAttempts`). The original goal is written **once**,
  at the very top of the transcript (`preamble`, `AgentLoop.swift:344-361`),
  and never re-stated. As `Used X(Y) → Z` lines and (if deliberation is on)
  `<think>` blocks accumulate, the goal drifts ever further from the prompt
  tail — the zone a small model attends to most. **This is the named root
  cause of multi-step drift on a 4B**, and nothing in the loop compensates
  for it.
- **Five existing guards, all worth preserving verbatim**: malformed JSON
  (2-strike halt), stall/repetition (fingerprint + 2-strike halt, refusal-aware),
  fabricated success (discard an answer if every tool attempt was refused),
  zero-action answer (nudge once, then halt on a computer-task goal answered
  with no tool use), and opt-in deliberation (`<think>` pass, best-effort,
  permanently grown into the transcript).
- **UI is a flat, append-only run log** (`AgentView.swift:52-84`). No upfront
  plan/checklist, no "step N of M" (maxSteps isn't even `@Published`), no
  per-step status icon — a step in the array just reads as "done", success or
  failure indistinguishable. `AgentSession` only assigns `steps` **once, at
  the very end** of the run (`AgentSession.swift:93` today) even though the
  loop already fires a live `onStep` callback — so the run log isn't actually
  live yet.
- **Toolkit-level chains are individually hardened** (calendar→note,
  clipboard→mail-draft, list→run-shortcut, reveal→open) with real live-caught
  fixes (docs.new hardcoded to stop URL hallucination, Mail launch-race
  retry, fuzzy tool-name matching). The 4-tool `open→observe→tap→type` GUI
  chain is the fragile outlier: `mac.ui.tap` has no scroll-to-find and refuses
  on ambiguous matches; `mac.ui.type` has no guarantee the prior tap actually
  focused a field; only `tap` has a `verify()` hook.

## 3. Approaches considered

| Approach | Wow | Reliability | Effort | Verdict |
|---|---|---|---|---|
| **Live Plan Checklist** — pre-loop NL plan decode, code-owned cursor, bounded re-plan-on-failure, live checklist UI | 7 | 6 | 3 | BLEND |
| **Reflexion Recovery** — failure-triggered `{"lesson":...}` decode, tail-pinned "what you learned" block, visible self-correction | 8 | 6 | 4 | BLEND |
| **Guided Recipes** — 3 curated tool-granular skeletons, end-of-transcript re-anchor, code-owned cursor bound to real tool execution, live checklist | 7 | 7 | 7 | BLEND |

Key judge findings that drove the blend:

- **End-of-transcript goal re-anchoring is the crown jewel**, present in some
  form in all three designs, costs **zero extra decodes**, and directly
  targets the named root cause. It belongs in every run, not just
  recipe-matched ones.
- **Approach 1's weakness**: advisory NL plan labels are decoupled from real
  tool execution; the code-owned cursor still advances one-label-per-iteration
  while a `.plan` decision executes N tools per iteration — mismatch produces
  confidently-wrong green checks, worse than no checklist. Also a net-new
  full decode before any action (added latency, not saved latency), plus a
  new `AgentDecision.checklist` case and two new grammars (twin-lock surface).
- **Approach 2's weakness**: the wow (amber glyph, "Learned →" line) is
  mostly derivable for **free** from the observation that already exists
  (the fuzzy-match hint is already appended to the transcript at
  `AgentLoop.swift:264-273`). The costly half — a 4B *writing* a correct,
  actionable lesson — is exactly the model-bound risk memory already flags
  (qwen3-4b weak); a wrong pinned lesson is a new failure vector. Effort was
  undercounted: needs a SHA-pinned grammar + a new stored `AgentStep.critique`
  field ported across three platforms (Swift/Kotlin/TS) plus parity vectors.
- **Approach 3's strength**: its ticks are the only ones that are *honest*,
  because each curated recipe step carries a `toolHint` and the cursor
  advances on an actual executed tool-name match, not a self-reported label.
  Its weakness (also cursor desync) is contained by design if — and only if
  — every recipe step maps to exactly one tool (no coarse multi-tool steps).

## 4. Chosen plan

**BLEND — "Guided Recipes as the honest backbone" + the two universal,
zero-extra-decode wins extracted from the other two approaches.**

- Take from **Recipes**: 3 curated, *tool-granular* (1 step = 1 toolHint)
  skeletons; honest code-owned cursor bound to real tool execution;
  budget-cap raised to fit; guard #6 (premature-victory-against-a-real-
  denominator).
- Take from **Live Plan Checklist / Reflexion**, the free halves only:
  (a) end-of-transcript goal re-anchoring for **every** goal, recipe-matched
  or not — this is the crown jewel and costs nothing; (b) universal per-step
  status glyph derived from the existing observation
  (`isPermissionRefusal` / new `isFailureObservation`) — works off-recipe too;
  (c) the "Learned → did you mean X?" UI line, sourced from the fuzzy-match
  hint that's *already in the observation string* — zero extra decode.
- **Explicitly deferred** (phase 2, not in this pass): the pre-loop NL plan
  decode (latency + desync + new grammar + twin-lock) and the reflexion
  self-critique *decode* (model-bound risk of a wrong pinned lesson + new
  stored field ported across 3 platforms). Both can be revisited once the
  backbone below is shipped and observed live.
- Deliberately **excluded from recipes**: the 4-tool
  `open→observe→tap→type` GUI chain. It's the documented fragile chain
  (no scroll-to-find, no type-target guarantee, only `tap` has `verify()`).
  Never stake the reliable demo on it.

### File-level implementation steps

1. **`apple/QuenderinKit/Sources/QuenderinKit/AgentRecipe.swift`** (NEW, `#if os(macOS)`)
   Pure/testable data model: `struct AgentRecipe { title, exampleGoal, steps: [Step] }`,
   `Step { title, toolHint: String, guidance: String? }`. Ship exactly 3
   tool-granular recipes:
   - *Morning brief*: `mac.calendar.today` → `mac.notes.create`
   - *Copy → Draft*: `mac.clipboard.read` → `mac.mail.draft`
   - *Find → Reveal → Open*: file-list → `mac.finder.reveal` → `mac.app.open`

   `static func match(goal:availableTools:)`: conservative per-recipe regex
   **AND** a `requiredTools` gate (every toolHint must be present) → `nil` on
   any miss. Builders: `preamble(recipe:)` (numbered skeleton + guidance, e.g.
   the docs.new URL note) and `nextStepLine(cursor:)` → e.g. `"Recipe
   <title>. Done: steps 1..k. Remaining: step k+1 <title> (suggested tool
   <hint>). Decide the single best next action."` — phrased to never say
   "redo".

2. **`apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift`**
   - After `goalNeedsAction` (~line 89): `let recipe = AgentRecipe.match(...)`;
     `let cap = recipe.map { max(maxSteps, $0.steps.count + 2) } ?? maxSteps`;
     loop `for _ in 0..<cap` (only ever raises the ceiling; nil recipe ==
     today, byte-for-byte).
   - **Universal re-anchor** (crown jewel, applies to every goal): each
     iteration, right before the decision decode, append to the transcript
     tail either `nextStepLine(recipeCursor)` (recipe matched) or a generic
     `"GOAL (still): <goal>. Actions taken so far: <toolAttempts>. Decide the
     single best next action."` (no recipe). Zero extra decode.
   - `var recipeCursor = 0`, advance-only: after a non-refused/non-error
     `.useTool`/`.plan` whose executed tool name matches the next remaining
     step's `toolHint`, advance; on a mismatch, **hold** (never retreat, never
     tell the model to redo — holding is honest; retreating would induce the
     exact stall the loop already fights).
   - **New guard #6** in the `.finalAnswer` branch (mirrors the zero-action
     guard at 152-161): `if let recipe, recipeCursor < recipe.steps.count,
     !nudgedForIncompleteRecipe { nudge with the next remaining step;
     nudgedForIncompleteRecipe = true; continue }`, then allow the answer on
     retry. Nudges once, never halts.
   - New pure static `isFailureObservation(_:)` keyed on **our own** stable
     capability error strings (`"No such tool"`, `"must include a valid to:"`,
     `"No shortcut named"`, `"NO_ACCOUNT"`, `"Tool error:"`, `"not executed"`)
     — deliberately excludes `"No events"` (a valid empty result, not a
     failure).
   - Thread `recipe` + `recipeCursor` out via a new
     `onProgress: @Sendable (AgentRecipe?, Int) -> Void = { _,_ in }` param on
     `run()`, called from `record()`.
   - No new `AgentDecision` case, no new grammar, no new blocklist entry.

3. **`apple/QuenderinKit/Sources/QuenderinKit/AgentSession.swift`**
   - Fix the assign-once deadness: wire an `onStep` closure into
     `loop.run(...)` that hops to `MainActor` and **appends** each `AgentStep`
     to `@Published steps` as it lands (the loop already fires this live —
     it's wire-up, not a refactor).
   - Add `@Published private(set) var activeRecipe: AgentRecipe?` and
     `@Published private(set) var recipeCursor = 0`, fed by `onProgress`.
   - Reset `steps = []`, `activeRecipe = nil`, `recipeCursor = 0` at the top
     of `run(goal:)` so no stale checklist survives into the next run.

4. **`apple/QuenderinKit/Sources/QuenderinKit/AgentView.swift`**
   - NEW `AgentRecipeChecklist`, rendered above the RUN LOG block when
     `session.activeRecipe != nil`: header `"<title> · Step N of M"`, one row
     per step with a fixed 16×16 leading status-glyph slot (done = teal
     check, active = small spinner, pending = hollow muted circle) — glyph
     and color change by status only, geometry never moves.
   - **Universal** per-step glyph in `AgentStepRow` derived from
     `step.observation` via `isPermissionRefusal` (lock) /
     `isFailureObservation` (amber triangle) / else (green check) — this
     upgrades every run, on-recipe or not.
   - Free reflexion line: below a failed row, if the observation already
     contains the fuzzy-match hint ("Did you mean X?"), render a copper
     "Learned → try X" line. Zero extra decode, sourced from existing
     observation text.
   - `AgentWorkingRow`: add the denominator + step title ("Working on step 2
     of 3 — Write the prep note").
   - Empty state: three tappable recipe cards that drop `exampleGoal` into
     the field.
   - Demote the flat RUN LOG to a collapsible "Details" disclosure when a
     recipe is active; keep it verbatim for power users.

5. **`apple/QuenderinKit/Tests/QuenderinKitTests/AgentRecipeTests.swift`** (NEW)
   Match precision (only the 3 intended goals, only with required tools
   present, no false trigger on an adjacent goal e.g. "what's on my calendar"
   alone must not match Morning-brief); cursor advances on toolHint match,
   holds on mismatch, never retreats; guard #6 nudges exactly once then
   yields; nil-recipe path leaves `cap == maxSteps`.

6. **`apple/QuenderinKit/Tests/QuenderinKitTests/AgentLoopTests.swift`** (extend)
   Re-anchor line present at the transcript tail every iteration, both
   recipe and generic goals; `cap` formula for both branches; regression
   assertion that all five existing guards still fire byte-for-byte.

7. **`docs/BUG_JOURNAL.md`** — append in the same commit as the fix (per
   global rule §1): the cursor-desync class ("advisory labels tick wrong;
   bind ticks to executed toolHint match, advance-only") and the assign-once
   live-log bug (`AgentSession.swift:93` assigned steps only at the end →
   stream via `onStep`). Add top-section scan-first bullets for both.

8. **`scripts/check_agent_parity.py`** — no code change; run as a gate. It
   enforces coverage bijection only over decision-parser + blocklist
   vectors, so this pass must stay green with zero vector edits — that's the
   proof the macOS layer never touched the shared decision contract.

## 5. Headline demo

**"Make me a prep note for today."**

The Morning-brief recipe matches instantly. A titled checklist draws before
the model finishes thinking: *"Morning brief · Step 1 of 2: Read today's
calendar / Write the prep note."* Row 1 flips from spinner to a teal check
as `mac.calendar.today` returns (a fixed date-bounded AppleScript that
returns cleanly even when empty). Row 2 ticks as `mac.notes.create` writes
the note (has a coded fallback for no-iCloud-account, and is undoable). Both
tools are independently hardened, so the demo lands every time on-device —
the user watches an honest 2-of-2 progression instead of a blank spinner
then a wall of JSON.

## 6. Tests

- `AgentRecipeTests`: match() precision (3 intended goals only, requires all
  tools present, no false triggers); cursor honesty (advance on match, hold
  on mismatch, never retreat); guard #6 nudges exactly once then yields.
- `AgentLoopTests`: universal re-anchor line present every iteration (recipe
  and generic); `cap = max(maxSteps, steps+2)` when matched, `== maxSteps`
  otherwise; full regression of all five pre-existing guards, byte-for-byte.
- `AgentSessionTests`: `steps` publishes incrementally via `onStep` (not only
  at the end); `activeRecipe`/`recipeCursor` reset at the top of every
  `run(goal:)`.
- `isFailureObservation` unit test: fires on our stable error strings; does
  **not** fire on `"No events..."` or on a permission refusal (that's
  `isPermissionRefusal`'s job).
- Parity gate: `scripts/check_agent_parity.py` exits green with **no vector
  edits** — proves the recipe layer never touched the shared decision
  contract.

## 7. Risks

- **Cursor desync is the one real joint**, flagged by all three judges on
  every checklist-shaped design. Mitigated by construction: (a) recipe steps
  are tool-granular (1 step = 1 toolHint, no coarse "write the draft" spanning
  many tools); (b) cursor advances only on an actual executed toolHint match
  and never retreats — a miscount holds truthfully rather than telling the
  model to redo (which would induce the exact stall the loop already
  fights); (c) the re-anchor line says "decide the single best next action",
  never "redo step k"; (d) guard #6 nudges once then yields — a miscount
  costs at most one wasted nudge, never a false halt.
- **Coverage is honest, not Potemkin.** Only 3 goals get the full titled
  checklist; every other goal reverts to the flat run log. But the derived
  per-step glyph and the universal goal re-anchor upgrade *every* run,
  recipe-matched or not — the wow is scoped, the reliability win is not.
- **Live `onStep` plumbing is real reactive work**, contained to
  `AgentSession` with MainActor hops and a per-run state reset to avoid a
  stale checklist bleeding into the next run.
- **Deferred work is deliberately deferred, not dropped**: the pre-loop NL
  plan decode and the reflexion self-critique decode both carry model-bound
  risk (a 4B writing a wrong plan/lesson) and twin-lock cost that don't pay
  for themselves yet. Revisit after this backbone ships and is observed live.
- **The fragile GUI chain is intentionally not a recipe** until `verify()`
  hooks land for `mac.ui.type` — don't stake the reliable demo on
  tap/type/canvas-AX weakness.

## 8. Twin note

The core of this plan needs **nothing** from the Android/Kotlin twin, by
deliberate design. `AgentRecipe`, the checklist UI, the live status glyphs,
guard #6, and the recipe cap are all macOS-scoped (`#if os(macOS)`) and add
no new `AgentDecision` case, no new grammar, no new blocklist entry.
`scripts/check_agent_parity.py` enforces coverage bijection only over
decision-parser + blocklist vectors, so it stays green with **zero vector
edits** — no `android/AgentLoop.kt` or `capabilityAgent.ts` port required for
the backbone.

The one cross-platform-*behavioral* item is the universal goal re-anchor
text (the generic `"GOAL (still): ..."` tail line): it's plain advisory
prompt text — no JSON key, no grammar production — so it cannot break
parser-level parity, but for true behavioral parity it should eventually be
ported to `android/AgentLoop.kt` and
`src/services/capability/capabilityAgent.ts`. Only add a matching id to
`shared/agent-parity-vectors.json` if and when a future parity vector
asserts on preamble/transcript assembly (none does today). Recommendation:
keep recipes explicitly out of the twins (macOS UX layer only); port the
re-anchor line if/when Android grows the same live-checklist surface — diff
the twin first, per the cross-platform-twin-drift memory rule, before
porting anything.
