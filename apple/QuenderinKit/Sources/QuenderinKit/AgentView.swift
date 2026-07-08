#if canImport(SwiftUI)
import SwiftUI

/// M4's screen: give the agent a goal and watch it plan → use tools → answer. The SwiftUI
/// twin of `ChatView`, bound to `AgentSession`. A separate surface from chat (additive).
public struct AgentView: View {
    @ObservedObject private var session: AgentSession
    @ObservedObject private var attachments: AttachedFilesStore
    @ObservedObject private var workspace: WorkspaceStore
    @ObservedObject private var approvals: ApprovalBroker
    @ObservedObject private var goalHistory: AgentGoalHistoryStore
    @State private var goal: String = ""
    @State private var showFilePicker = false
    @State private var showFolderPicker = false
    @State private var undoNotice: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    /// The SAME UserDefaults-backed consent the Settings pane and the session's runner use —
    /// a grant made here (by an explicit user tap) is read live by the runner on the next run.
    /// This is a USER gesture, never model-reachable; the security invariant is "the MODEL can't
    /// self-grant", not "grants can only happen in Settings".
    private let consentStore = UserDefaultsConsentStore()

    public init(session: AgentSession, attachments: AttachedFilesStore = .shared,
                workspace: WorkspaceStore = .shared,
                goalHistory: AgentGoalHistoryStore = .shared) {
        self.session = session
        self.attachments = attachments
        self.workspace = workspace
        self.approvals = session.approvals
        self.goalHistory = goalHistory
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
                                if case .plan = step.decision { return true }
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
                    // While a run is live, SOMETHING must always be visibly happening. Before this
                    // row existed, the screen was BLANK from Run until the first step landed — and
                    // the first decision is the slowest decode of the mission (full prompt prefill
                    // + plan generation on-device), so real goals read as "it just stuck" and users
                    // quit the app (live user report). The composer spinner alone is not feedback.
                    if session.isRunning {
                        AgentWorkingRow(stepNumber: session.steps.count + 1,
                                        firstStep: session.steps.isEmpty, palette: p)
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
                        // say so, then GUIDE. A PERMISSION halt is special — the goal was fine, it
                        // just lacked a grant — so instead of "try a different goal", offer the
                        // actual fix: allow the named capability and run it again.
                        AgentHaltBanner(message: message)
                        let grantable = grantableRefusedCapabilities
                        if !grantable.isEmpty {
                            grantAndRunBar(capabilities: grantable, palette: p)
                        } else {
                            AgentExampleList(palette: p, header: "It plans best with clear multi-step goals — try one of these:") { example in
                                goal = example
                            }
                        }
                        runActions(palette: p, showShare: false)
                    } else if session.steps.isEmpty, !session.isRunning {
                        // Educate first: our users aren't computer-native, so before "give me a goal"
                        // we tell them — in plain words — how good THEIR model is at being an agent
                        // and what their hardware can run. Knowing the model's limits up front is the
                        // difference between "it's broken" and "ah, I should phrase this more simply".
                        AgentModelBriefingCard(palette: p)
                        // First run: show what the agent can do instead of a blank screen.
                        // Tapping an example drops it into the field, ready to edit or run.
                        AgentEmptyState(palette: p) { example in goal = example }
                        // Every goal the user has run, newest first — tap to re-use (drops into
                        // the field, ready to edit or send again), remove one via the context
                        // menu, or clear the lot. Same recall affordance chat gets from its
                        // conversation list, sized for goals.
                        if !goalHistory.entries.isEmpty {
                            AgentRecentGoals(entries: goalHistory.entries, palette: p,
                                             onPick: { goal = $0 },
                                             onRemove: { goalHistory.remove($0) },
                                             onClear: { goalHistory.clear() })
                        }
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

            workspaceRow(palette: p)

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
        // The ONLY door into the workspace (fs.list / fs.move): an explicit folder pick.
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                workspace.grant(url)
            }
        }
        // The chat→agent handoff: chat's "Run it with the Agent" posted a goal; the shell already
        // switched here. Consume it and RUN — the tap WAS the run gesture, and every mutation
        // still previews + asks below. @Published re-emits its current value on subscribe, so a
        // goal posted before this view existed still arrives the moment it appears.
        .onReceive(AgentHandoff.shared.$pending) { pending in
            guard let pending, !session.isRunning else { return }
            AgentHandoff.shared.pending = nil
            goal = pending
            run()
        }
        // Per-run approval for mutating actions — the runner is suspended on this answer.
        // Dismissing without choosing counts as NO (the safe reading of silence).
        .confirmationDialog(
            approvals.pending?.summary ?? "",
            isPresented: Binding(
                get: { approvals.pending != nil },
                set: { stillShown in if !stillShown && approvals.pending != nil { approvals.resolve(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow this action") { approvals.resolve(true) }
            Button("Don't allow", role: .cancel) { approvals.resolve(false) }
        }
    }

    /// The workspace chip row: which folder the agent may work in, revoke, and undo.
    @ViewBuilder
    private func workspaceRow(palette p: QuenderinPalette) -> some View {
        if workspace.folderName != nil || undoNotice != nil {
            HStack(spacing: 8) {
                if let name = workspace.folderName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.caption2)
                        Text("\(name) — workspace").font(.caption)
                        Button {
                            workspace.revoke()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Revoke workspace access")
                    }
                    .foregroundStyle(p.onSurfaceVariant)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(p.surface, in: Capsule())

                    if AgentToolkit.undoJournal.count > 0 {
                        Button("Undo last move") {
                            undoNotice = AgentToolkit.undoJournal.undoLast()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(p.primary)
                    }

                    // The generic trust-loop undo: reverse the last task's mac.* creates etc.,
                    // newest-first (the workspace journal above covers file moves).
                    if session.undoableActions > 0 {
                        Button("Undo task changes (\(session.undoableActions))") {
                            Task { undoNotice = await session.undoTask() }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(p.primary)
                        .disabled(session.isRunning)
                    }
                }
                if let notice = undoNotice {
                    Text(notice).font(.caption).foregroundStyle(p.onSurfaceVariant)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    /// Start the typed goal. On a plan failure ("try rephrasing it") the goal is handed back to the
    /// field so the user edits it instead of retyping from scratch.
    /// The capabilities the last run was REFUSED for (missing consent) that are safe to offer a
    /// contextual grant for — everything except T4 irreversible, which stays Settings-only and
    /// deliberate. Read from the run's structured decisions (the refused step's tool name), never
    /// by parsing observation strings.
    private var grantableRefusedCapabilities: [String] {
        // Fire for ANY permission-refused step in the run — not only a .needsPermission halt.
        // A run can end .stalled or .maxSteps while the REAL blocker was a missing grant (e.g. a
        // stray scratchpad call muddied the halt reason); offering the grant is always the fix.
        guard !session.isRunning, session.haltReason != nil else { return [] }
        let tierByName = Dictionary(AgentToolkit.capabilities().map { ($0.name, $0.tier) },
                                    uniquingKeysWith: { first, _ in first })
        var ordered: [String] = []
        var seen = Set<String>()
        func consider(_ name: String) {
            guard !seen.contains(name), let tier = tierByName[name], tier != .irreversible else { return }
            seen.insert(name); ordered.append(name)
        }
        for step in session.steps {
            guard let obs = step.observation, AgentLoop.isPermissionRefusal(obs) else { continue }
            switch step.decision {
            case .useTool(let name, _): consider(name)
            case .plan(let calls): calls.forEach { consider($0.name) }
            case .finalAnswer: break
            }
        }
        return ordered
    }

    /// The one-tap "Allow & run again" affordance on a permission halt. The tap grants STANDING
    /// consent for the named capabilities (the same thing the Settings toggle does — an explicit
    /// user gesture, unreachable by the model) and re-runs the exact goal. Any mutating capability
    /// STILL fires its per-run approval dialog below before it changes anything, so this can never
    /// produce a silent write — the honest subtitle says so.
    @ViewBuilder
    private func grantAndRunBar(capabilities: [String], palette p: QuenderinPalette) -> some View {
        let tierByName = Dictionary(AgentToolkit.capabilities().map { ($0.name, $0.tier) },
                                    uniquingKeysWith: { first, _ in first })
        let anyMutating = capabilities.contains { (tierByName[$0] ?? .readOnly) > .readOnly }
        let names = capabilities.map { "“\($0)”" }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                for name in capabilities { consentStore.setGranted(name, true) }
                let g = session.lastGoal
                Task { await session.run(goal: g) }
            } label: {
                Label("Allow \(names) and run again", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(p.primary)
            .accessibilityLabel("Allow \(capabilities.joined(separator: ", ")) and run the goal again")
            if anyMutating {
                Text("You'll still confirm before it makes any change — this only grants the standing permission.")
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func run() {
        let g = goal.trimmingCharacters(in: .whitespaces)
        guard !session.isRunning, !g.isEmpty else { return }
        // Recorded at SUBMIT, not completion: a cancelled or halted goal is still one the user
        // typed and may want back — the recents list is about recall, not about success.
        goalHistory.record(g)
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

            // Grant the workspace folder fs.list/fs.move work in — one folder at a time.
            Button {
                showFolderPicker = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(p.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    .glassChrome(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .help("Grant a workspace folder the agent may organize (with your approval per change)")
            .accessibilityLabel("Grant a workspace folder")

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
/// screen reads as intentional, not blank. The examples are real "operate my computer" tasks — an
/// agent's job is to DO the work on your machine (open apps, click, type, draft), not to calculate.
private struct AgentEmptyState: View {
    let palette: QuenderinPalette
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(palette.primary)
            #if os(macOS)
            Text("Tell the agent what to do on your Mac")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("It opens apps, clicks, types, and works the tools for you — all on your machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #else
            Text("Give the agent a goal")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("It uses on-device tools to plan and get it done — privately, on your iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #endif
            AgentExampleList(palette: palette, header: nil, onPick: onPick)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// Educates the user, on open, about the model they're running: how good it is as an AGENT, what
/// their hardware can run, and that it all stays on-device. Reads the live active model + RAM and
/// renders `AgentModelGuide.briefing` — the judgment lives in that pure, tested function, not here.
private struct AgentModelBriefingCard: View {
    let palette: QuenderinPalette

    private var briefing: AgentModelBriefing {
        let id = UserDefaults.standard.string(forKey: OnboardingModel.activeModelDefaultsKey)
        #if os(macOS)
        let noun = "Mac"
        #else
        let noun = "iPhone"
        #endif
        return AgentModelGuide.briefing(activeModelID: id,
                                        totalRAMGB: HardwareProbe.current().totalRAMGB,
                                        deviceNoun: noun)
    }

    var body: some View {
        let b = briefing
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").font(.subheadline).foregroundStyle(palette.primary)
                Text(b.modelLabel).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface)
                Spacer()
                AptitudeBadge(aptitude: b.aptitude, palette: palette)
            }
            Text(b.aptitudeDetail).font(.caption).foregroundStyle(palette.onSurfaceVariant)
            Divider().overlay(palette.onSurfaceVariant.opacity(0.15))
            Label { Text(b.hardwareLine).font(.caption).foregroundStyle(palette.onSurfaceVariant) }
                icon: { Image(systemName: "memorychip").font(.caption).foregroundStyle(palette.onSurfaceVariant) }
            if let up = b.upgrade {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").font(.caption).foregroundStyle(palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your device can run \(up.modelLabel) (\(up.aptitude.label))")
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.onSurface)
                        Text(up.reason).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Label { Text(b.privacyNote).font(.caption2).foregroundStyle(palette.onSurfaceVariant) }
                icon: { Image(systemName: "lock.shield").font(.caption2).foregroundStyle(palette.onSurfaceVariant) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.onSurfaceVariant.opacity(0.15), lineWidth: 1))
    }
}

/// A small pill conveying the model's agent aptitude — brand-tinted for the capable-and-up ratings,
/// neutral for the modest ones. Color reinforces the word; the word carries the meaning.
private struct AptitudeBadge: View {
    let aptitude: AgentAptitude
    let palette: QuenderinPalette

    private var tint: Color {
        switch aptitude {
        case .excellent, .strong: return palette.primary
        case .capable, .basic: return palette.onSurfaceVariant
        }
    }

    var body: some View {
        Text(aptitude.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("\(aptitude.label) for agents")
    }
}

/// The tappable example goals — ONE list shared by the empty state and the halt state, so the
/// screen that says "that didn't work" always also shows what DOES. Tapping drops the example
/// into the field, ready to edit or run.
private struct AgentExampleList: View {
    let palette: QuenderinPalette
    let header: String?
    let onPick: (String) -> Void

    // Real tasks for the surface — an agent's job is to operate the device for you, not do
    // arithmetic. macOS drives apps/browser/Mail (lead with the doc-open proven live this session);
    // iOS can't drive other apps (sandbox), so it shows what it CAN do — read on-device context.
    #if os(macOS)
    private static let examples = [
        "Open a new Google Doc in my browser",
        "Add milk and eggs to my Reminders",
        "Draft an email to alex@example.com about tomorrow's meeting",
    ]
    #else
    private static let examples = [
        "What's on my clipboard right now?",
        "What's on my calendar today?",
        "How much battery and storage do I have left?",
    ]
    #endif

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

/// The user's own past goals, newest first — the re-use affordance. Tap drops the goal into
/// the field (same interaction as the examples, so recall and guidance feel like one system);
/// context-menu removes one; the footer button forgets everything. Rendered only on the empty
/// state: once a run is on screen, the transcript owns the space.
private struct AgentRecentGoals: View {
    let entries: [AgentGoalEntry]
    let palette: QuenderinPalette
    let onPick: (String) -> Void
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT GOALS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            ForEach(entries, id: \.goal) { entry in
                Button { onPick(entry.goal) } label: {
                    Label {
                        Text(entry.goal).lineLimit(2)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { onRemove(entry.goal) } label: {
                        Label("Remove from recents", systemImage: "trash")
                    }
                }
                .accessibilityLabel("Re-use goal: \(entry.goal)")
            }
            Button("Clear recent goals", action: onClear)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.top, 2)
                .accessibilityLabel("Clear recent goals")
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The live "the agent is working" row — a spinner, which step it's on, and (on the first
/// step) an honest expectation that on-device planning takes a moment. Present whenever a
/// run is in flight so the screen can never read as frozen.
private struct AgentWorkingRow: View {
    let stepNumber: Int
    let firstStep: Bool
    let palette: QuenderinPalette

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(firstStep ? "Planning the task…" : "Working on step \(stepNumber)…")
                    .font(.callout.weight(.medium))
                if firstStep {
                    Text("The model is thinking on-device — the first step takes the longest.")
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(firstStep ? "Planning the task" : "Working on step \(stepNumber)")
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
                if case let .plan(calls) = step.decision {
                    Text("Plan: " + calls.map { "\($0.name)(\($0.input))" }.joined(separator: " · "))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.onSurface)
                } else if case let .useTool(name, input) = step.decision {
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
