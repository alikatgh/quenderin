#if canImport(SwiftUI)
import SwiftUI

/// The Chat tab: a WhatsApp-style two-level flow. Lands on the conversation LIST; tapping a row (or the
/// "+") pushes the open CONVERSATION (the streaming `ChatView` + its toolbar), and the system back button
/// returns to the list. Bound to `ConversationCoordinator`. Twin of Android's `ChatTab`.
public struct ChatHomeView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    @ObservedObject private var chat: ChatModel
    private let model: ModelEntry
    private let onSelectModel: (ModelEntry) -> Void
    @State private var showConversation = false
    @State private var showProfile = false
    @Environment(\.colorScheme) private var scheme

    public init(coordinator: ConversationCoordinator, model: ModelEntry, onSelectModel: @escaping (ModelEntry) -> Void) {
        self.coordinator = coordinator
        self.chat = coordinator.chat
        self.model = model
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        NavigationStack {
            ConversationListView(
                coordinator: coordinator,
                model: model,
                onOpen: { id in coordinator.open(id); showConversation = true },
                onNew: { coordinator.startNew(); showConversation = true }
            )
            .navigationDestination(isPresented: $showConversation) {
                conversationDetail
            }
        }
        // Persist when leaving the open conversation (back to the list), so the list reflects it.
        .onChange(of: showConversation) { open in
            if !open { coordinator.persist() }
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        let p = QuenderinPalette.of(scheme)
        ChatView(model: chat)
            .inlineNavTitle()
            .toolbar {
                // Tappable model name (twin of Android's tappable chat header) → the model profile.
                ToolbarItem(placement: .principal) {
                    Button { showProfile = true } label: {
                        VStack(spacing: 1) {
                            Text(model.label).font(.headline).foregroundStyle(p.onSurface).lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(p.status).frame(width: 6, height: 6)
                                Text("on-device · private").font(.caption2).foregroundStyle(p.statusText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(model.label)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { coordinator.startNew() } label: { Label("New chat", systemImage: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showProfile) {
                ModelProfileView(model: model, onSelectModel: onSelectModel)
            }
            // Persist when a turn finishes (isGenerating falls), not on every streamed token.
            .onChange(of: chat.isGenerating) { generating in
                if !generating { coordinator.persist() }
            }
    }
}

/// The WhatsApp-style conversation list — the Chat tab's landing screen. Tap a row to open it, swipe to
/// delete, the toolbar "+" starts a new chat. Every conversation is with the same on-device model, so
/// each row is a past SESSION (title from its first message + when it was last active). Twin of Android's
/// `ConversationListScreen`.
struct ConversationListView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    let model: ModelEntry
    let onOpen: (String) -> Void
    let onNew: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = QuenderinPalette.of(scheme)
        Group {
            if coordinator.summaries.isEmpty {
                VStack(spacing: 12) {
                    ModelOrb(size: 72)
                    Text("No conversations yet").font(.headline).foregroundStyle(p.onSurface)
                    Text("Start a chat with \(model.label) — it runs entirely on your \(deviceNoun).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: onNew) { Label("New chat", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(coordinator.summaries) { summary in
                        Button { onOpen(summary.id) } label: {
                            HStack(spacing: 12) {
                                ModelOrb(size: 44)
                                // WhatsApp row anatomy: title over the last-message snippet.
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(summary.title).font(.body).foregroundStyle(p.onSurface).lineLimit(1)
                                    if !summary.preview.isEmpty {
                                        Text(summary.preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                // TimelineView keeps the label live if the list stays on screen
                                // (same fix as the Mac sidebar — never a frozen "in 0 sec").
                                TimelineView(.everyMinute) { context in
                                    Text(Self.relativeDate(summary.updatedAt, now: context.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Last active " + Self.relativeDate(summary.updatedAt, now: context.date))
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        // Delete by STABLE id snapshotted before mutation — each delete() refreshes
                        // `summaries`, so deleting by a shifting index would be wrong.
                        let ids = offsets.map { coordinator.summaries[$0].id }
                        for id in ids { coordinator.delete(id) }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNew) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
            }
        }
    }

    private static func relativeDate(_ epochMillis: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        // Clamp the fresh case: a just-saved row would otherwise read as the future-tense "in 0 sec".
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
