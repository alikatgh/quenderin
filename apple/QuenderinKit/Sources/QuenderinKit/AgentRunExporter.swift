import Foundation

/// Renders an ``AgentRun`` to a portable Markdown **walkthrough** the user can share or save — the
/// agent's reasoning made into a reviewable artifact (the one genuinely transferable idea from
/// agentic IDEs like Google Antigravity: a shareable record of what the agent did and how it
/// concluded), while staying fully on-device. The chat twin is ``ConversationExporter``; this is the
/// agent twin. Pure + testable. Twin of Android `AgentRunExporter`.
public enum AgentRunExporter {
    public static func markdown(_ run: AgentRun, goal: String) -> String {
        let goalTrimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = goalTrimmed.isEmpty ? "Agent run" : goalTrimmed
        let n = run.steps.count
        var out = "# Agent walkthrough: \(heading)\n\n"
        out += "_Exported from Quenderin — on-device, \(n) step\(n == 1 ? "" : "s")._\n\n"

        // A glanceable verification summary up top: the outcome + which tools the agent actually used.
        // Agentic-IDE artifacts (e.g. Google Antigravity) lead with this so a reader can verify the run
        // at a glance instead of reading to the end. ASCII-only + identical wording to the Android twin.
        let status: String
        switch run.haltReason {
        case .answered:  status = "answered"
        case .maxSteps:  status = "stopped at the step limit"
        case .blocked:   status = "stopped by the safety filter"
        case .planError: status = "stopped (could not form a plan)"
        }
        var toolsUsed: [String] = []
        for step in run.steps {
            if case let .useTool(name, _) = step.decision, !toolsUsed.contains(name) {
                toolsUsed.append(name)
            }
        }
        let toolsLine = toolsUsed.isEmpty ? "No tools used." : "Tools used: \(toolsUsed.joined(separator: ", "))."
        out += "**Outcome: \(status).** \(toolsLine)\n\n"

        for (i, step) in run.steps.enumerated() {
            let num = i + 1
            switch step.decision {
            case let .useTool(name, input):
                out += "**\(num). Used `\(name)`(\(input))**"
            case .finalAnswer:
                out += "**\(num). Final answer**"
            }
            if let obs = step.observation, !obs.isEmpty {
                out += " → \(obs)"
            }
            out += "\n\n"
        }

        // Outcome: the answer when there is one, else the user-facing halt reason (maxSteps/blocked/
        // planError). `.answered` returns nil from userMessage by design — the answer is shown instead.
        if let answer = run.answer {
            out += "**Answer:** \(answer)\n"
        } else if let reason = run.haltReason.userMessage {
            out += "**Halted:** \(reason)\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
