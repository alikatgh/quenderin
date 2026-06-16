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
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Give the agent a goal…", text: $goal)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isRunning)
                Button {
                    let g = goal
                    goal = ""
                    Task { await session.run(goal: g) }
                } label: {
                    if session.isRunning { ProgressView() } else { Text("Run") }
                }
                .disabled(session.isRunning || goal.trimmingCharacters(in: .whitespaces).isEmpty)
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
    }
}
#endif
