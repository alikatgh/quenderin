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
        conversations.startNew()
        if let id = conversations.currentID { selection = .conversation(id) }
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

/// One sidebar conversation: title, with the relative "last active" time as the subtitle.
private struct SidebarChatRow: View {
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.title).lineLimit(1)
            Text(Self.relative(summary.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private static func relative(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// What the Mac sidebar can select: a conversation, or the Agent tool.
enum SidebarItem: Hashable {
    case conversation(String)
    case agent
}
#endif
