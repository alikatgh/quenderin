#if canImport(SwiftUI)
import SwiftUI

/// The Chat tab: the live streaming chat, plus a History button (browse/switch) and a New-chat
/// button. Persists the conversation when each turn finishes, so it survives relaunch. Wraps
/// `ChatView` so that screen stays a pure streaming view. Bound to `ConversationCoordinator`.
public struct ChatHomeView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    @ObservedObject private var chat: ChatModel
    private let model: ModelEntry
    private let onSelectModel: (ModelEntry) -> Void
    @State private var showHistory = false
    @State private var showProfile = false
    @Environment(\.colorScheme) private var scheme

    public init(coordinator: ConversationCoordinator, model: ModelEntry, onSelectModel: @escaping (ModelEntry) -> Void) {
        self.coordinator = coordinator
        self.chat = coordinator.chat
        self.model = model
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        NavigationStack {
            ChatView(model: chat)
                .inlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { showHistory = true } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    // Tappable model name (twin of Android's tappable chat header) → the model profile.
                    ToolbarItem(placement: .principal) {
                        Button { showProfile = true } label: {
                            VStack(spacing: 1) {
                                Text(model.label)
                                    .font(.headline)
                                    .foregroundStyle(p.onSurface)
                                    .lineLimit(1)
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
                        Button { coordinator.startNew() } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                    }
                }
                .sheet(isPresented: $showHistory) {
                    ConversationHistoryView(coordinator: coordinator) { showHistory = false }
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
}

/// The chat-history list: tap to open a past conversation, swipe to delete. Presented as a sheet
/// from `ChatHomeView`.
struct ConversationHistoryView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    let onDismiss: () -> Void
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.summaries.isEmpty {
                    Text("No conversations yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("No conversations yet")
                        .accessibilityHint("Start chatting on the Chat tab and your conversations will appear here.")
                } else {
                    List {
                        ForEach(coordinator.summaries) { summary in
                            Button {
                                coordinator.open(summary.id)
                                onDismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.title)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(Self.relativeDate(summary.updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Updated " + Self.relativeDateFull(summary.updatedAt))
                                }
                            }
                        }
                        .onDelete { offsets in
                            // Snapshot the IDs against the *current* array before deleting — each
                            // delete() calls refresh() and mutates `summaries`, so deleting by a
                            // stable id (not a shifting index) is required for correctness.
                            let ids = offsets.map { coordinator.summaries[$0].id }
                            for id in ids { coordinator.delete(id) }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !coordinator.summaries.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear All", role: .destructive) { showClearConfirm = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDismiss) }
            }
            .confirmationDialog("Delete all conversations?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { coordinator.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every saved conversation from this device.")
            }
        }
    }

    private static func relativeDate(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func relativeDateFull(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
