#if canImport(SwiftUI)
import SwiftUI

/// The Chat tab: the live streaming chat, plus a History button (browse/switch) and a New-chat
/// button. Persists the conversation when each turn finishes, so it survives relaunch. Wraps
/// `ChatView` so that screen stays a pure streaming view. Bound to `ConversationCoordinator`.
public struct ChatHomeView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    @ObservedObject private var chat: ChatModel
    @State private var showHistory = false

    public init(coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        self.chat = coordinator.chat
    }

    public var body: some View {
        NavigationStack {
            ChatView(model: chat)
                .navigationTitle("Chat")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { showHistory = true } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
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
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { coordinator.summaries[$0].id }.forEach(coordinator.delete)
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
}
#endif
