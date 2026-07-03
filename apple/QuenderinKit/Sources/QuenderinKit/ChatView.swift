#if canImport(SwiftUI)
import SwiftUI

/// The chat screen. Themed message bubbles with speaker-side tails, a pill composer with a circular
/// send button, a typing indicator, and an empty state — the SwiftUI twin of Android's redesigned
/// `ChatScreen`, built on the shared `QuenderinPalette` / `BubbleShape` tokens. Tokens land in the
/// assistant bubble live as they stream.
public struct ChatView: View {
    @ObservedObject private var model: ChatModel
    @State private var draft: String = ""
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool

    public init(model: ChatModel) {
        self.model = model
    }

    // Mirrors the Send button's .disabled guard so Return-to-send adds no new behavior.
    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, !model.isGenerating else { return }
        draft = ""
        composerFocused = true   // Return-to-send must not drop keyboard focus mid-conversation
        Task { await model.send(prompt) }
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.messages.isEmpty, !model.isGenerating {
                        EmptyChatState(palette: p)
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVStack(spacing: 6) {
                            DayDivider(text: "Today", palette: p)
                            ForEach(model.messages) { message in
                                ChatBubble(message: message, palette: p)
                                    .id(message.id)
                            }
                            if model.isGenerating {
                                TypingBubble(palette: p)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("typing")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        // On a wide Mac detail pane the transcript reads as a centered column
                        // (like Messages), not a strip hugging the left edge.
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: model.messages.count) { _ in
                    if let lastId = model.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
                .onChange(of: model.isGenerating) { generating in
                    if generating { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }

            Text(SupportContact.aiDisclaimer)
                .font(.caption2)
                .foregroundStyle(p.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)

            composer(palette: p)
                .frame(maxWidth: 760)     // same centered column as the transcript on wide panes
                .frame(maxWidth: .infinity)
        }
        .background(p.background)
        .toolbar {
            // Export the transcript as Markdown the user can share/save — on THEIR terms, never silently.
            if !model.messages.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: ConversationExporter.markdown(model.messages),
                              subject: Text("Quenderin conversation"),
                              message: Text("Exported from Quenderin (on-device)")) {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel("Share conversation")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func composer(palette p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .submitLabel(.send)
                .onSubmit { send() }
                .focused($composerFocused)
                // A chat you just opened (or created with ⌘N) is for TYPING — put the caret there,
                // WhatsApp-style, instead of making the user click the field first.
                .onAppear { composerFocused = true }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(p.surfaceVariant, in: Capsule())

            let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty && !model.isGenerating
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(p.primary.opacity(canSend ? 1 : 0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let palette: QuenderinPalette
    @Environment(\.openURL) private var openURL

    /// Phone-width bubbles look like ribbons in the Mac's wide detail pane.
    static var bubbleMaxWidth: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 300
        #endif
    }

    var body: some View {
        let mine = message.role == .user
        let bubble = VStack(alignment: .leading, spacing: 2) {
            if mine {
                // The user's own message is shown literally (what they typed), not re-interpreted.
                Text(message.text.isEmpty ? "…" : message.text)
                    .foregroundStyle(palette.onUserBubble)
                    .textSelection(.enabled)
            } else if message.text.isEmpty {
                Text("…").foregroundStyle(palette.onAssistantBubble)
            } else {
                // Assistant replies are Markdown — render bold/headings/lists/code instead of raw markers.
                MarkdownText(text: message.text, color: palette.onAssistantBubble)
                    .textSelection(.enabled)
            }
            if message.isFlagged {
                Label(SupportContact.flaggedOutputNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(mine ? palette.userBubble : palette.assistantBubble, in: BubbleShape(mine: mine))
        .frame(maxWidth: Self.bubbleMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)

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

/// Assistant-side "…" while a reply is being generated — three dots pulsing in sequence.
private struct TypingBubble: View {
    let palette: QuenderinPalette
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(palette.assistantTimestamp)
                    .frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * pulse(i))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.assistantBubble, in: BubbleShape(mine: false))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase = 1 }
        }
        .accessibilityLabel("Generating a reply")
    }

    private func pulse(_ i: Int) -> Double {
        // Stagger the three dots so the pulse travels left-to-right.
        let shifted = (phase + Double(i) * 0.22).truncatingRemainder(dividingBy: 1)
        return shifted
    }
}

private struct DayDivider: View {
    let text: String
    let palette: QuenderinPalette
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(palette.onDayDivider)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(palette.dayDivider, in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

private struct EmptyChatState: View {
    let palette: QuenderinPalette
    var body: some View {
        VStack(spacing: 14) {
            ModelAvatar(size: 72)
            Text("Ask Quenderin anything")
                .font(.title3.weight(.medium))
                .foregroundStyle(palette.onSurface)
            Text("Runs entirely on your \(deviceNoun). Nothing you type leaves the device.")
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(32)
    }
}
#endif
