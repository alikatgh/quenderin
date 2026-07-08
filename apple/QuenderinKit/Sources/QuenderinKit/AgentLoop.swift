import Foundation

/// One turn of the agent: what it decided, and what it observed (tool output,
/// a refusal, or nil for a final answer).
public struct AgentStep: Sendable, Equatable {
    public let decision: AgentDecision
    public let observation: String?
}

/// The result of running the agent to completion.
public struct AgentRun: Sendable, Equatable {
    public enum HaltReason: String, Sendable { case answered, maxSteps, blocked, planError, stalled, cancelled, needsPermission }
    public let steps: [AgentStep]
    public let answer: String?
    public let haltReason: HaltReason
}

public extension AgentRun.HaltReason {
    /// A short, user-facing explanation for why the agent stopped, shown when there is no
    /// answer to display. `.answered` returns nil — the answer itself is shown instead.
    /// Kept identical to Android `AgentRun.HaltReason.userMessage` (cross-platform parity).
    var userMessage: String? {
        switch self {
        case .answered:  return nil
        case .maxSteps:  return "The agent reached its step limit before reaching an answer. Try a simpler or more specific goal."
        case .blocked:   return "The agent stopped: a step was blocked by the on-device safety filter."
        case .planError: return "The agent couldn't work out a step-by-step plan for that goal."
        case .stalled:   return "The agent got stuck repeating the same step. Try rephrasing the goal."
        case .cancelled: return "Stopped — you halted the agent."
        case .needsPermission: return "The agent needs a permission it doesn't have yet — nothing was completed. The run log above shows exactly which one and where to grant it (Quenderin Settings → Agent, or macOS System Settings › Privacy). Grant it, then run the goal again."
        }
    }
}

/// The vision's perceive → plan → execute loop, in the form iOS allows: a
/// **tool-use** agent. Each turn the planner (an `InferenceEngine`) emits a
/// decision; tool calls are **safety-gated** (`SafetyBlocklist`) before running,
/// their output is fed back, and the loop repeats until a final answer or a step
/// cap. Pure logic over the seams — fully testable with `ScriptedInferenceEngine`.
public struct AgentLoop: Sendable {
    private let engine: InferenceEngine
    private let tools: [AgentTool]
    private let maxSteps: Int
    /// The enforcement point for tools that are `Capability`s: gate → run → ledger, no way
    /// around it (AGENT_AUTONOMY_PLAN §6). Plain `AgentTool`s keep the legacy direct path.
    private let runner: CapabilityRunner
    /// Opt-in "think, then decide". Read LIVE (a closure, not a stored Bool) so toggling the setting
    /// takes effect on the very next step, not the next app launch. Default OFF — thinking makes the
    /// agent slower, so it's the user's call (Settings → Agent → "Deeper reasoning").
    private let deliberate: @Sendable () -> Bool

    public init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                runner: CapabilityRunner = CapabilityRunner(),
                deliberate: @escaping @Sendable () -> Bool = { false }) {
        self.engine = engine
        self.tools = tools
        self.maxSteps = max(1, maxSteps)
        self.runner = runner
        self.deliberate = deliberate
    }

    public func run(
        goal: String,
        onStep: @Sendable (AgentStep) -> Void = { _ in },
        onProgress: @Sendable (AgentRecipe?, Int) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) async -> AgentRun {
        var steps: [AgentStep] = []
        var transcript = preamble(goal: goal)
        // Reliability guards for a weak on-device model (twins of the desktop CapabilityAgent):
        // `parseFailures` recovers from malformed JSON (nudge + retry, not instant death); `stall`
        // catches the model re-emitting the SAME action (nudge, then halt .stalled). Both nudge the
        // transcript only — a nudge isn't a step the agent took.
        var prevSig: String?
        var lastObs = ""
        var stall = 0
        var parseFailures = 0
        // Fabricated-success guard (live-caught): a consent-refused tool call executes NOTHING,
        // but a small model then happily answers "I have drafted the email…" — a fluent lie about
        // an action that never happened. Track whether any tool observation was a real execution;
        // if the model claims done while every attempt was a permission refusal, the run halts
        // .needsPermission instead of presenting the fabrication as the outcome.
        var toolAttempts = 0
        var refusedAttempts = 0
        // Zero-action guard (live-caught, the sibling of the fabricated-success guard): the model
        // answered a bare "Done" with an EMPTY run log — no tool attempted at all. For a goal that
        // reads as a computer task (ActionIntent), an answer with zero attempts gets ONE corrective
        // nudge; if the model still answers without acting, the run halts honestly instead of
        // presenting "Done" over work that never happened.
        let goalNeedsAction = ActionIntent.looksLikeComputerTask(goal)
        var nudgedForNoAction = false

        // World-class multi-step (docs/audits/2026-07-08-world-class-multistep.md): a matched RECIPE
        // gives an honest denominator + a tool-hinted skeleton the weak 4B fills in. Purely advisory —
        // nil recipe is EXACTLY today's behavior. The cap only ever RISES, so a longer chain isn't
        // starved by nudges. The cursor advances on a real executed tool-name match — a green check
        // can never fire on the wrong step.
        let recipe = AgentRecipe.match(goal: goal, availableTools: tools.map(\.name))
        if let recipe { transcript += "\n" + recipe.skeleton() }
        let stepCap = recipe.map { max(maxSteps, $0.steps.count + 2) } ?? maxSteps
        var recipeCursor = 0
        var nudgedForIncompleteRecipe = false
        onProgress(recipe, recipeCursor)   // publish now so the checklist DRAWS before the first decode

        func record(_ step: AgentStep) {
            steps.append(step)
            onStep(step)   // live update for the UI, as each step happens
        }

        // Advance the cursor iff the just-executed tool IS the next expected step (advance-only: a
        // miscount holds truthfully rather than telling the model to redo a step it already did).
        func advanceRecipe(executed toolName: String) {
            guard let recipe, recipeCursor < recipe.steps.count,
                  recipe.steps[recipeCursor].toolHint == toolName else { return }
            recipeCursor += 1
            onProgress(recipe, recipeCursor)
        }

        for _ in 0..<stepCap {
            // Q-641: the hard-stop (kill switch) — checked at each step boundary. `AgentSession.cancel()`
            // flips the flag (and interrupts the in-flight decode via the engine), so a running mission
            // ends here with `.cancelled` instead of grinding to maxSteps. Twin of the desktop Q-523.
            if isCancelled() { return AgentRun(steps: steps, answer: nil, haltReason: .cancelled) }
            // CROWN JEWEL — re-anchor the goal + progress at the transcript TAIL each iteration. A 4B
            // attends most to the tail, but the goal was written once at the TOP and drowns under the
            // growing observation log (the named root cause of multi-step drift). Zero extra decode;
            // helps EVERY goal — recipe-guided (the next step) or generic (the goal + actions-so-far).
            let reanchor = recipe?.nextStepLine(cursor: recipeCursor)
                ?? "GOAL (still): \(goal). Actions taken so far: \(toolAttempts). Decide the single best next action."
            transcript += "\n" + reanchor
            let reply: String
            do {
                // Decisions decode under the GBNF grammar on engines that support it — the model
                // CANNOT emit prose instead of the JSON contract, so first-try parses replace the
                // nudge-and-retry dance. Engines without grammar support ignore the option, and
                // the parse-nudge path below still covers them (mock, ported engines).
                // On the FIRST step of an action goal, use the tool|plan-only grammar so a weak
                // model can't bail with {"answer":"I can't…"} before even trying a tool.
                // Opt-in deliberation: let the model reason BEFORE it commits (Qwen3 is tuned to
                // think first, but the grammar forces `{` as the first decision token). The reasoning
                // is woven into the transcript as a closed <think> block so the grammar-constrained
                // decision that follows is informed by it. Best-effort — a failed/empty think pass
                // never fails the step, it just falls through to the direct decode.
                if deliberate(), let thought = try? await engine.complete(
                    prompt: transcript + "<think>\n", options: Self.deliberationOptions) {
                    let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { transcript += "<think>\n" + trimmed + "\n</think>\n" }
                    if isCancelled() { return AgentRun(steps: steps, answer: nil, haltReason: .cancelled) }
                }
                let firstActionStep = goalNeedsAction && steps.isEmpty
                reply = try await engine.complete(prompt: transcript,
                                                  options: firstActionStep ? Self.actionFirstOptions : Self.decisionOptions)
            } catch {
                return AgentRun(steps: steps, answer: nil, haltReason: .planError)
            }

            guard let decision = AgentDecisionParser.parse(reply) else {
                // Malformed output: nudge with the contract and retry; halt only if it slips again.
                parseFailures += 1
                if parseFailures >= 2 {
                    return AgentRun(steps: steps, answer: nil, haltReason: .planError)
                }
                transcript += "\n" + Self.parseNudge
                continue
            }
            parseFailures = 0

            // A final answer has no action to repeat — handle (and safety-gate, H14) before the guard.
            if case .finalAnswer(let answer) = decision {
                if SafetyBlocklist.isBlocked(answer) {
                    record(AgentStep(decision: decision, observation: "Refused: answer touches a blocked topic."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .blocked)
                }
                // Every tool attempt was refused for missing permission ⇒ NOTHING executed, so any
                // answer implying the task happened is false. Drop it and say what's actually true.
                // (A structured banner also beats an honest "I couldn't" — it names the fix.)
                if toolAttempts > 0 && refusedAttempts == toolAttempts {
                    record(AgentStep(decision: decision, observation: "The answer was withheld: no tool actually ran (permission was missing)."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .needsPermission)
                }
                // Zero attempts on an action goal: "Done" over no work is a lie. One nudge, then halt.
                if toolAttempts == 0 && goalNeedsAction {
                    if !nudgedForNoAction {
                        nudgedForNoAction = true
                        transcript += "\nYou have not taken any action yet, so an answer now would be false. This goal requires acting through a tool — pick the right one from the list and use it."
                        continue
                    }
                    record(AgentStep(decision: decision, observation: "The answer was withheld: the goal requires actions, but none were taken."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .planError)
                }
                // Guard #6 (only possible with a recipe's honest denominator): don't accept "done"
                // after only a PARTIAL subset of the steps ran. Nudge ONCE with the next step, then
                // allow the answer on retry — nudges once then yields, never halts.
                if let recipe, recipeCursor < recipe.steps.count, !nudgedForIncompleteRecipe {
                    nudgedForIncompleteRecipe = true
                    transcript += "\nNot finished yet — \(recipe.nextStepLine(cursor: recipeCursor)) Do that before answering."
                    continue
                }
                record(AgentStep(decision: decision, observation: nil))
                return AgentRun(steps: steps, answer: answer, haltReason: .answered)
            }

            // Stuck detection: the model re-proposed the exact action it just ran. Don't re-execute
            // (that repeats side effects / re-fails identically) — nudge, and bail if it insists.
            let sig = Self.signature(of: decision)
            if sig == prevSig {
                stall += 1
                if stall >= 2 {
                    // Reason precedence: if the model got stuck ON a permission-refused action
                    // (lastObs is the refusal), it isn't confused — it has no other move. "Try
                    // rephrasing" is wrong there; "grant the capability" is right. Checking the
                    // STALLING observation (not an all-attempts count) means an unrelated earlier
                    // success — e.g. a stray calculator scratchpad call — can't mask it
                    // (live-caught: openURL refused, but calculator(1) first → mislabeled .stalled).
                    let reason: AgentRun.HaltReason =
                        (Self.isPermissionRefusal(lastObs) || Self.isSystemPermissionBlock(lastObs)) ? .needsPermission : .stalled
                    return AgentRun(steps: steps, answer: nil, haltReason: reason)
                }
                transcript += "\nYou already ran \(sig) and got: \(lastObs) — do something different, or reply {\"answer\":\"…\"} if the task is done."
                continue
            }
            stall = 0

            let observation: String
            switch decision {
            case .finalAnswer:
                observation = ""   // unreachable — handled above

            case .useTool(let name, let input):
                // Safety gate — refuse blocked actions before they ever run.
                if SafetyBlocklist.isBlocked(input) || SafetyBlocklist.isBlocked(name) {
                    record(AgentStep(decision: decision, observation: "Refused: touches a blocked action."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .blocked)
                }
                observation = await execute(name: name, input: input)
                toolAttempts += 1
                if Self.isPermissionRefusal(observation) { refusedAttempts += 1 }
                else if !Self.isFailureObservation(observation) { advanceRecipe(executed: name) }
                transcript += "\nUsed \(name)(\(input)) → \(observation)"

            case .plan(let calls):
                // Safety gate per step, BEFORE anything runs — a plan containing a blocked
                // action is a bad plan, not a plan to trim.
                for call in calls where SafetyBlocklist.isBlocked(call.input) || SafetyBlocklist.isBlocked(call.name) {
                    record(AgentStep(decision: decision, observation: "Refused: the plan touches a blocked action."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .blocked)
                }
                // Every step must resolve to a Capability — the runner's plan path owns
                // consent + the ONE aggregate approval + per-step ledgering.
                var resolved: [(capability: Capability, input: String)] = []
                var unknown: String?
                for call in calls {
                    guard let capability = tools.first(where: { $0.name == call.name }) as? Capability else {
                        unknown = call.name
                        break
                    }
                    resolved.append((capability, call.input))
                }
                if let unknown {
                    observation = Self.unknownToolMessage(unknown, available: tools.map(\.name)) + " Plan not executed."
                } else {
                    observation = await runner.executePlan(resolved)
                    // A plan that ran cleanly may satisfy several recipe steps in order.
                    if !Self.isFailureObservation(observation) {
                        for call in calls { advanceRecipe(executed: call.name) }
                    }
                }
                let described = calls.map { "\($0.name)(\($0.input))" }.joined(separator: ", ")
                transcript += "\nProposed plan [\(described)] → \(observation)"
            }

            record(AgentStep(decision: decision, observation: observation))
            prevSig = sig
            lastObs = observation
        }

        // Same precedence at the step cap: if the run ended on a permission refusal, a macOS
        // system-permission block, or every attempt was refused, the blocker is a missing grant —
        // say that, not "too complex".
        if Self.isPermissionRefusal(lastObs) || Self.isSystemPermissionBlock(lastObs)
            || (toolAttempts > 0 && refusedAttempts == toolAttempts) {
            return AgentRun(steps: steps, answer: nil, haltReason: .needsPermission)
        }
        return AgentRun(steps: steps, answer: nil, haltReason: .maxSteps)
    }

    /// The corrective nudge shown after a malformed reply — the exact JSON contract, once.
    static let parseNudge = "Your last reply was not valid JSON. Reply with EXACTLY ONE JSON object and nothing else: {\"tool\":\"<name>\",\"input\":\"<text>\"}, {\"plan\":[{\"tool\":\"<name>\",\"input\":\"<text>\"},…]}, or {\"answer\":\"<text>\"}."

    /// Decision decode options: Qwen3's NON-THINKING sampling recipe (temp 0.7 / top_p 0.8 /
    /// top_k 20) + the decision grammar. The stock chat defaults (top_p 0.95, no top_k) are a
    /// hybrid that matches neither Qwen3 mode; tightening the tail to the model's tuned distribution
    /// cuts off-recipe noise in the free `input` argument and the odd low-probability wrong-tool
    /// pick. Scoped to the agent so chat is untouched. (Verified SHIP; docs/audits 2026-07-08.)
    static let decisionOptions = GenerationOptions(topP: 0.8, topK: 20, gbnfGrammar: AgentDecisionGrammar.gbnf)
    /// First-action-step options: the tool|plan-only grammar (no `answer`) so a weak model must
    /// try a tool instead of bailing on step 1 of an action goal. Same Qwen3 recipe.
    static let actionFirstOptions = GenerationOptions(topP: 0.8, topK: 20, gbnfGrammar: AgentDecisionGrammar.gbnfActionFirst)

    /// The "think first" decode (opt-in). Qwen3's THINKING recipe (temp 0.6 / top_p 0.95 / top_k 20),
    /// UNCONSTRAINED so the model can actually reason, but hard-capped at 256 tokens and stopped at
    /// `</think>` (via StopSequenceScanner) so the reasoning can't run away and starve the decision.
    /// The grammar-forced decode that follows sees the reasoning and commits. Qwen3-audit issue #1.
    static let deliberationOptions = GenerationOptions(
        maxTokens: 256, temperature: 0.6, topP: 0.95, topK: 20,
        stopSequences: ["</think>"], gbnfGrammar: nil)

    /// The recovery hint for a mistyped tool name. Live-caught: the model called "mail.draft"
    /// for "mac.mail.draft", and the bare "No such tool" observation left it NOTHING to recover
    /// with — it flailed and surfaced the error as its answer. The loop knows the tool list; a
    /// near-miss deserves "did you mean". Pure + deterministic; twin of the Kotlin helper.
    static func unknownToolMessage(_ name: String, available: [String]) -> String {
        let suggestions = closestTools(to: name, in: available)
        let hint = suggestions.isEmpty
            ? "" : " Did you mean \(suggestions.map { "\"\($0)\"" }.joined(separator: " or "))?"
        return "No such tool: \(name).\(hint)"
    }

    /// Closest real tool names: a namespaced twin or containment ("mail.draft" ⊂
    /// "mac.mail.draft") beats small edit distance; anything farther than 3 edits is noise.
    static func closestTools(to name: String, in available: [String], limit: Int = 2) -> [String] {
        let lowered = name.lowercased()
        let scored: [(String, Int)] = available.compactMap { candidate in
            let c = candidate.lowercased()
            if c == lowered { return (candidate, 0) }
            if c.contains(lowered) || lowered.contains(c) { return (candidate, 1) }
            let d = levenshtein(lowered, c)
            return d <= 3 ? (candidate, 1 + d) : nil
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map { $0.0 }
    }

    /// Classic DP edit distance — tiny inputs (tool names), so O(n·m) is nothing.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// True when a tool observation means the action did NOT execute for lack of the user's
    /// permission. These prefixes are OUR OWN stable strings from `CapabilityRunner`
    /// (consent gate, per-run decline, missing approver) — not model output. Kept in lockstep
    /// with the Kotlin twin.
    static func isPermissionRefusal(_ observation: String) -> Bool {
        observation.hasPrefix("Needs your permission first:") ||
        observation.hasPrefix("You declined:") ||
        observation.hasPrefix("This action changes files and needs your per-run approval")
    }

    /// True when an observation means the tool RAN but FAILED — so the recipe cursor must NOT advance
    /// on it. Keyed on OUR OWN stable capability/loop error strings, never model output. Deliberately
    /// does NOT include "No events…" (a valid empty calendar) or a permission refusal (that's
    /// `isPermissionRefusal`). Keeping the set conservative avoids ticking a step that truly failed.
    static func isFailureObservation(_ observation: String) -> Bool {
        for marker in ["No such tool", "must include a valid to:", "No shortcut named",
                       "NO_ACCOUNT", "Tool error:", "not executed", "Couldn't ", "Timed out"] {
            if observation.contains(marker) { return true }
        }
        return false
    }

    /// True when an observation is a macOS SYSTEM-permission block (Automation / Accessibility). The
    /// fix is a one-time grant in System Settings › Privacy — NOT "try rephrasing", and NOT Quenderin's
    /// own consent toggle — so the halt must be `.needsPermission`, not `.stalled`. Keyed on our own
    /// stable `describeMacError` strings. (Live-caught: a recipe stalled on an Automation-blocked
    /// Calendar and told the user to "rephrase the goal", which can't fix a permission.)
    static func isSystemPermissionBlock(_ observation: String) -> Bool {
        observation.contains("Privacy & Security › Automation") ||
        observation.contains("Privacy & Security › Accessibility")
    }

    /// A stable fingerprint of an action, so the loop can spot the model re-proposing the same thing.
    static func signature(of decision: AgentDecision) -> String {
        switch decision {
        case .finalAnswer:
            return "answer"
        case .useTool(let name, let input):
            return "\(name)(\(input))"
        case .plan(let calls):
            return "plan[" + calls.map { "\($0.name)(\($0.input))" }.joined(separator: ", ") + "]"
        }
    }

    private func execute(name: String, input: String) async -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.unknownToolMessage(name, available: tools.map(\.name))
        }
        // Capabilities go through the runner (blocklist → consent → preview → run → ledger);
        // for T0 tools the observable behavior is identical, plus the ledger row.
        if let capability = tool as? Capability {
            return await runner.execute(capability, input: input)
        }
        do {
            return try await tool.run(input)
        } catch {
            return "Tool error: \(error)"
        }
    }

    private func preamble(goal: String) -> String {
        let toolList = tools.map { "- \($0.name): \($0.purpose)" }.joined(separator: "\n")
        // The "answer is ONLY the final result" line exists because grammar-constrained decoding
        // (AgentDecisionGrammar) closed the accidental safety net: pre-grammar, a chatty model's
        // "Okay, let's calculate…" preamble FAILED the JSON parse and drew a retry nudge; under
        // the grammar that narration becomes a legal {"answer":…} and ends the mission with no
        // work done (live-caught). Same line in the Kotlin twin.
        return """
        Goal: \(goal)
        Available tools:
        \(toolList)
        Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use a tool, \
        {"plan":[{"tool":"<name>","input":"<text>"},…]} to propose several steps the user \
        approves together, or {"answer":"<final answer>"} when done.
        Use {"answer":…} ONLY for the completed final result — never for narration, plans in \
        prose, or intentions. If any calculation or lookup is still needed, use a tool first.
        """
    }
}
