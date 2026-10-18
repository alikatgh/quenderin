#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

@MainActor public final class GraniteChatController: ObservableObject {
    @Published public var prompt = ""
    @Published public private(set) var messages: [GraniteMessage] = []
    @Published public private(set) var modelURL: URL?
    @Published public private(set) var busy = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var failure: String?
    @Published public private(set) var status = "Import a converted Granite Switch 4.1 8B GGUF and its matching conversion record."
    private let engine = NativeGraniteEngine()
    private let suspendForSpecialist: @Sendable () async throws -> SpecialistInferenceLease
    private var job: Task<Void, Never>?
    private static let lastImportKey = "quenderin.granite41ImportFolder"
    public init(suspendForSpecialist: @escaping @Sendable () async throws -> SpecialistInferenceLease = { throw SpecialistCoordinationError.unavailable }) {
        self.suspendForSpecialist = suspendForSpecialist
        if let name = UserDefaults.standard.string(forKey: Self.lastImportKey), Self.validFolder(name) {
            modelURL = GraniteModelImporter.directory.appendingPathComponent(name).appendingPathComponent("granite-switch-4.1-8b.gguf")
        }
    }
    private static func validFolder(_ name: String) -> Bool {
        name.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil || UUID(uuidString: name) != nil ||
            (name.count == 101 && name.prefix(64).range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && name.dropFirst(64).first == "-" && UUID(uuidString: String(name.dropFirst(65))) != nil)
    }
    public var unavailableReason: String? {
        if !NativeGraniteEngine.available { return "This build requires the verified native Prism text runtime." }
        if HardwareProbe.appMemoryBudgetGB() < 32 { return "Granite Switch 4.1 8B needs at least 32 GiB of available app memory. Choose a smaller text model on this device." }
        return nil
    }
    public func cancel() { job?.cancel() }
    public func newConversation() { if !busy { messages = []; failure = nil } }
    private func run(_ message: String, timeout: UInt64, work: @escaping @MainActor () async throws -> Void) {
        guard job == nil else { return }; busy = true; failure = nil; status = message
        job = Task {
            let worker = Task { try await work() }
            let timer = Task { do { try await Task.sleep(nanoseconds: timeout); worker.cancel() } catch {} }
            defer { timer.cancel(); busy = false; progress = nil; job = nil }
            do { try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }) }
            catch is CancellationError { status = "Cancelled. Your question, conversation and completed import are kept." }
            catch { failure = String(error.localizedDescription.prefix(2048)); status = "The operation did not finish. Your question and conversation are kept for retry." }
        }
    }
    public func importPair(_ urls: [URL]) {
        guard unavailableReason == nil else { failure = unavailableReason; return }
        guard urls.count == 2, let model = urls.first(where: { $0.pathExtension.lowercased() == "gguf" }),
              let receipt = urls.first(where: { $0.lastPathComponent == model.lastPathComponent + ".quenderin.json" }) else {
            failure = "Select exactly one GGUF and its matching GGUF.quenderin.json conversion record."; return
        }
        run("Copying and verifying the complete local conversion…", timeout: 7_200_000_000_000) { [self] in
            let worker = Task.detached {
                let modelAccess = model.startAccessingSecurityScopedResource(), receiptAccess = receipt.startAccessingSecurityScopedResource()
                defer { if modelAccess { model.stopAccessingSecurityScopedResource() }; if receiptAccess { receipt.stopAccessingSecurityScopedResource() } }
                return try GraniteModelImporter.importPair(model: model, receipt: receipt) { value in Task { @MainActor in self.progress = value } }
            }
            let proof = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation(); modelURL = proof.fileURL; messages = []
            UserDefaults.standard.set(proof.fileURL.deletingLastPathComponent().lastPathComponent, forKey: Self.lastImportKey)
            status = "Complete local conversion and record verified. The selected originals are unchanged."
        }
    }
    public func ask() {
        if let reason = unavailableReason { failure = reason; return }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let modelURL, !question.isEmpty, question.utf8.count <= 8192, !question.contains("\0"), messages.count < 30 else { failure = "Import the model and enter a question of 1–8192 UTF-8 bytes, or start a new conversation if this one is full."; return }
        let history = messages + [.init(role: .user, content: question)]
        run("Verifying the local model, then answering…", timeout: 600_000_000_000) { [self] in
            let lease = try await suspendForSpecialist()
            let outcome: Result<String, Error>
            do {
                try Task.checkCancellation()
                let verifier = Task.detached { try GraniteArtifactProof.verify(modelURL) }
                let proof = try await withTaskCancellationHandler(operation: { try await verifier.value }, onCancel: { verifier.cancel() })
                try Task.checkCancellation(); outcome = .success(try await engine.answer(proof: proof, messages: history))
            } catch { outcome = .failure(error) }
            // Always join/unload the specialist before restoring ordinary text, including cancellation.
            try await Task.detached { await self.engine.cancel(); try await lease.resume() }.value
            let final = try outcome.get(); try Task.checkCancellation()
            messages = history + [.init(role: .assistant, content: final)]; prompt = ""; status = "Final text answer from the imported Granite conversion."
        }
    }
}

public struct GraniteChatView: View {
    @ObservedObject private var controller: GraniteChatController
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase
    public init(controller: GraniteChatController) { self.controller = controller }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Granite Switch 4.1 8B").font(.headline)
            Text("Local converted GGUF · text chat only · at least 32 GiB available memory").font(.caption).foregroundStyle(.secondary)
            Text("Choose the GGUF produced by scripts/convert_granite41.py together with its .quenderin.json record. Speech, guardian decisions and tools are unavailable.").font(.caption)
            if let reason = controller.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(controller.modelURL == nil ? "Import GGUF and record…" : "Choose another conversion…") { importing = true }
                    .disabled(controller.busy || controller.unavailableReason != nil)
                if controller.modelURL != nil { Label("Local model selected", systemImage: "checkmark.circle") }
            }
            if controller.modelURL != nil { Text("Verified imports of the same conversion are reused.").font(.caption).foregroundStyle(.secondary) }
            if let progress = controller.progress { ProgressView(value: progress) }
            ForEach(Array(controller.messages.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.role == .user ? "You" : "Granite").font(.caption.bold())
                    Text(message.content).textSelection(.enabled)
                }
            }
            TextEditor(text: $controller.prompt).frame(minHeight: 88).disabled(controller.busy)
                .accessibilityLabel("Question for Granite")
            HStack {
                Button("Ask Granite") { controller.ask() }.disabled(controller.busy || controller.modelURL == nil || controller.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.unavailableReason != nil)
                if controller.busy { Button("Cancel") { controller.cancel() } }
                Button("New conversation") { controller.newConversation() }.disabled(controller.busy || controller.messages.isEmpty)
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if let failure = controller.failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): controller.importPair(urls); case .failure: break }
        }
        .onDisappear { controller.cancel() }
        .onChange(of: scenePhase) { phase in if phase != .active { controller.cancel() } }
    }
}
#endif
