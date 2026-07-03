#if canImport(SwiftUI)
import SwiftUI

/// M4's screen: give the agent a goal and watch it plan → use tools → answer. The SwiftUI
/// twin of `ChatView`, bound to `AgentSession`. A separate surface from chat (additive).
public struct AgentView: View {
    @ObservedObject private var session: AgentSession
    @State private var goal: String = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(session.steps.enumerated()), id: \.offset) { _, step in
                        AgentStepRow(step: step)
                    }
                    if let answer = session.answer {
                        MarkdownText(text: answer, color: .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(p.primary.opacity(0.12))
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
                        runActions(palette: p)
                    } else if !session.isRunning, let message = session.haltReason?.userMessage {
                        // The agent stopped without an answer (step limit, safety gate, plan error):
                        // say so instead of trailing off into silence.
                        AgentHaltBanner(message: message)
                        runActions(palette: p)
                    } else if session.steps.isEmpty, !session.isRunning {
                        // First run: show what the agent can do instead of a blank screen.
                        // Tapping an example drops it into the field, ready to edit or run.
                        AgentEmptyState(palette: p) { example in goal = example }
                    }
                }
                .padding()
                .frame(maxWidth: 760)     // same centered column as chat on wide (Mac) panes
                .frame(maxWidth: .infinity)
            }

            Text(SupportContact.aiDisclaimer)
                .font(.caption2)
                .foregroundStyle(p.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)

            composer(palette: p)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(p.background)
    }

    /// Start the typed goal. On a plan failure ("try rephrasing it") the goal is handed back to the
    /// field so the user edits it instead of retyping from scratch.
    private func run() {
        let g = goal.trimmingCharacters(in: .whitespaces)
        guard !session.isRunning, !g.isEmpty else { return }
        goal = ""
        Task {
            await session.run(goal: g)
            if session.answer == nil, session.haltReason != nil, goal.isEmpty { goal = g }
        }
    }

    /// The pill-and-circle composer — the exact twin of chat's, so the two surfaces read as one app.
    /// The circle shows a spinner while a run is in flight (runs are short; no separate stop control).
    @ViewBuilder
    private func composer(palette p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            TextField("Give the agent a goal…", text: $goal)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .submitLabel(.go)
                .onSubmit { run() }
                .disabled(session.isRunning)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(p.surfaceVariant, in: Capsule())

            let canRun = !goal.trimmingCharacters(in: .whitespaces).isEmpty && !session.isRunning
            Button(action: run) {
                Group {
                    if session.isRunning {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(p.primary.opacity(canRun || session.isRunning ? 1 : 0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canRun)
            .accessibilityLabel(session.isRunning ? "Running" : "Run goal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    /// Actions on a FINISHED run (share the walkthrough, clear the board) — attached to the result
    /// they act on, not parked permanently in the composer bar.
    @ViewBuilder
    private func runActions(palette p: QuenderinPalette) -> some View {
        HStack(spacing: 16) {
            // Export the completed run as a Markdown walkthrough — mirroring chat's ShareLink.
            // The agent's reasoning leaves the device on the user's terms.
            if let walkthrough = session.exportMarkdown {
                ShareLink(item: walkthrough,
                          subject: Text("Quenderin agent run"),
                          message: Text("Exported from Quenderin (on-device)")) {
                    Label("Share walkthrough", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share walkthrough")
            }
            Button(role: .destructive) { session.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .accessibilityLabel("Clear run")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(p.onSurfaceVariant)
        .disabled(session.isRunning)
        .padding(.top, 2)
    }
}

/// First-run guidance with an on-brand spark focal point (twin of Android's `AgentEmptyState`) so the
/// screen reads as intentional, not blank. The examples are deliberately MULTI-STEP — each needs the
/// agent to plan and chain more than one tool (convert → calculate, date → divide), showcasing agentic
/// work instead of a single-shot calculation.
private struct AgentEmptyState: View {
    let palette: QuenderinPalette
    let onPick: (String) -> Void

    private let examples = [
        "Convert 5 miles to km, then take 20% of that",
        "Days until 2027-01-01 — and how many weeks?",
        "18% of 240, then convert that many km to miles",
    ]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(palette.primary)
            Text("Give the agent a multi-step goal")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("It plans, calls tools, and chains the results.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { onPick(example) } label: {
                        Label(example, systemImage: "arrow.turn.down.right")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use example: \(example)")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
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
