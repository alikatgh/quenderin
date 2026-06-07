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

/// The vision's perceive → plan → execute loop, in the form iOS allows: a
/// **tool-use** agent. Each turn the planner (an `InferenceEngine`) emits a
/// decision; tool calls are **safety-gated** (`SafetyBlocklist`) before running,
/// their output is fed back, and the loop repeats until a final answer or a step
/// cap. Pure logic over the seams — fully testable with `ScriptedInferenceEngine`.
public struct AgentLoop: Sendable {
    private let engine: InferenceEngine
    private let tools: [AgentTool]
    private let maxSteps: Int

    public init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6) {
        self.engine = engine
        self.tools = tools
        self.maxSteps = max(1, maxSteps)
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
