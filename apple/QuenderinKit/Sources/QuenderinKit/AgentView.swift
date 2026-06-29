#if canImport(SwiftUI)
import SwiftUI

/// M4's screen: give the agent a goal and watch it plan → use tools → answer. The SwiftUI
/// twin of `ChatView`, bound to `AgentSession`. A separate surface from chat (additive).
public struct AgentView: View {
    @ObservedObject private var session: AgentSession
    @State private var goal: String = ""
    @Environment(\.openURL) private var openURL

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(session.steps.enumerated()), id: \.offset) { _, step in
                        AgentStepRow(step: step)
                    }
                    if let answer = session.answer {
                        Text(answer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    if let url = SupportContact.reportMailto(reportedText: answer, context: "agent") {
                                        openURL(url)
                                    }
                                } label: {
                                    Label("Report answer", systemImage: "flag")
                                }
                            }
                    } else if !session.isRunning, let message = session.haltReason?.userMessage {
                        // The agent stopped without an answer (step limit, safety gate, plan error):
                        // say so instead of trailing off into silence.
                        AgentHaltBanner(message: message)
                    } else if session.steps.isEmpty, !session.isRunning {
                        // First run: show what the agent can do instead of a blank screen.
                        AgentEmptyState()
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: 8) {
                Button(role: .destructive) { session.clear() } label: { Image(systemName: "trash") }
                    .disabled(session.isRunning || (session.steps.isEmpty && session.answer == nil && session.haltReason == nil))
                    .accessibilityLabel("Clear")
                // Export the completed run as a Markdown walkthrough — shown only once a run has finished,
                // mirroring chat's ShareLink. The agent's reasoning leaves the device on the user's terms.
                if let walkthrough = session.exportMarkdown {
                    ShareLink(item: walkthrough,
                              subject: Text("Quenderin agent run"),
                              message: Text("Exported from Quenderin (on-device)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share walkthrough")
                }
                TextField("Give the agent a goal…", text: $goal)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isRunning)
                    .submitLabel(.go)
                    .onSubmit {
                        guard !session.isRunning,
                              !goal.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let g = goal
                        goal = ""
                        Task { await session.run(goal: g) }
                    }
                Button {
                    let g = goal
                    goal = ""
                    Task { await session.run(goal: g) }
                } label: {
                    if session.isRunning { ProgressView() } else { Text("Run") }
                }
                .disabled(session.isRunning || goal.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(session.isRunning ? "Running" : "Run")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Text(SupportContact.aiDisclaimer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

/// First-run guidance: what to type when the agent transcript is empty, so the screen isn't blank.
private struct AgentEmptyState: View {
    private let examples = [
        "What's 18% of 240?",
        "Convert 5 miles to kilometres",
        "How many days until 2027-01-01?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give the agent a goal — it plans, uses tools, and answers. Try:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Label(example, systemImage: "arrow.turn.down.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(example)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }
}

/// Shown when the agent halts without an answer — turns a silent dead-end into an
/// explanation (step limit, safety gate, or plan error). Tinted distinctly from the answer.
private struct AgentHaltBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// One step in the agent's reasoning: the tool it called and what it observed.
private struct AgentStepRow: View {
    let step: AgentStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case let .useTool(name, input) = step.decision {
                Text("\(name)(\(input))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let observation = step.observation {
                Text("→ \(observation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
