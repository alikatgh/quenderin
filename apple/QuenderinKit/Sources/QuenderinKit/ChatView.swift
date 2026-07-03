#if canImport(SwiftUI)
import SwiftUI

/// The chat screen. Themed message bubbles with speaker-side tails, a pill composer with a circular
/// send button, a typing indicator, and an empty state — the SwiftUI twin of Android's redesigned
/// `ChatScreen`, built on the shared `QuenderinPalette` / `BubbleShape` tokens. Tokens land in the
/// assistant bubble live as they stream.
public struct ChatView: View {
    @ObservedObject private var model: ChatModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft: String = ""
    @State private var suggestionDismissed = false
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool

    /// The loaded model + a switch action — when provided, the router can suggest a better
    /// installed model for a NEW chat's first message (a tappable chip, never a silent swap).
    private let activeModel: ModelEntry?
    private let onSwitchModel: ((ModelEntry) -> Void)?
    /// When set, this conversation's appearance overrides (ChatPrefsStore) beat the globals.
    private let conversationID: String?
    @ObservedObject private var chatPrefs = ChatPrefsStore.shared

    public init(model: ChatModel, activeModel: ModelEntry? = nil,
                onSwitchModel: ((ModelEntry) -> Void)? = nil, conversationID: String? = nil) {
        self.model = model
        self.activeModel = activeModel
        self.onSwitchModel = onSwitchModel
        self.conversationID = conversationID
    }

    /// This chat's font: per-conversation override where present, the Settings default otherwise.
    private var effectiveChatFont: Font {
        guard let id = conversationID else { return settings.chatFont }
        let style = chatPrefs.fontStyle(for: id).flatMap(AppSettings.ChatFontStyle.init(rawValue:))
            ?? settings.chatFontStyle
        let size = chatPrefs.fontSize(for: id).flatMap(AppSettings.ChatFontSize.init(rawValue:))
            ?? settings.chatFontSize
        return .system(size: size.points, design: style.design)
    }

    /// Router suggestion for the drafted FIRST message: only in an empty chat, only when the
    /// pick differs from the loaded model, and only from what's actually installed.
    private var routeSuggestion: (decision: RouteDecision, entry: ModelEntry)? {
        guard settings.suggestBestModel, !suggestionDismissed,
              let active = activeModel, onSwitchModel != nil,
              model.messages.isEmpty, draft.trimmingCharacters(in: .whitespaces).count >= 12 else { return nil }
        let installed = ModelManager(
            storage: FileManagerModelStorage(directory: OnboardingModel.defaultModelsDir()),
            activeModelID: active.id
        ).installed().map(\.model)
        guard installed.count > 1,
              let decision = ModelRouter.route(prompt: draft, installed: installed),
              decision.modelID != active.id,
              let entry = installed.first(where: { $0.id == decision.modelID }) else { return nil }
        return (decision, entry)
    }

    // Mirrors the Send button's .disabled guard so Return-to-send adds no new behavior.
    private func send() {
        suggestionDismissed = false
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
                        // macOS gets a PLAIN VStack: LazyVStack destroys/recreates rows while you
                        // scroll and estimates-then-corrects their heights, which made wheel
                        // scrolling stutter and jump on long Markdown replies. A transcript's row
                        // count is modest and each row is cheap once the Markdown parse is cached
                        // (see MarkdownText), so laziness bought nothing here. iOS keeps the lazy
                        // stack for memory on phones.
                        transcriptStack {
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
                        .environment(\.font, effectiveChatFont)   // per-chat override ?? Settings default
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

            if let suggestion = routeSuggestion {
                RouteSuggestionChip(
                    decision: suggestion.decision,
                    entry: suggestion.entry,
                    palette: p,
                    onSwitch: { onSwitchModel?(suggestion.entry) },
                    onDismiss: { suggestionDismissed = true }
                )
                .frame(maxWidth: 760)
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

    /// The transcript container: eager on macOS (smooth wheel scrolling), lazy on iOS (memory).
    @ViewBuilder
    private func transcriptStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        VStack(spacing: 6) { content() }
        #else
        LazyVStack(spacing: 6) { content() }
        #endif
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
                // Liquid Glass on OS 26 (material below): the composer is chrome floating
                // over the transcript, not part of the content.
                .glassChrome(in: Capsule())

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
        // BOTH frames must align to the speaker's side: the inner cap-width frame still expands
        // to bubbleMaxWidth when the pane is wider, so a short user bubble pinned .leading inside
        // it would float mid-pane instead of hugging the right edge.
        .frame(maxWidth: Self.bubbleMaxWidth, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)

        // Every bubble answers a right-click: Copy always; Report on AI responses only
        // (Generative-AI content policy).
        bubble.contextMenu {
            if !message.text.isEmpty {
                Button {
                    copyToPasteboard(message.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if message.role == .assistant, !message.text.isEmpty {
                Button {
                    if let url = SupportContact.reportMailto(reportedText: message.text, context: "chat") {
                        openURL(url)
                    }
                } label: {
                    Label("Report response", systemImage: "flag")
                }
            }
        }
    }
}

/// The router's pick, offered — never imposed: "coding question → Qwen2.5 Coder · Switch".
/// Appears above the composer while drafting the FIRST message of a chat; one tap switches
/// the model (the draft survives), the ✕ dismisses it for this message.
private struct RouteSuggestionChip: View {
    let decision: RouteDecision
    let entry: ModelEntry
    let palette: QuenderinPalette
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ModelAvatar(size: 22, modelID: entry.id)
            Text(decision.reason)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Switch") { onSwitch() }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.primary)
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassChrome(in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
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
            .glassChrome(in: Capsule())
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
