import Foundation

/// One turn of the agent: what it decided, and what it observed (tool output,
/// a refusal, or nil for a final answer).
public struct AgentStep: Sendable, Equatable {
    public let decision: AgentDecision
    public let observation: String?
}

/// The result of running the agent to completion.
public struct AgentRun: Sendable, Equatable {
    public enum HaltReason: String, Sendable { case answered, maxSteps, blocked, planError }
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
        onStep: @Sendable (AgentStep) -> Void = { _ in }
    ) async -> AgentRun {
        var steps: [AgentStep] = []
        var transcript = preamble(goal: goal)

        func record(_ step: AgentStep) {
            steps.append(step)
            onStep(step)   // live update for the UI, as each step happens
        }

        for _ in 0..<maxSteps {
            let reply: String
            do {
                reply = try await engine.complete(prompt: transcript)
            } catch {
                return AgentRun(steps: steps, answer: nil, haltReason: .planError)
            }

            guard let decision = AgentDecisionParser.parse(reply) else {
                return AgentRun(steps: steps, answer: nil, haltReason: .planError)
            }

            switch decision {
            case .finalAnswer(let answer):
                // The safety gate also applies to the final answer (H14): a jailbroken/fine-tuned
                // on-device model could emit blocked content as an answer, bypassing the tool-only gate.
                if SafetyBlocklist.isBlocked(answer) {
                    record(AgentStep(decision: decision, observation: "Refused: answer touches a blocked topic."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .blocked)
                }
                record(AgentStep(decision: decision, observation: nil))
                return AgentRun(steps: steps, answer: answer, haltReason: .answered)

            case .useTool(let name, let input):
                // Safety gate — refuse blocked actions before they ever run.
                if SafetyBlocklist.isBlocked(input) || SafetyBlocklist.isBlocked(name) {
                    record(AgentStep(decision: decision, observation: "Refused: touches a blocked action."))
                    return AgentRun(steps: steps, answer: nil, haltReason: .blocked)
                }

                let observation = await execute(name: name, input: input)
                record(AgentStep(decision: decision, observation: observation))
                transcript += "\nUsed \(name)(\(input)) → \(observation)"
            }
        }

        return AgentRun(steps: steps, answer: nil, haltReason: .maxSteps)
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
        or {"answer":"<final answer>"} when done.
        """
    }
}
