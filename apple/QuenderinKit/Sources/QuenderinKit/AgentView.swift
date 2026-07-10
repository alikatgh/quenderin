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
    /// Header disclosure: what the agent is, model fit, tools, safety — always one tap away.
    @State private var showAgentInfo = false
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
            // Clickable identity header — expand for model, tools, safety (always available).
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAgentInfo.toggle() }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.subheadline).foregroundStyle(p.primary)
                        Text("Agent").font(.headline).foregroundStyle(p.onSurface)
                        Image(systemName: showAgentInfo ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(p.onSurfaceVariant)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(session.isRunning ? p.primary : p.status).frame(width: 6, height: 6)
                        Text(session.isRunning
                             ? "working on your goal…"
                             : "on-device tools · safety-gated · tap for details")
                            .font(.caption2)
                            .foregroundStyle(session.isRunning ? p.primary : p.statusText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent")
            .accessibilityHint(showAgentInfo ? "Hide agent details" : "Show agent details")
            .background(p.surface)

            if showAgentInfo {
                AgentInfoPanel(palette: p, consentStore: consentStore)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(p.surface)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
            ScrollView {
                // Eager VStack on macOS (same reason as chat: LazyVStack remeasure jank on wheel).
                agentStack(spacing: 12) {
                    // Goal card — always visible for the active/last run so the blank planning
                    // state never hides what was asked.
                    if !session.lastGoal.isEmpty, session.isRunning || !session.steps.isEmpty
                        || session.answer != nil || session.haltReason != nil {
                        AgentGoalCard(goal: session.lastGoal, running: session.isRunning, palette: p)
                    }

                    // The WOW: when a recipe matches, a live checklist draws the plan up front and
                    // ticks each row off as the agent actually completes it — honest N-of-M progress
                    // instead of a blank spinner then a wall of JSON.
                    if let recipe = session.activeRecipe {
                        AgentRecipeChecklist(recipe: recipe, cursor: session.recipeCursor,
                                             running: session.isRunning, palette: p)
                    }
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
                    // Live run status: goal phase, what happens next, Stop — never a bare spinner.
                    if session.isRunning {
                        AgentWorkingCard(
                            goal: session.lastGoal,
                            stepNumber: session.steps.count + 1,
                            firstStep: session.steps.isEmpty,
                            hasRecipe: session.activeRecipe != nil,
                            palette: p,
                            onStop: { session.cancel() }
                        )
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
            // The walk-away option: one grant covers every later step of THIS goal only
            // (broker resets at the next run). Blocked actions still refuse regardless.
            Button("Allow all steps for this goal") { approvals.resolveAllForRun() }
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
        let friendly = capabilities.map { CapabilityCatalog.displayName(for: $0) }
        let buttonTitle: String = {
            if friendly.count == 1 {
                return "Allow “\(friendly[0])” and try again"
            }
            return "Allow these and try again"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Button {
                // Grant still keys on stable tool ids — only the label is human.
                for name in capabilities { consentStore.setGranted(name, true) }
                let g = session.lastGoal
                Task { await session.run(goal: g) }
            } label: {
                Label(buttonTitle, systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(p.primary)
            .accessibilityLabel(buttonTitle)
            if friendly.count > 1 {
                Text(friendly.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
            }
            if anyMutating {
                Text("You’ll still confirm before it changes anything — this only turns the capability on.")
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

    /// Eager stack on macOS (smooth wheel), lazy on iOS (memory) — twin of ChatView.transcriptStack.
    @ViewBuilder
    private func agentStack<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: spacing) { content() }
        #else
        LazyVStack(alignment: .leading, spacing: spacing) { content() }
        #endif
    }

    /// Composer twin of chat — while a run is live the circle is **Stop** (not a dead spinner).
    @ViewBuilder
    private func composer(palette p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    .background(p.surfaceVariant.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .help("Attach a file the agent may read (with your permission)")
            .accessibilityLabel("Attach a file")

            Button {
                showFolderPicker = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(p.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    .background(p.surfaceVariant.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .help("Grant a workspace folder the agent may organize (with your approval per change)")
            .accessibilityLabel("Grant a workspace folder")

            TextField(session.isRunning ? "Agent is working on your goal…" : "Give the agent a goal…",
                      text: $goal)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .submitLabel(.go)
                .onSubmit { run() }
                .disabled(session.isRunning)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(p.surfaceVariant.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(p.onSurfaceVariant.opacity(0.12), lineWidth: 1))

            let canRun = !goal.trimmingCharacters(in: .whitespaces).isEmpty && !session.isRunning
            Button {
                if session.isRunning {
                    session.cancel()
                } else {
                    run()
                }
            } label: {
                Group {
                    if session.isRunning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    (session.isRunning ? Color.orange : p.primary)
                        .opacity(canRun || session.isRunning ? 1 : 0.4),
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .disabled(!canRun && !session.isRunning)
            .help(session.isRunning ? "Stop the agent" : "Run goal")
            .accessibilityLabel(session.isRunning ? "Stop agent" : "Run goal")
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

/// The live plan checklist — the world-class multi-step WOW. It draws the recipe's steps the instant
/// a recipe matches (before the model even finishes its first decode), then each row flips
/// pending-circle → active-spinner → teal check as the cursor advances on a REAL executed-tool match
/// (never a fabricated tick). Per UI_DESIGN_RULES, only the leading glyph's icon/color changes with
/// state — the fixed 16×16 slot means geometry never shifts.
private struct AgentRecipeChecklist: View {
    let recipe: AgentRecipe
    let cursor: Int
    let running: Bool
    let palette: QuenderinPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // A DYNAMIC plan is the agent's OWN proposal (its denominator is a model estimate), so it
                // reads as "Plan · the agent's plan" with a completed count — never a vouched "Step N of M"
                // track a fully-green run could mistake for a guaranteed goal-achieving chain.
                Image(systemName: recipe.isDynamic ? "wand.and.stars" : "checklist")
                    .font(.caption).foregroundStyle(palette.primary)
                Text(recipe.isDynamic ? "Plan" : recipe.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface)
                if recipe.isDynamic {
                    Text("· the agent's plan").font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                }
                Spacer()
                Text(recipe.isDynamic
                     ? "\(min(cursor, recipe.steps.count)) of \(recipe.steps.count) done"
                     : "Step \(min(cursor + 1, recipe.steps.count)) of \(recipe.steps.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    ZStack {
                        if i < cursor {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.primary)
                        } else if i == cursor && running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(palette.onSurfaceVariant.opacity(0.45))
                        }
                    }
                    .frame(width: 16, height: 16)
                    .font(.caption)
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(i < cursor ? palette.onSurfaceVariant : palette.onSurface)
                        .fontWeight(i == cursor && running ? .semibold : .regular)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.primary.opacity(0.22), lineWidth: 1))
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
    // The recipe-triggering goals — tapping one fires the live checklist (the multi-step WOW), so the
    // empty state teaches exactly what the agent reliably does, end to end. Single source of truth.
    private static let examples = AgentRecipe.all.map(\.exampleGoal)
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

/// Goal banner for the active/last run — the field is cleared on submit, so this is where
/// the user always sees what was asked.
private struct AgentGoalCard: View {
    let goal: String
    let running: Bool
    let palette: QuenderinPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(running ? "YOUR GOAL" : "GOAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            Text(goal)
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.onSurfaceVariant.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Goal: \(goal)")
    }
}

/// Live run status — phase, what happens next, Stop. Replaces the bare "Planning…" spinner.
private struct AgentWorkingCard: View {
    let goal: String
    let stepNumber: Int
    let firstStep: Bool
    let hasRecipe: Bool
    let palette: QuenderinPalette
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(firstStep ? "Planning the first step…" : "Working on step \(stepNumber)…")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                    Text(phaseDetail)
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onStop) {
                    Text("Stop")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop agent")
            }

            Divider().overlay(palette.onSurfaceVariant.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                infoLine(icon: "lock.shield",
                         text: "Nothing leaves this Mac. Tools only run with your grants.")
                infoLine(icon: "hand.raised",
                         text: "If a step would change something, you’ll get an Allow / Don’t allow prompt first.")
                infoLine(icon: "checkmark.shield",
                         text: "Turn tools on in Settings → Agent if a step says it needs permission.")
                if firstStep {
                    infoLine(icon: "clock",
                             text: "The first plan is the slowest — the model loads your goal on-device.")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.primary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(firstStep ? "Planning the first step" : "Working on step \(stepNumber)")
    }

    private var phaseDetail: String {
        if firstStep {
            return hasRecipe
                ? "Matched a built-in plan — drafting the first tool call."
                : "Reading your goal and choosing the first tool. This can take a moment."
        }
        return "Running the next tool, then checking the result before continuing."
    }

    private func infoLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(palette.primary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Expandable "what is the Agent" panel — model fit, tools, how consent works. Opened from the header.
private struct AgentInfoPanel: View {
    let palette: QuenderinPalette
    let consentStore: ConsentStore

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

    private var grantedTools: [String] {
        AgentToolkit.capabilities()
            .filter { !$0.requiresConsent || consentStore.isGranted($0.name) }
            .map { CapabilityCatalog.displayName(for: $0.name) }
    }

    private var lockedTools: [String] {
        AgentToolkit.capabilities()
            .filter { $0.requiresConsent && !consentStore.isGranted($0.name) }
            .map { CapabilityCatalog.displayName(for: $0.name) }
    }

    var body: some View {
        let b = briefing
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(palette.primary)
                Text(b.modelLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.onSurface)
                Spacer()
                AptitudeBadge(aptitude: b.aptitude, palette: palette)
            }
            Text(b.aptitudeDetail)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            Text(b.hardwareLine)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Divider().overlay(palette.onSurfaceVariant.opacity(0.12))

            Text("HOW IT WORKS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            Text("You give a goal. The agent plans steps, uses tools on this device, and shows each step in the run log. Mutating actions always ask you first.")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if !grantedTools.isEmpty {
                Text("READY TO USE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(.top, 2)
                Text(grantedTools.prefix(12).joined(separator: " · ")
                     + (grantedTools.count > 12 ? " · …" : ""))
                    .font(.caption)
                    .foregroundStyle(palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !lockedTools.isEmpty {
                Text("NEEDS YOUR OK IN SETTINGS → AGENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(.top, 2)
                Text(lockedTools.prefix(10).joined(separator: " · ")
                     + (lockedTools.count > 10 ? " · …" : ""))
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(b.privacyNote)
                .font(.caption2)
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceVariant.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.onSurfaceVariant.opacity(0.12), lineWidth: 1)
        )
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
                    Text("Plan: " + calls.map {
                        let label = CapabilityCatalog.displayName(for: $0.name)
                        return $0.input.isEmpty ? label : "\(label) — \($0.input)"
                    }.joined(separator: " · "))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.onSurface)
                } else if case let .useTool(name, input) = step.decision {
                    // People see "Add a calendar event"; model/ledger still use the tool id.
                    Text(CapabilityCatalog.displayName(for: name))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.primary)
                    if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(input)
                            .font(.caption)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .textSelection(.enabled)
                    }
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
