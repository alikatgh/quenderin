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
            .padding(.horizontal)
            .padding(.top, 8)
            Text(SupportContact.aiDisclaimer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @Environment(\.openURL) private var openURL

    var body: some View {
        let bubble = VStack(alignment: .leading, spacing: 2) {
            Text(message.role == .user ? "You" : "Quenderin")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

        // Report affordance on AI responses only (Generative-AI content policy).
        if message.role == .assistant, !message.text.isEmpty {
            bubble.contextMenu {
                Button {
                    if let url = SupportContact.reportMailto(reportedText: message.text, context: "chat") {
                        openURL(url)
                    }
                } label: {
                    Label("Report response", systemImage: "flag")
                }
            }
        } else {
            bubble
        }
    }
}
#endif
