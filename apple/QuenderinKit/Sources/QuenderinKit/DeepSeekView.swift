#if canImport(SwiftUI)
import SwiftUI

/// A separately bound cloud conversation, never a mode on an existing local transcript.
public struct DeepSeekView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller: DeepSeekController
    private let showsDoneButton: Bool
    @State private var draft = ""
    @State private var consent = false
    @State private var showConnection = false
    public init(controller: DeepSeekController = .shared, showsDoneButton: Bool = false) {
        self.controller = controller; self.showsDoneButton = showsDoneButton
    }
    public var body: some View {
        NavigationStack {
            Group {
                if controller.isConnected { chat }
                else { DeepSeekConnectionForm(controller: controller) }
            }
            .navigationTitle("DeepSeek")
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                if controller.isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showConnection = true } label: { Label("Connection", systemImage: "key") }
                            .disabled(controller.isBusy)
                    }
                }
            }
            .sheet(isPresented: $showConnection) {
                NavigationStack {
                    DeepSeekConnectionForm(controller: controller)
                        .navigationTitle("DeepSeek connection")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnection = false } } }
                }
                .frame(minWidth: 320, minHeight: 420)
            }
        }
        .onChange(of: controller.journal.selectedChatID) { _ in consent = false; draft = "" }
        .onDisappear { if controller.isBusy { controller.stop() } }
    }
    private var chat: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Conversation", selection: Binding(get: { controller.journal.selectedChatID ?? "" }, set: { controller.selectChat($0) })) {
                        ForEach(controller.journal.chats) { saved in Text(saved.title).tag(saved.id) }
                    }
                    .disabled(controller.isBusy)
                    Button { controller.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                        .disabled(controller.isBusy)
                }
                HStack {
                    Picker("Model", selection: Binding(get: { controller.model }, set: { controller.setSelection(model: $0, effort: controller.effort) })) {
                        Text("DeepSeek Flash").tag("deepseek-flash")
                        Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                    }
                    Picker("Thinking", selection: Binding(get: { controller.effort }, set: { controller.setSelection(model: controller.model, effort: $0) })) {
                        Text("Off").tag(ProviderReasoningEffort.off)
                        Text("Low").tag(ProviderReasoningEffort.low)
                        Text("High").tag(ProviderReasoningEffort.high)
                        Text("Max").tag(ProviderReasoningEffort.max)
                    }
                }
                .disabled(controller.isBusy || controller.chat?.state != .ready)
                Text("Destination: api.deepseek.com · tools disabled · text only")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if controller.chat?.displayedMessages.isEmpty != false {
                            Text("Start a separate DeepSeek conversation. No model download is needed.")
                                .foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(controller.chat?.displayedMessages ?? [], id: \.id) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == .user ? "You" : "DeepSeek").font(.headline)
                                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                                    DisclosureGroup("Thinking") { Text(reasoning).font(.callout).textSelection(.enabled) }
                                }
                                if !message.content.isEmpty { Text(message.content).textSelection(.enabled) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("deepseek-bottom")
                    }.padding()
                }
                .onChange(of: controller.chat?.partialAssistant?.content) { _ in proxy.scrollTo("deepseek-bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let usage = controller.chat?.usage {
                    Text("Usage: \(usage.inputTokens) input · \(usage.outputTokens) output tokens")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = controller.error ?? controller.chat?.failure?.failure {
                    Text(failure.localizedDescription).foregroundStyle(.red).font(.callout).accessibilityIdentifier("deepseek-error")
                }
                if let state = controller.chat?.state, state != .ready, state != .running {
                    Text(state == .outputLimit ? "The output limit was reached. This incomplete turn is saved for reading and excluded from future requests. Start a new chat to continue." : "This turn is incomplete and excluded from future requests. Start a new chat to continue.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Start a new DeepSeek chat") { controller.newChat() }.disabled(controller.isBusy)
                } else {
                    Toggle("Send this DeepSeek conversation to DeepSeek using my account balance. Local chats and tools stay on this device.", isOn: $consent)
                        .font(.caption).disabled(controller.isBusy)
                    HStack(alignment: .bottom) {
                        TextField("Message DeepSeek", text: $draft, axis: .vertical)
                            .lineLimit(1...6).textFieldStyle(.roundedBorder)
                            .disabled(controller.isBusy).accessibilityIdentifier("deepseek-message")
                        if controller.isBusy {
                            Button("Stop", role: .destructive) { controller.stop() }.accessibilityIdentifier("deepseek-stop")
                        } else {
                            Button("Send") {
                                controller.send(draft)
                                if controller.isBusy { draft = "" }
                            }
                            .disabled(!controller.canSend || !consent || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("deepseek-send")
                        }
                    }
                    Text("One request per Send · 4,096 output tokens · 120 seconds · no automatic retries. These limits do not cap your DeepSeek invoice.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding()
        }
    }
}

private struct DeepSeekConnectionForm: View {
    @ObservedObject var controller: DeepSeekController
    @State private var apiKey = ""
    @State private var model = "deepseek-flash"
    @State private var consent = false
    @State private var confirmRemove = false
    var body: some View {
        Form {
            Section {
                Text("Use DeepSeek without downloading a model")
                    .font(.headline)
                Text("Quenderin connects directly to api.deepseek.com. Connection validation sends your API key to DeepSeek’s models endpoint and makes no paid inference request. Your key is saved only in this device’s Keychain. Saved DeepSeek history stays separate from local chats.")
                    .font(.callout)
            }
            Section("\(controller.isConnected ? "Replace" : "Connect") API key") {
                SecureField("DeepSeek API key", text: $apiKey)
                    .privacySensitive().autocorrectionDisabled()
                    .accessibilityIdentifier("deepseek-api-key")
                Picker("Model to validate", selection: $model) {
                    Text("DeepSeek Flash").tag("deepseek-flash")
                    Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                }
                Toggle("Send this key to DeepSeek for validation and save it securely on this device.", isOn: $consent)
                    .accessibilityLabel("Send this key to DeepSeek for validation and save it securely on this device.")
                    .accessibilityIdentifier("deepseek-validation-consent")
                Button(controller.isBusy ? "Connecting…" : "Validate and save connection") {
                    let input = apiKey; apiKey = ""
                    Task { await controller.connect(input, selectedModel: model) }
                }
                .disabled(controller.isBusy || !consent || apiKey.isEmpty)
                .accessibilityIdentifier("deepseek-connect")
            }
            .disabled(controller.isBusy)
            if let error = controller.error { Text(error.localizedDescription).foregroundStyle(.red) }
            if let notice = controller.notice { Text(notice).foregroundStyle(.secondary) }
            Section {
                Text("Cloud inference uses your DeepSeek account balance. No tools or local files are shared. Flash supports vision at the provider, but image messages are not enabled here.")
                    .font(.caption)
                Link("DeepSeek pricing and account terms", destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!)
                Text("Supported model catalog: \(DeepSeekContract.catalogVersion)").font(.caption2).foregroundStyle(.secondary)
            }
            if controller.isConnected {
                Section {
                    Button("Remove connection", role: .destructive) { confirmRemove = true }.disabled(controller.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this device’s DeepSeek key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove connection", role: .destructive) { controller.removeConnection() }
        } message: { Text("Saved DeepSeek conversations remain on this device. Reconnect to send a new message.") }
        .onDisappear { apiKey = "" }
    }
}
#endif
