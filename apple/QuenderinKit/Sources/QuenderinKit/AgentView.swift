#if canImport(SwiftUI)
import SwiftUI

/// M4's screen: give the agent a goal and watch it plan → use tools → answer. The SwiftUI
/// twin of `ChatView`, bound to `AgentSession`. A separate surface from chat (additive).
public struct AgentView: View {
    @ObservedObject private var session: AgentSession
    @ObservedObject private var attachments: AttachedFilesStore
    @State private var goal: String = ""
    @State private var showFilePicker = false
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    public init(session: AgentSession, attachments: AttachedFilesStore = .shared) {
        self.session = session
        self.attachments = attachments
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 0) {
            // Identity header, twin of the chat header's anatomy: name + status line.
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.subheadline).foregroundStyle(p.primary)
                    Text("Agent").font(.headline).foregroundStyle(p.onSurface)
                }
                HStack(spacing: 4) {
                    Circle().fill(p.status).frame(width: 6, height: 6)
                    Text("on-device tools · safety-gated").font(.caption2).foregroundStyle(p.statusText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(p.surface)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !session.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("RUN LOG")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(p.onSurfaceVariant)
                            // The final "answer" decision carries no tool call and no observation —
                            // it would render as a bare numbered circle, so the log skips it.
                            let visible = session.steps.filter { step in
                                if case .useTool = step.decision { return true }
                                return step.observation != nil
                            }
                            ForEach(Array(visible.enumerated()), id: \.offset) { index, step in
                                AgentStepRow(index: index + 1, step: step, palette: p)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
                    }
                    if let answer = session.answer {
                        MarkdownText(text: answer, color: .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(p.primary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    copyToPasteboard(answer)
                                } label: {
                                    Label("Copy answer", systemImage: "doc.on.doc")
                                }
                                Button {
                                    if let url = SupportContact.reportMailto(reportedText: answer, context: "agent") {
                                        openURL(url)
                                    }
                                } label: {
                                    Label("Report answer", systemImage: "flag")
                                }
                            }
                        runActions(palette: p, showShare: true)
                    } else if !session.isRunning, let message = session.haltReason?.userMessage {
                        // The agent stopped without an answer (step limit, safety gate, plan error):
                        // say so, then GUIDE — show goals that work instead of blaming the phrasing.
                        // No Share here: a run with no answer has no walkthrough worth exporting.
                        AgentHaltBanner(message: message)
                        AgentExampleList(palette: p, header: "It plans best with clear multi-step goals — try one of these:") { example in
                            goal = example
                        }
                        runActions(palette: p, showShare: false)
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

            // Attached files — what fs.read may see. Chips sit above the composer so what the
            // agent can touch is always visible before you send a goal (never buried in a menu).
            if !attachments.names.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments.names, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text").font(.caption2)
                                Text(name).font(.caption)
                                Button {
                                    attachments.remove(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(name)")
                            }
                            .foregroundStyle(p.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(p.surface, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }

            composer(palette: p)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(p.background)
        // The ONLY door into fs.read's granted map: an explicit user pick (§7 — the model can
        // name attached files, never mint paths).
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { attachments.attach(url) }
            }
        }
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
            // Attach a file for fs.read — the + that only appears attached to a real capability
            // (the advertised-but-unimplemented rule, honored in the affirmative).
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    .glassChrome(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .help("Attach a file the agent may read (with your permission)")
            .accessibilityLabel("Attach a file")

            TextField("Give the agent a goal…", text: $goal)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .submitLabel(.go)
                .onSubmit { run() }
                .disabled(session.isRunning)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                // Same Liquid Glass chrome as chat's composer — the two surfaces read as one app.
                .glassChrome(in: Capsule())

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
    /// they act on, not parked permanently in the composer bar. `showShare` is false on a halt:
    /// a run that produced no answer has nothing worth exporting.
    @ViewBuilder
    private func runActions(palette p: QuenderinPalette, showShare: Bool) -> some View {
        HStack(spacing: 16) {
            // Export the completed run as a Markdown walkthrough — mirroring chat's ShareLink.
            // The agent's reasoning leaves the device on the user's terms.
            if showShare, let walkthrough = session.exportMarkdown {
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
            AgentExampleList(palette: palette, header: nil, onPick: onPick)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// The tappable example goals — ONE list shared by the empty state and the halt state, so the
/// screen that says "that didn't work" always also shows what DOES. Tapping drops the example
/// into the field, ready to edit or run.
private struct AgentExampleList: View {
    let palette: QuenderinPalette
    let header: String?
    let onPick: (String) -> Void

    private static let examples = [
        "Convert 5 miles to km, then take 20% of that",
        "Days until 2027-01-01 — and how many weeks?",
        "18% of 240, then convert that many km to miles",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.examples, id: \.self) { example in
                Button { onPick(example) } label: {
                    Label(example, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use example: \(example)")
            }
        }
        // No frame here: the empty state centers this as a block, the halt state leads it —
        // the parent stack's alignment decides.
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

/// One numbered step in the run log: the tool call (code-styled) and what came back.
private struct AgentStepRow: View {
    let index: Int
    let step: AgentStep
    let palette: QuenderinPalette

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(width: 16, height: 16)
                .background(Circle().fill(palette.surfaceVariant))
            VStack(alignment: .leading, spacing: 3) {
                if case let .useTool(name, input) = step.decision {
                    Text("\(name)(\(input))")
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.primary)
                        .textSelection(.enabled)
                }
                if let observation = step.observation {
                    Text(observation)
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index)")
    }
}
#endif
