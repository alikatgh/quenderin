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
    /// Documents queued for the NEXT send (chips above the composer) — extracted at attach time,
    /// cleared once the message goes out. Milestone 1: documents-as-text in chat.
    @State private var pendingDocuments: [AttachedDocument] = []
    @State private var attachmentNotice: String?
    @State private var showAttachPicker = false
    /// Where the transcript's bottom edge sits in viewport coordinates, and the viewport's
    /// height — nearBottom is DERIVED from the pair in body, so it can never go stale when
    /// one arrives before the other (the ↓ button haunted empty chats when a preference
    /// fired before onAppear had measured the viewport).
    @State private var sentinelY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// Streaming auto-follows ONLY while this is true — the moment you scroll up to re-read,
    /// the app stops fighting you and a floating ↓ offers the way back.
    private var nearBottom: Bool { sentinelY < viewportHeight + 140 }
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
        // Documents alone are a legitimate send ("summarize this file" with no extra words).
        guard !prompt.isEmpty || !pendingDocuments.isEmpty, !model.isGenerating else { return }
        let documents = pendingDocuments
        pendingDocuments = []
        attachmentNotice = nil
        draft = ""
        composerFocused = true   // Return-to-send must not drop keyboard focus mid-conversation
        Task { await model.send(prompt, documents: documents) }
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
              GeometryReader { viewport in
                ScrollView {
                    if model.messages.isEmpty, !model.isGenerating {
                        EmptyChatState(palette: p, activeModel: activeModel)
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        // macOS gets a PLAIN VStack: LazyVStack destroys/recreates rows while you
                        // scroll and estimates-then-corrects their heights, which made wheel
                        // scrolling stutter and jump on long Markdown replies. A transcript's row
                        // count is modest and each row is cheap once the Markdown parse is cached
                        // (see MarkdownText), so laziness bought nothing here. iOS keeps the lazy
                        // stack for memory on phones.
                        transcriptStack(spacing: settings.messageDensity.spacing) {
                            DayDivider(text: "Today", palette: p)
                            ForEach(model.messages) { message in
                                ChatBubble(message: message, palette: p,
                                           accent: settings.bubbleAccent.colors(dark: scheme == .dark))
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
                    // Bottom sentinel: its position in the scroll coordinate space tells us
                    // whether the transcript's tail is on screen (drives follow + the ↓ button).
                    GeometryReader { geo in
                        Color.clear.preference(key: BottomEdgeKey.self,
                                               value: geo.frame(in: .named("chatScroll")).minY)
                    }
                    .frame(height: 1)
                    .id("bottom")
                    #if os(macOS)
                    // AppKit gotcha: user scrolling moves the document view WITHOUT a SwiftUI
                    // layout pass, so the preference above goes stale mid-scroll. Watch the
                    // enclosing NSScrollView's bounds directly for that path.
                    .background(MacScrollObserver { distanceFromBottom in
                        sentinelY = viewportHeight + distanceFromBottom
                    })
                    #endif
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(BottomEdgeKey.self) { minY in
                    // Updates on LAYOUT changes (streaming growth). On macOS, user scrolling
                    // doesn't relayout — MacScrollObserver covers that path.
                    sentinelY = minY
                }
                .onAppear {
                    viewportHeight = viewport.size.height
                    // A restored conversation opens at its LATEST messages, not the top.
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: viewport.size.height) { viewportHeight = $0 }
                .onChange(of: model.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // Follow the STREAM token by token — but only while you're already at the tail.
                .onChange(of: model.messages.last?.text) { _ in
                    if nearBottom, model.isGenerating {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: model.isGenerating) { generating in
                    if generating { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                // The way back down while reading history (always available, not just streaming).
                .overlay(alignment: .bottomTrailing) {
                    if !nearBottom {
                        Button {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(p.onSurface)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .glassChrome(in: Circle())
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                        .help("Jump to the latest message")
                        .accessibilityLabel("Jump to latest")
                    }
                }
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
    private func transcriptStack<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        VStack(spacing: spacing) { content() }
        #else
        LazyVStack(spacing: spacing) { content() }
        #endif
    }

    @ViewBuilder
    private func composer(palette p: QuenderinPalette) -> some View {
        VStack(spacing: 6) {
            // Queued attachments + any rejection notice — visible BEFORE sending, removable.
            if !pendingDocuments.isEmpty || attachmentNotice != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingDocuments, id: \.name) { doc in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text").font(.caption2)
                                Text(doc.name).font(.caption)
                                Button {
                                    pendingDocuments.removeAll { $0.name == doc.name }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(doc.name)")
                            }
                            .foregroundStyle(p.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(p.surface, in: Capsule())
                        }
                        if let notice = attachmentNotice {
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            composerRow(palette: p)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        // Extraction happens HERE, at attach time — what the model will see is fixed now, and a
        // binary/oversized file is refused with a visible reason instead of mangled silently.
        .fileImporter(isPresented: $showAttachPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                switch DocumentTextExtractor.extract(name: url.lastPathComponent, url: url) {
                case .document(let doc): pendingDocuments.append(doc)
                case .rejected(let reason): attachmentNotice = reason
                }
            }
        }
    }

    @ViewBuilder
    private func composerRow(palette p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            Button {
                showAttachPicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    .glassChrome(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isGenerating)
            .help("Attach a text file to this message")
            .accessibilityLabel("Attach a file")

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

            let canSend = (!draft.trimmingCharacters(in: .whitespaces).isEmpty || !pendingDocuments.isEmpty) && !model.isGenerating
            Button {
                if model.isGenerating { model.stopGenerating() } else { send() }
            } label: {
                Image(systemName: model.isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: model.isGenerating ? 15 : 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(p.primary.opacity(canSend || model.isGenerating ? 1 : 0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !model.isGenerating)
            .help(model.isGenerating ? "Stop generating" : "Send message")
            .accessibilityLabel(model.isGenerating ? "Stop generating" : "Send message")
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let palette: QuenderinPalette
    /// The user-bubble color preset (Appearance → Message bubbles).
    var accent: (bubble: Color, text: Color, timestamp: Color)? = nil
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
            // Attached-document chips — the transcript shows WHAT was attached, not the extracted
            // text (that lives in engineText for the model).
            if !message.documents.isEmpty {
                HStack(spacing: 5) {
                    ForEach(message.documents, id: \.name) { doc in
                        Label(doc.name, systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle((accent?.timestamp ?? palette.userTimestamp))
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 2)
            }
            if mine {
                // The user's own message is shown literally (what they typed), not re-interpreted.
                // A documents-only send has no typed text — the chips ARE the message.
                if !message.text.isEmpty || message.documents.isEmpty {
                    Text(message.text.isEmpty ? "…" : message.text)
                        .foregroundStyle(accent?.text ?? palette.onUserBubble)
                        .textSelection(.enabled)
                }
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
        .background(mine ? (accent?.bubble ?? palette.userBubble) : palette.assistantBubble, in: BubbleShape(mine: mine))
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

#if os(macOS)
/// Reports how far the user is from the transcript's bottom, straight from the enclosing
/// NSScrollView — the only signal that survives AppKit's layout-free scrolling.
private struct MacScrollObserver: NSViewRepresentable {
    let onChange: (_ distanceFromBottom: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token: NSObjectProtocol?
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view, context.coordinator.token == nil,
                  let scroll = view.enclosingScrollView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            context.coordinator.token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak scroll] _ in
                guard let clip = scroll?.contentView else { return }
                onChange(clip.documentRect.height - clip.bounds.maxY)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

/// Where the transcript's bottom edge sits in the scroll viewport (drives follow-scroll).
private struct BottomEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
    var activeModel: ModelEntry? = nil

    /// True when the loaded model's quantization is graded "Low" — the honest heads-up
    /// belongs BEFORE the first disappointing answer, not buried in the profile sheet.
    private var isLowQualityModel: Bool {
        guard let activeModel else { return false }
        return Quantization.info(id: activeModel.quantization)?.quality == "Low"
    }

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
            if isLowQualityModel {
                Text("You're on the lightest model — quick, but it simplifies and sometimes rambles. "
                   + "For anything that matters, pick a bigger one in the Model library.")
                    .font(.footnote)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 2)
            }
        }
        .padding(32)
    }
}
#endif
