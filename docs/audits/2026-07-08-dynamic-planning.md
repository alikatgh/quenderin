# Dynamic planning for the agent loop

**Date:** 2026-07-08
**Status:** SHIP-BEHIND-FLAG (not DO-NOT-SHIP — see feasibility verdict below)
**Scope:** `apple/QuenderinKit/Sources/QuenderinKit/{AgentLoop,AgentRecipe,AgentView}.swift`, macOS-only, no twin.

---

## 1. The question

Today `AgentRecipe.match(goal:)` (AgentLoop.swift:98) only fires for 3 hardcoded
regex recipes. Every other goal — the long tail — gets **no plan, no checklist,
no denominator**: the 4B re-derives "the single best next action" from scratch
every turn under a generic tail line (AgentLoop.swift:129), with `stepCap ==
maxSteps` and zero standing trajectory. The agent looks hardcoded because,
outside 3 demo goals, it is: the model's own planning intelligence is never
engaged, only its per-turn reactive tool pick.

Can we let the model **author the plan** for arbitrary goals — genuinely using
its intelligence, not more regex — without reintroducing the two things that
make LLM-authored plans dangerous: (a) a checklist that ticks green when
nothing actually happened, and (b) a wrong upfront plan actively steering a
weak 4B worse than having no plan at all?

---

## 2. Approaches considered (red-teamed)

All three were red-teamed against the actual source (`AgentLoop.swift`,
`AgentRecipe.swift`). All three came back **BLEND** — none shippable as
originally proposed.

| # | Approach | usesIntelligence | reliability | honesty | latency | Verdict |
|---|----------|:-:|:-:|:-:|:-:|:-:|
| 1 | **Model-planned dynamic recipe** — one grammar-constrained pre-loop decode emits `[{tool,label}]`, wrapped as a dynamic `AgentRecipe` through the existing seam. New bespoke GBNF grammar (enum-alternation of tool names). | 8 | 5 | 6 | 7 | BLEND |
| 2 | **Discovered plan** — no decode at all; checklist grows one row per tool the model *already* reactively picks; row greens off the same success-gate the shipped cursor uses. | 3 | 6 | 6 | 9 | BLEND |
| 3 | **Dynamic Recipe Fallback** — one bounded decode, but reuses the **already-shipped** `AgentDecisionGrammar.gbnf` (its `plan` production already exists) and derives step titles from each tool's `purpose` string, never from model prose. | 8 | 5 | 7 | 7 | BLEND |

**Why not #1 (new bespoke grammar):** real planning and honest-by-construction
ticks, but it authors a *new* GBNF grammar and a *new* free-text `label` field
that the tick doesn't validate — "Send email ✓" can be bound to
`mac.calendar.today` and still show green. That's Critique-1 re-imported: a
confidently-wrong check to a non-technical user, even though the underlying
tool-executed proof is technically true.

**Why not #2 (discovered plan) as the base:** it doesn't plan. By its own
design there is "nothing to decode ahead of action" — `usesIntelligence: 3`.
It fails the deliverable outright, though its two instincts (zero added
decodes; status driven by the same observation classifier the shipped cursor
uses) are worth keeping.

**Why not #3 as originally written:** all three reviewers converged on the
same fatal, verified-in-source flaw — see §3.

### The shared fatal flaw (verified in source, drives the redesign)

The modal case for *any* real-planning design is **"valid-but-wrong plan"**
(real tools, wrong order/selection) — and that's precisely the regime a weak
4B is worst at, because it's exactly the long tail no static recipe covers.
Today's code turns a wrong plan into an **active regression**, not a no-op:

1. `nextStepLine` (AgentRecipe.swift:104-105) injects `"Next is step k — use
   <wrong tool>"` into the transcript **tail** — the zone the 4B attends to
   most.
2. `advanceRecipe` (AgentLoop.swift:112-117) is **advance-only**: a diverging
   model leaves the cursor stalled, so that *same* wrong suggestion is
   hammered on **every subsequent turn**, not just once.
3. `stepCap` rises to `max(maxSteps, N+2)` (AgentLoop.swift:100), funding
   *more* flailing while it does so.
4. An under-decomposed plan that fully greens triggers `"all steps are done,
   give the final answer now"` — a **premature-victory** push a neutral
   reactive loop never has.

So "purely advisory, can never make a run worse" is false as written. This is
the thing to fix, not a footnote.

---

## 3. Chosen plan

**HYBRID:** keep the 3 curated recipes as the zero-decode fast path. Add a
**hardened** version of Approach 3 for the long tail — one bounded pre-loop
decode authors a tool-name chain, validated and wrapped as
`AgentRecipe(isDynamic: true)`, flowing through the existing
`AgentRecipe.match(...) ?? planDynamically(...)` seam. Four hardening moves
neutralize the wrong-plan regression from §2 so the downside collapses to
"≈ today + one capped decode." Ships **behind a flag, OFF by default**
(mirrors `AgentDeliberation`).

### verdictOnFeasibility: **SHIP-BEHIND-FLAG**

Not a clean SHIP: value on the real qwen3-4b, in exactly the regime it's
weakest (per memory: `agent-quality-is-model-bound`), is **unproven**. Flag
gating is not a formality here — it's the actual risk-management mechanism.
If live telemetry shows plans are usually wrong, the honest move is to leave
the flag off or remove the feature, not to force default-on. Not DO-NOT-SHIP
because every hardening move is a bounded, reversible degradation to
already-shipped behavior (see risk residuals in §5) — there is no scenario
where shipping dark makes today's reactive loop worse.

### Why Approach 3 is the base, not Approach 1

Approach 3 reuses the **already-shipped** `AgentDecisionGrammar.gbnf`
(confirmed: its root already permits the `plan` production,
`AgentDecisionGrammar.swift:17-19`) — zero new grammar, zero new
`AgentDecision` case, zero twin-lock. Step titles/guidance are derived from
each tool's existing `purpose` string, so the model authors **zero free-text
prose** — this is what kills Approach 1's label-lie ("Send email ✓" bound to
the wrong tool) by construction, not by validation.

---

### File-level implementation steps

**1. `AgentRecipe.swift` — dynamic recipe type + parser**
Add `public let isDynamic: Bool` (default `false`; existing static `.all`
recipes stay `false`). Add macOS-scoped
`static func parsePlan(_ calls: [ToolCall], tools: [AgentTool], maxSteps: Int) -> AgentRecipe?`:
- filter each call to `Set(tools.map(\.name))` (mirrors the toolset gate at
  line 69, so the `==` at `AgentLoop.swift:114` can fire);
- collapse **consecutive duplicate tools** to keep the 1-step-== 1-tool
  invariant;
- clamp to `<= maxSteps` (defeats a hallucinated 20-step plan);
- reject (`nil`) if fewer than 2 valid steps survive.
- Each surviving step → `Step(title: derived-from-tool.purpose, toolHint:
  exact registered name, guidance: tool.purpose)` — **never** the model's
  free text.
- Wrap as `AgentRecipe(title: "Plan", exampleGoal: goal, steps:, isDynamic:
  true)`.

**2. `AgentRecipe.swift` — self-abandoning re-anchor (H2 + H4)**
Split `nextStepLine` by `isDynamic`:
- Dynamic suggestion phrased as abandonable: `"Next likely step k — <title>
  (try <toolHint>; if a different tool clearly fits better, use that
  instead)."` — not the curated path's firm "suggested tool."
- In the `cursor >= count` branch, replace `"all steps are done, give the
  final answer now"` with a goal-anchored `"the planned steps ran — confirm
  the goal is actually met before answering, otherwise continue."`
- Static-recipe wording is untouched.

**3. `AgentLoop.swift` — the seam + gating (H1)**
Line 98: `var recipe = AgentRecipe.match(goal:, availableTools:)`. After it:
```swift
if recipe == nil, goalNeedsAction, tools.count >= 2, AgentDynamicPlanning.isEnabled {
    if isCancelled() { return .cancelled }
    recipe = await planDynamically(goal: goal)
    if isCancelled() { return .cancelled }
}
```
Line 100 `stepCap`: apply the `+2` slack **only when `!recipe.isDynamic`** —
dynamic recipes use plain `maxSteps`, identical to today's nil-recipe path.
New `#if os(macOS) private func planDynamically(goal:) async -> AgentRecipe?`:
build a prompt from goal + `name: purpose` tool list; one decode under
`planningOptions = GenerationOptions(maxTokens: 192, topP: 0.8, topK: 20,
gbnfGrammar: AgentDecisionGrammar.gbnf)` (reused, not new); wrap in `try?`
like the existing deliberation pass (line 144); parse with the existing
`AgentDecisionParser`; take `.plan(calls)` (a lone `.useTool` promotes to a
1-call list; `.finalAnswer`/`nil` → `nil`); hand to `AgentRecipe.parsePlan`.
Any failure at any stage → `nil` → exactly today's reactive loop.

**4. `AgentLoop.swift` — dynamic-stall tracking (H2 core)**
Add `var dynamicStalls = 0`. In the `.useTool`/`.plan` branches: if
`recipe?.isDynamic == true` and the just-executed tool did **not** advance the
cursor, `dynamicStalls += 1`; reset to 0 on any advance. At the re-anchor site
(line 128), when `recipe?.isDynamic == true && dynamicStalls >= 2`, bypass
`nextStepLine` and emit the neutral generic line (`"GOAL (still): \(goal).
Actions taken so far: \(toolAttempts). Decide the single best next action."`).
This is the core fix for the §2 regression: a wrong plan self-demotes to
today's neutral re-anchor after 2 divergences, bounding the attention-hot
mis-steer instead of hammering it every turn.

**5. `AgentLoop.swift` — guard #6 exemption (H3)**
Line 194: change condition to `if let recipe, !recipe.isDynamic, recipeCursor
< recipe.steps.count, !nudgedForIncompleteRecipe`. A model-guessed
denominator is not evidence the goal is unmet for a dynamic recipe; it must
not nudge the model to run a spurious step on an already-successful run.
Guards 1-5 untouched.

**6. New file `AgentDynamicPlanning.swift`**
Exact structural mirror of `AgentDeliberation.swift`:
```swift
public enum AgentDynamicPlanning {
    static let defaultsKey = "quenderin.agentDynamicPlanning"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static func setEnabled(_ v: Bool) { ... }
}
```
Read live in the seam gate (step 3). Add a Settings toggle next to "Deeper
reasoning," e.g. "Plan novel goals (experimental)."

**7. `AgentView.swift` — UI honesty label**
In `AgentRecipeChecklist` (line 466), when `recipe.isDynamic`: render header
as "Plan" (the agent's proposal), not a vouched recipe title; omit "N of M"
framing that implies a guaranteed track — show "Step N" / completed count
instead. Denominator `M` is a model estimate; the UI must read as a proposal.

---

### Tests to add

- **`AgentRecipeTests` — `parsePlan` validation:** unregistered toolHint
  filtered out; <2 surviving steps → `nil`; consecutive-duplicate tools
  collapse to one step; a 20-step hallucination clamps to `<= maxSteps`; step
  titles derive from `tool.purpose`, never a model-supplied label field.
- **`AgentLoopTests` — dynamic happy path:** flag ON, no static match,
  scripted 3-tool plan executed in order → cursor ticks 0→1→2→3, each green
  only after a non-failure observation; final `haltReason == .answered`.
- **`AgentLoopTests` — WRONG-plan divergence (load-bearing regression
  test):** scripted plan `[A,B,C]`, model reactively runs `[A,D,E]`; assert
  (i) cursor stalls after non-matching tools, (ii) after 2 dynamic stalls the
  re-anchor reverts to the neutral line (no persistent wrong-tool whisper),
  (iii) `stepCap == maxSteps` (no `+2` inflation), (iv) run still reaches
  `.answered`.
- **`AgentLoopTests`:** a dynamic step whose observation matches
  `isFailureObservation` does not tick the cursor.
- **`AgentLoopTests` — premature victory:** an under-decomposed dynamic plan
  whose steps all green does *not* emit "give the final answer now"; the
  goal-anchored "confirm the goal is actually met" line fires instead.
- **`AgentLoopTests` — latency proof:** flag-OFF and static-match paths call
  `engine.complete` exactly the reactive number of times (call-count
  assertion on `ScriptedInferenceEngine`) — proves zero added latency off the
  flagged long-tail path.
- **Parity:** `scripts/check_agent_parity.py` stays green in CI with **zero**
  edits to `shared/agent-parity-vectors.json`.

---

### Residual risks (after hardening)

1. **Value is unproven** on qwen3-4b in exactly the regime it's weakest —
   this is *why* it's flag-gated and measured live, not shipped on. If live
   data shows plans are usually wrong, turn it off; don't force default-on.
2. **Sharpest residual — failure-string honesty hole.** `isFailureObservation`
   (AgentLoop.swift:364-370) is a conservative 8-marker allowlist tuned to the
   curated Capabilities. A third-party `AgentTool` that returns a failure
   *string* without throwing and without a recognized marker (e.g. `"Request
   failed: 500"`) would tick a dynamic step green falsely. **Mitigation:**
   restrict `planDynamically`'s candidate tool list to
   `tools.compactMap { $0 as? Capability }` — the `.plan` resolve path
   already requires every step to be a `Capability` (line 253), and that set's
   errors already flow through `describeMacError`/`"Tool error:"`. Expanding
   `isFailureObservation` to non-Capability tools is a follow-up, not a
   blocker.
3. **Denominator `M` is a model guess** — disclosed, not eliminated, via the
   "Plan" UI label (step 7).
4. **Bounded residual mis-steer:** even hardened, a wrong plan still costs +1
   decode and up to 2 mildly-misdirected turns before self-abandon. Acceptable
   because it's flag-gated and capped, not silent or unbounded.
5. Grammar-less engines (mock/ported) ignore `planningOptions`' grammar;
   `parsePlan`'s strict validation catches garbage → `nil` → reactive, no
   regression.

---

### Twin note

**Zero twin-lock, verified against source.** No new `AgentDecision` case; no
change to `AgentDecision.swift`, `AgentDecisionParser`, or the blocklist.
`planningOptions` **reuses** the already-shipped `AgentDecisionGrammar.gbnf`
(root already permits the `plan` production, confirmed at
`AgentDecisionGrammar.swift:17-19`) — no new grammar authored anywhere.
`planDynamically`, `planningOptions`, `isDynamic`, `parsePlan`, and
`AgentDynamicPlanning` are all macOS-scoped, same as `AgentRecipe` itself
(already documented as macOS-only + advisory, off the parity island —
`AgentRecipe.swift:3-10`).

**The one hard guardrail:** the plan JSON is parsed by the existing
`AgentDecisionParser` but must be **immediately wrapped into an `AgentRecipe`**
— it must never be added as a parity vector or routed through a new decision
path, or `shared/agent-parity-vectors.json` (scoped to decision-parser +
blocklist verdicts per `scripts/check_agent_parity.py`) would demand a
Kotlin/TS twin. As designed, `check_agent_parity.py` stays green with zero
vector edits and no Kotlin/Swift/TS twin work is required. Cross-platform
behavioral surface added: **none** beyond macOS advisory prompt text.
