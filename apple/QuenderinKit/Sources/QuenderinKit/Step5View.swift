#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class Step5Controller: ObservableObject {
    @Published public var endpoint = "" { didSet { if endpoint != oldValue { consent = false; connected = false } } }
    @Published public var consent = false
    @Published public var prompt = ""
    @Published public private(set) var messages: [Step5Message] = []
    @Published public private(set) var busy = false
    @Published public private(set) var connected = false
    @Published public private(set) var status = "Enter your CUDA-host gateway origin and check its pinned backend."
    @Published public private(set) var failure: String?
    @Published public private(set) var truncated = false
    private let client: Step5Client
    private var job: Task<Void, Never>?
    public init(client: Step5Client = Step5Client()) { self.client = client }
    public var validEndpoint: Bool { (try? Step5Contract.endpoint(endpoint)) != nil }
    public func cancel() { job?.cancel() }
    public func clear() { guard job == nil else { return }; messages = []; failure = nil; truncated = false; status = "Conversation cleared. Your host and unsent prompt are kept in memory." }
    private func run(_ text: String, work: @escaping @MainActor () async throws -> Void) {
        guard job == nil else { return }; busy = true; failure = nil; status = text
        job = Task {
            defer { busy = false; job = nil }
            do { try await work() }
            catch is CancellationError { status = "Request cancelled. Your prompt and conversation are kept." }
            catch { failure = String(error.localizedDescription.prefix(2048)); status = "Request did not finish. Your prompt and conversation are kept." }
        }
    }
    public func check() {
        let host = endpoint
        run("Checking the pinned Step 5 gateway…") { [self] in try await client.check(host); try Task.checkCancellation(); connected = true; status = "Pinned CUDA backend and complete verified artifacts are ready." }
    }
    public func send() {
        guard consent else { failure = "Confirm that this conversation may be sent to the selected CUDA host."; return }
        guard messages.count + 2 <= 16 else { failure = "This conversation reached its message limit. Clear it explicitly before asking another question."; return }
        let input = prompt, host = endpoint, request = messages + [Step5Message(role: "user", content: prompt)]
        do { try Step5Contract.messages(request) } catch { failure = error.localizedDescription; return }
        run("Waiting for the Step 5 CUDA host…") { [self] in
            let answer = try await client.answer(host, messages: request); try Task.checkCancellation()
            messages = request + [Step5Message(role: "assistant", content: answer.text)]
            if prompt == input { prompt = "" }; connected = true; truncated = answer.truncated
            status = answer.truncated ? "Answer reached the host's 1,024-token limit. Nothing was retried automatically." : "Final answer received from your CUDA host."
        }
    }
}

public struct Step5View: View {
    @ObservedObject private var controller: Step5Controller
    @State private var confirmClear = false
    public init(controller: Step5Controller) { self.controller = controller }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step 5 CUDA host").font(.headline)
            Text("Step 5 runs on its official CUDA backend on your chosen host, not the phone's local engine. Prompts and this conversation are sent to that host only after you confirm below.").font(.callout).foregroundStyle(.secondary)
            Text("On your host, scripts/run_step5_backend.py starts the pinned backend with already-installed complete FP8 weights and source. It does not download or provision them. Use an SSH tunnel to literal loopback, or an independently secured HTTPS proxy. Credentials are unavailable here; the endpoint stays in memory only.").font(.caption).foregroundStyle(.secondary)
            TextField("Gateway origin", text: $controller.endpoint)
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .disabled(controller.busy).accessibilityLabel("Step 5 gateway origin")
            Text("HTTPS origin or http://127.0.0.1:18000. No paths, credentials, query or fragment.").font(.caption).foregroundStyle(.secondary)
            Button("Check pinned backend") { controller.check() }.disabled(controller.busy || !controller.validEndpoint)
            Toggle("I allow this conversation to be sent to the selected CUDA host", isOn: $controller.consent).disabled(controller.busy)
            ForEach(Array(controller.messages.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 4) { Text(message.role == "user" ? "You" : "Step 5").font(.caption).bold(); Text(message.content).textSelection(.enabled) }
            }
            Text("Prompt").font(.subheadline)
            TextEditor(text: $controller.prompt).frame(minHeight: 100).accessibilityLabel("Step 5 prompt").disabled(controller.busy)
                .onChange(of: controller.prompt) { value in if value.count > 8192 { controller.prompt = String(value.prefix(8192)) } }
            Text("\(controller.prompt.utf8.count) / 8,192 UTF-8 bytes · \(controller.messages.count) stored messages · 32 KiB request limit. History is never silently pruned.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Send to CUDA host") { controller.send() }.disabled(controller.busy || !controller.validEndpoint || !controller.consent || controller.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.prompt.utf8.count > 8192)
                if controller.busy { Button("Cancel") { controller.cancel() } }
                Button("Clear conversation…") { confirmClear = true }.disabled(controller.busy || controller.messages.isEmpty)
            }
            Text(controller.status).font(.callout).foregroundStyle(.secondary)
            if let failure = controller.failure { Text(failure).font(.callout).foregroundStyle(.red) }
        }.onDisappear { controller.cancel() }
        .confirmationDialog("Clear this Step 5 conversation?", isPresented: $confirmClear) { Button("Clear conversation", role: .destructive) { controller.clear() }; Button("Cancel", role: .cancel) {} }
    }
}
#endif
