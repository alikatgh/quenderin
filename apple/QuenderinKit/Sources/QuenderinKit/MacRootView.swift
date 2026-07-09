#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// The Mac-idiom shell: a `NavigationSplitView` with conversations in the sidebar and the open chat
/// in the detail pane — replacing the phone's TabView-in-a-window. The Agent lives in a Tools
/// section of the sidebar; Settings is the standard ⌘, scene (see QuenderinApp); ⌘N starts a new
/// chat (File menu, via the app's commands). This file is macOS-only; iOS keeps its TabView flow.
public struct MacRootView: View {
    @ObservedObject private var onboarding: OnboardingModel
    @ObservedObject private var conversations: ConversationCoordinator
    @ObservedObject private var chat: ChatModel
    private let agent: AgentSession?
    private let model: ModelEntry

    /// Sidebar selection as a SET: single click opens a chat; ⌘-click / ⇧-click (or a long
    /// press on a row) grow it into a multi-selection for bulk actions.
    @State private var selection = Set<String>()
    @State private var confirmBulkDelete = false
    @State private var showProfile = false
    @State private var rail: RailSection = .chats
    @ObservedObject private var library = ModelLibraryController.shared
    @Environment(\.colorScheme) private var scheme

    public init(
        onboarding: OnboardingModel,
        conversations: ConversationCoordinator,
        agent: AgentSession?,
        model: ModelEntry
    ) {
        self.onboarding = onboarding
        self.conversations = conversations
        self.chat = conversations.chat
        self.agent = agent
        self.model = model
    }

    public var body: some View {
        // WhatsApp anatomy: a fixed icon RAIL (sections) · list column · detail. Each rail
        // destination is a dedicated page, not a row squeezed into the chats sidebar.
        // Chat→agent handoff: when chat posts a goal ("Run it with the Agent"), jump the rail to
        // the Agent page — AgentView consumes and runs the pending goal on appear.
        HStack(spacing: 0) {
            railColumn
            Divider()
            switch rail {
            case .chats:
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            case .agent:
                if let agent {
                    AgentView(session: agent)
                } else {
                    Text("The agent needs a loaded model.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .search:
                UniversalSearchView(activeModelID: model.id, onSelectModel: { onboarding.beginInstall($0) })
            case .models:
                ModelsLibraryView(activeModelID: model.id, onSelectModel: { onboarding.beginInstall($0) })
            case .about:
                AboutView()
            }
        }
        .onAppear {
            if selection.isEmpty, let id = conversations.currentID {
                selection = [id]
            }
        }
        // Chat posted a goal via the handoff bar — switch to the Agent page, which consumes it.
        .onReceive(AgentHandoff.shared.$pending) { pending in
            if pending != nil { rail = .agent }
        }
        // A SINGLE selected row opens that conversation (open() persists the one being left);
        // a multi-selection changes nothing until the user picks a bulk action.
        .onChange(of: selection) { newValue in
            if newValue.count == 1, let id = newValue.first, id != conversations.currentID {
                conversations.open(id)
            }
        }
        // Follow the coordinator wherever a conversation change originates — the sidebar button,
        // the File-menu ⌘N (which talks to the coordinator directly and can't reach this view's
        // @State), or a delete fallback. Without this, ⌘N created a chat but left the detail pane
        // showing whatever was selected before. (Never while a multi-selection is in progress.)
        .onChange(of: conversations.currentID) { (newID: String?) in
            if let id = newID, selection.count <= 1, selection != [id] {
                selection = [id]
            }
        }
        // "New Chat" must never be a dead control: even when startNew() no-ops (the current chat
        // is already empty), jump the selection back to that empty chat — e.g. from the Agent pane.
        .onChange(of: conversations.newChatSignal) { (_: Int) in
            rail = .chats   // ⌘N from any rail section lands you in the empty chat, ready to type
            if let id = conversations.currentID {
                selection = [id]
            }
        }
        // Persist when a turn finishes (isGenerating falls), so sidebar titles/times stay live.
        .onChange(of: chat.isGenerating) { generating in
            if !generating { conversations.persist() }
        }
        // A real Mac app never collapses into a sliver (same lesson as the Settings window).
        .frame(minWidth: 860, minHeight: 520)
        // ⌘1–⌘4 walk the rail; ⌘F / ⌘K open universal Search.
        .background {
            Group {
                Button("") { rail = .chats }.keyboardShortcut("1", modifiers: .command)
                // Q-581: always navigate to the Agent rail on ⌘2. It used to no-op silently when the agent
                // was unavailable (`agent == nil`), leaving the user with no idea why the key did nothing.
                // The `.agent` destination already renders an honest "The agent needs a loaded model."
                // placeholder in that case, so this shows the reason instead of swallowing the keystroke.
                Button("") { rail = .agent }.keyboardShortcut("2", modifiers: .command)
                Button("") { rail = .search }.keyboardShortcut("3", modifiers: .command)
                Button("") { rail = .models }.keyboardShortcut("4", modifiers: .command)
                Button("") { rail = .search }.keyboardShortcut("f", modifiers: .command)
                Button("") { rail = .search }.keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Chats") {
                if conversations.summaries.isEmpty {
                    Text("No chats yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(conversations.summaries) { summary in
                        SidebarChatRow(summary: summary)
                            .tag(summary.id)
                            // NO long-press recognizer here: it forced every click through a
                            // 0.4s disambiguation and made plain chat switching feel broken
                            // (owner: "almost impossible to use"). Multi-select is ⌘-click /
                            // ⇧-click / ⌫ / the context menu — the Mac-native paths.
                            .contextMenu {
                                Button("Open") { selection = [summary.id] }
                                if selection.count > 1, selection.contains(summary.id) {
                                    Button("Delete \(selection.count) chats…", role: .destructive) {
                                        confirmBulkDelete = true
                                    }
                                } else {
                                    Button("Delete", role: .destructive) { delete(summary.id) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        // ⌫ deletes the selection — one chat or many (with the same confirmation).
        .onDeleteCommand { if !selection.isEmpty { confirmBulkDelete = true } }
        .confirmationDialog(
            "Delete \(selection.count) \(selection.count == 1 ? "chat" : "chats")?",
            isPresented: $confirmBulkDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their transcripts and per-chat settings are removed from this Mac. This can't be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newChat) { Image(systemName: "square.and.pencil") }
                    .help("New chat (⌘N)")
                    .accessibilityLabel("New chat")
            }
        }
    }

    private func newChat() {
        conversations.startNew()   // selection follows via the newChatSignal observer
    }

    private func delete(_ id: String) {
        conversations.delete(id)
        // Deleting the selected chat: follow the coordinator to whatever it fell back to.
        if selection.contains(id) {
            selection = conversations.currentID.map { [$0] } ?? []
        }
    }

    private func deleteSelected() {
        conversations.deleteMany(selection)
        selection = conversations.currentID.map { [$0] } ?? []
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        let p = QuenderinPalette.of(scheme)
        if selection.count > 1 {
            MultiSelectPane(
                count: selection.count,
                palette: p,
                onDelete: { confirmBulkDelete = true },
                onCancel: { selection = conversations.currentID.map { [$0] } ?? [] }
            )
        } else if selection.count == 1 {
            ChatView(model: chat, activeModel: model, onSwitchModel: { onboarding.beginInstall($0) }, conversationID: conversations.currentID)
                // Re-identify the view per conversation: switching chats resets scroll state and
                // refires onAppear, which puts the caret in the composer (see ChatView).
                .id(conversations.currentID)
                .navigationTitle("")   // the model header below is the title
                .toolbar {
                    // Tappable model identity (twin of the mobile chat header) → the model profile.
                    ToolbarItem(placement: .principal) {
                        Button { showProfile = true } label: {
                            HStack(spacing: 6) {
                                Circle().fill(p.status).frame(width: 7, height: 7)
                                Text(model.label).font(.headline).foregroundStyle(p.onSurface)
                                Text("on-device · private").font(.caption).foregroundStyle(p.statusText)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("About \(model.label)")
                        .accessibilityLabel("About \(model.label)")
                    }
                }
                .sheet(isPresented: $showProfile) {
                    ModelProfileView(model: model, onSelectModel: { onboarding.beginInstall($0) },
                                     conversationID: conversations.currentID)
                        .frame(minWidth: 480, minHeight: 560)
                }
        } else {
            VStack(spacing: 10) {
                ModelOrb(size: 56)
                Text("Select a chat, or press ⌘N to start one.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.background)
        }
    }
}

/// The detail pane while SEVERAL chats are selected: the count, the one destructive action,
/// and a way out — nothing else competes for attention.
private struct MultiSelectPane: View {
    let count: Int
    let palette: QuenderinPalette
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(palette.primary)
            Text("\(count) chats selected")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.onSurface)
            Text("⌘-click rows to change the selection; ⇧-click selects a range.")
                .font(.callout)
                .foregroundStyle(palette.onSurfaceVariant)
            HStack(spacing: 10) {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete \(count) chats…", systemImage: "trash")
                }
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }
}

/// One sidebar conversation, WhatsApp-anatomy: avatar orb · title over last-message snippet ·
/// compact time in the top-right corner.
private struct SidebarChatRow: View {
    let summary: ConversationSummary

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            // The row wears the family colors of the model that answered in that conversation —
            // people run several models, and the avatar is how rows tell them apart at a glance.
            ModelAvatar(size: 34, modelID: summary.modelID)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // TimelineView re-renders each minute: a Mac sidebar sits open for hours, and
                    // a label computed once at persist time would otherwise freeze at the string
                    // it was born with ("in 0 sec" — forever).
                    TimelineView(.everyMinute) { context in
                        Text(Self.compactTime(summary.updatedAt, now: context.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary.preview.isEmpty ? "No messages yet" : summary.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// WhatsApp-style corner time: "now" this minute, minutes/hours today-ish, weekday inside a
    /// week, short date beyond. Clamped so a just-saved row never reads future-tense ("in 0 sec").
    static func compactTime(_ epochMillis: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(seconds < 7 * 86_400 ? "EEE" : "dMMM")
        return formatter.string(from: date)
    }
}

/// What the Mac sidebar can select: a conversation, or the Agent tool.
/// The rail's destinations. Settings deliberately isn't one — the gear at the rail's foot
/// opens the standard macOS Settings scene (⌘,), the Mac-idiomatic home for preferences.
enum RailSection: Hashable {
    case chats, agent, search, models, about
}

extension MacRootView {
    /// The WhatsApp-style fixed icon rail: Chats / Agent / Models, gear at the foot.
    /// Selection reads through COLOR only (tinted rounded fill), never geometry.
    @ViewBuilder
    var railColumn: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 6) {
            railButton(.chats, icon: "bubble.left.and.bubble.right", label: "Chats (⌘1)", palette: p)
            if agent != nil {
                railButton(.agent, icon: "sparkles", label: "Agent (⌘2)", palette: p)
            }
            railButton(.search, icon: "magnifyingglass", label: "Search (⌘F)", palette: p)
            railButton(.models, icon: "books.vertical", label: "Model library (⌘4)", palette: p)
                .overlay(alignment: .topTrailing) {
                    // Live download activity: a thin progress ring + count, visible from any
                    // section — the library keeps working when you go back to chatting.
                    if library.activeDownloadCount > 0 {
                        ZStack {
                            Circle().fill(p.surface)
                            Circle()
                                .trim(from: 0, to: max(0.03, library.overallDownloadProgress))
                                .stroke(p.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(library.activeDownloadCount)")
                                .font(.system(size: 8, weight: .bold).monospacedDigit())
                                .foregroundStyle(p.onSurface)
                        }
                        .frame(width: 16, height: 16)
                        .offset(x: 2, y: -2)
                        .accessibilityLabel("\(library.activeDownloadCount) models downloading")
                    }
                }
            Spacer()
            // The elf opens the dedicated About PAGE (was a popup menu — owner wanted a page).
            Button {
                rail = .about
            } label: {
                ModelAvatar(size: 30)
                    .overlay(
                        Circle().strokeBorder(
                            rail == .about ? p.primary : .clear, lineWidth: 2
                        )
                    )
            }
            .buttonStyle(.plain)
            .help("About Quenderin — settings, help, and links")
            .accessibilityLabel("About Quenderin")
            .accessibilityAddTraits(rail == .about ? [.isSelected] : [])
            .padding(.bottom, 10)
        }
        .padding(.top, 12)
        // 78pt, not 64: the traffic lights span ~x12–68 — at 64 the green light straddled
        // the rail/list color seam (owner screenshot). All three now sit on one surface.
        .frame(width: 78)
        .background(p.surface)
    }

    @ViewBuilder
    private func railButton(_ section: RailSection, icon: String, label: String, palette p: QuenderinPalette) -> some View {
        Button {
            rail = section
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(rail == section ? p.primary : p.onSurfaceVariant)
                .frame(width: 44, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(rail == section ? p.primary.opacity(0.16) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(rail == section ? [.isSelected] : [])
    }
}

enum SidebarItem: Hashable {
    case conversation(String)
}
#endif
