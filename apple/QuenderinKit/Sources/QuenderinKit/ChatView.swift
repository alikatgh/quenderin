#if canImport(SwiftUI)
import SwiftUI

/// Minimal streaming chat screen. Tokens land in the assistant bubble live.
public struct ChatView: View {
    @ObservedObject private var model: ChatModel
    @State private var draft: String = ""

    public init(model: ChatModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        ChatBubble(message: message)
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask anything…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    let prompt = draft
                    draft = ""
                    Task { await model.send(prompt) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isGenerating)
            }
            .padding()
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.role == .user ? "You" : "Quenderin")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
#endif
