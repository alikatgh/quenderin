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
        case .needsPermission: return "The agent needs your permission for the tools it planned — nothing was done yet. Grant the capability named in the run log (Settings → Agent), then run the goal again."
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

    public init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                runner: CapabilityRunner = CapabilityRunner()) {
        self.engine = engine
        self.tools = tools
        self.maxSteps = max(1, maxSteps)
        self.runner = runner
    }

    public func run(
        goal: String,
        onStep: @Sendable (AgentStep) -> Void = { _ in },
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

        func record(_ step: AgentStep) {
            steps.append(step)
            onStep(step)   // live update for the UI, as each step happens
        }

        for _ in 0..<maxSteps {
            // Q-641: the hard-stop (kill switch) — checked at each step boundary. `AgentSession.cancel()`
            // flips the flag (and interrupts the in-flight decode via the engine), so a running mission
            // ends here with `.cancelled` instead of grinding to maxSteps. Twin of the desktop Q-523.
            if isCancelled() { return AgentRun(steps: steps, answer: nil, haltReason: .cancelled) }
            let reply: String
            do {
                reply = try await engine.complete(prompt: transcript)
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
                record(AgentStep(decision: decision, observation: nil))
                return AgentRun(steps: steps, answer: answer, haltReason: .answered)
            }

            // Stuck detection: the model re-proposed the exact action it just ran. Don't re-execute
            // (that repeats side effects / re-fails identically) — nudge, and bail if it insists.
            let sig = Self.signature(of: decision)
            if sig == prevSig {
                stall += 1
                if stall >= 2 {
                    return AgentRun(steps: steps, answer: nil, haltReason: .stalled)
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
                    observation = "No such tool: \(unknown). Plan not executed."
                } else {
                    observation = await runner.executePlan(resolved)
                }
                let described = calls.map { "\($0.name)(\($0.input))" }.joined(separator: ", ")
                transcript += "\nProposed plan [\(described)] → \(observation)"
            }

            record(AgentStep(decision: decision, observation: observation))
            prevSig = sig
            lastObs = observation
        }

        return AgentRun(steps: steps, answer: nil, haltReason: .maxSteps)
    }

    /// The corrective nudge shown after a malformed reply — the exact JSON contract, once.
    static let parseNudge = "Your last reply was not valid JSON. Reply with EXACTLY ONE JSON object and nothing else: {\"tool\":\"<name>\",\"input\":\"<text>\"}, {\"plan\":[{\"tool\":\"<name>\",\"input\":\"<text>\"},…]}, or {\"answer\":\"<text>\"}."

    /// True when a tool observation means the action did NOT execute for lack of the user's
    /// permission. These prefixes are OUR OWN stable strings from `CapabilityRunner`
    /// (consent gate, per-run decline, missing approver) — not model output. Kept in lockstep
    /// with the Kotlin twin.
    static func isPermissionRefusal(_ observation: String) -> Bool {
        observation.hasPrefix("Needs your permission first:") ||
        observation.hasPrefix("You declined:") ||
        observation.hasPrefix("This action changes files and needs your per-run approval")
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
            return "No such tool: \(name)."
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
        return """
        Goal: \(goal)
        Available tools:
        \(toolList)
        Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use a tool, \
        {"plan":[{"tool":"<name>","input":"<text>"},…]} to propose several steps the user \
        approves together, or {"answer":"<final answer>"} when done.
        """
    }
}
