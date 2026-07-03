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

    @State private var selection: SidebarItem?
    @State private var showProfile = false
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
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            if selection == nil, let id = conversations.currentID {
                selection = .conversation(id)
            }
        }
        // Selecting a sidebar row opens that conversation (open() persists the one being left).
        .onChange(of: selection) { newValue in
            if case let .conversation(id) = newValue, id != conversations.currentID {
                conversations.open(id)
            }
        }
        // Follow the coordinator wherever a conversation change originates — the sidebar button,
        // the File-menu ⌘N (which talks to the coordinator directly and can't reach this view's
        // @State), or a delete fallback. Without this, ⌘N created a chat but left the detail pane
        // showing whatever was selected before.
        .onChange(of: conversations.currentID) { (newID: String?) in
            if let id = newID, selection != .conversation(id) {
                selection = .conversation(id)
            }
        }
        // "New Chat" must never be a dead control: even when startNew() no-ops (the current chat
        // is already empty), jump the selection back to that empty chat — e.g. from the Agent pane.
        .onChange(of: conversations.newChatSignal) { (_: Int) in
            if let id = conversations.currentID {
                selection = .conversation(id)
            }
        }
        // Persist when a turn finishes (isGenerating falls), so sidebar titles/times stay live.
        .onChange(of: chat.isGenerating) { generating in
            if !generating { conversations.persist() }
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
                            .tag(SidebarItem.conversation(summary.id))
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(summary.id) }
                            }
                    }
                }
            }
            if agent != nil {
                Section("Tools") {
                    Label("Agent", systemImage: "sparkles")
                        .tag(SidebarItem.agent)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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
        if case .conversation(id) = selection {
            selection = conversations.currentID.map(SidebarItem.conversation)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        let p = QuenderinPalette.of(scheme)
        switch selection {
        case .agent:
            AgentView(session: agent!)
                .navigationTitle("Agent")
        case .conversation:
            ChatView(model: chat)
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
                    ModelProfileView(model: model, onSelectModel: { onboarding.beginInstall($0) })
                        .frame(minWidth: 480, minHeight: 520)
                }
        case nil:
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

/// One sidebar conversation, WhatsApp-anatomy: avatar orb · title over last-message snippet ·
/// compact time in the top-right corner.
private struct SidebarChatRow: View {
    let summary: ConversationSummary

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ModelAvatar(size: 34)
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
enum SidebarItem: Hashable {
    case conversation(String)
    case agent
}
#endif
