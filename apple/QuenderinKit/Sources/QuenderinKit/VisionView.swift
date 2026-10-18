#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

public protocol VisionInferencePort: Sendable {
    var visionAvailable: Bool { get }
    func answer(model: VisionModelDescriptor, modelURL: URL, projectorURL: URL, imageURL: URL, prompt: String, availableMemoryBytes: Int64) async throws -> String
    func cancel()
    func close() async
}
extension NativeVisionEngine: VisionInferencePort { public var visionAvailable: Bool { Self.available } }

@MainActor public final class VisionController: ObservableObject {
    @Published public private(set) var selectedID = VisionModels.all[0].id
    @Published public var prompt = ""
    @Published public private(set) var imageURL: URL?
    @Published public private(set) var imageLabel = "No still image selected"
    @Published public private(set) var answer = ""
    @Published public private(set) var busy = false
    @Published public private(set) var installed = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var status = "Choose a vision preset and one still image."
    @Published public private(set) var failure: String?
    private let installer: VisionModelInstaller
    private let engine: any VisionInferencePort
    private let budget: @Sendable () -> ImageResourceBudget
    private let suspendForSpecialist: @Sendable () async throws -> SpecialistInferenceLease
    private let inputs: URL
    private var job: Task<Void, Never>?
    public init(installer: VisionModelInstaller = VisionModelInstaller(), engine: any VisionInferencePort = NativeVisionEngine(), budget: @escaping @Sendable () -> ImageResourceBudget = { .current() }, selectedImageDirectory: URL? = nil, suspendForSpecialist: @escaping @Sendable () async throws -> SpecialistInferenceLease = { throw VisionWorkflowError.invalid("The app has not supplied exclusive specialist engine coordination.") }) {
        self.installer = installer; self.engine = engine; self.budget = budget
        self.suspendForSpecialist = suspendForSpecialist
        inputs = (selectedImageDirectory ?? VisionModelInstaller.defaultDirectory).appendingPathComponent("selected-\(UUID().uuidString)", isDirectory: true)
    }
    deinit { job?.cancel(); engine.cancel(); let engine = engine; Task { await engine.close() }; try? FileManager.default.removeItem(at: inputs) }
    public var model: VisionModelDescriptor { VisionModels.model(selectedID)! }
    public var runtimeAvailable: Bool { engine.visionAvailable }
    public var unavailableReason: String? {
        if !engine.visionAvailable { return "This build does not include the pinned native vision runtime." }
        return Self.resourceReason(model, budget())
    }
    private static func resourceReason(_ model: VisionModelDescriptor, _ budget: ImageResourceBudget) -> String? {
        do { try VisionModelInstaller.checkResources(model, memory: budget.availableMemoryBytes, disk: budget.freeDiskBytes); return nil }
        catch { return error.localizedDescription }
    }
    public func select(_ id: String) {
        guard !busy, VisionModels.model(id) != nil else { return }; selectedID = id; installed = false; answer = ""; failure = nil
        Task { let present = await installer.hasComponents(model); if selectedID == id { installed = present } }
    }
    public func refresh() { select(selectedID) }
    public func cancel() { job?.cancel(); engine.cancel() }
    public func report(_ error: Error) { failure = String(error.localizedDescription.prefix(2048)) }
    private func run(_ message: String, timeout: UInt64, work: @escaping @MainActor () async throws -> Void) {
        guard job == nil else { return }; busy = true; failure = nil; status = message
        job = Task {
            let current = Task { try await work() }
            let timer = Task { do { try await Task.sleep(nanoseconds: timeout); current.cancel(); engine.cancel() } catch {} }
            defer { timer.cancel(); busy = false; progress = nil; job = nil }
            do { try await withTaskCancellationHandler(operation: { try await current.value }, onCancel: { current.cancel() }) }
            catch is CancellationError { status = "Cancelled. Your question, selected image and verified components are kept." }
            catch { report(error); status = "The operation did not finish. Your question and image are kept for retry." }
        }
    }
    public func chooseImage(_ source: URL) {
        run("Checking the selected still image…", timeout: 30_000_000_000) { [self] in
            let folder = inputs
            let worker = Task.detached { try VisionSelectedImage.copy(source, into: folder) }
            let chosen = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            if Task.isCancelled { try? FileManager.default.removeItem(at: chosen); throw CancellationError() }
            if let old = imageURL { try? FileManager.default.removeItem(at: old) }
            imageURL = chosen; imageLabel = String(source.lastPathComponent.prefix(200)); answer = ""; status = "Still image selected. Its original remains unchanged."
        }
    }
    public func install() {
        if let reason = unavailableReason { failure = reason; return }
        let chosen = model
        run("Installing and verifying both pinned vision components…", timeout: 7_200_000_000_000) { [self] in
            _ = try await installer.install(chosen, budget: budget()) { value in Task { @MainActor in self.progress = value } }
            try Task.checkCancellation(); installed = true; status = "Complete model and projector verified."
        }
    }
    public func ask() {
        guard runtimeAvailable else { failure = "This build does not include the pinned native vision runtime."; return }
        guard let image = imageURL, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 8192, !prompt.contains("\0") else { failure = "Choose a still image and enter a question of 1–8,192 UTF-8 bytes."; return }
        let chosen = model, question = prompt
        run("Verifying components, then loading the still-image model…", timeout: 900_000_000_000) { [self] in
            let lease = try await suspendForSpecialist()
            let result: Result<String, Error>
            do {
                try Task.checkCancellation()
                let files = try await installer.verify(chosen, budget: budget()); try Task.checkCancellation()
                let fresh = budget(); try VisionModelInstaller.checkResources(chosen, memory: fresh.availableMemoryBytes, disk: fresh.freeDiskBytes)
                result = .success(try await engine.answer(model: chosen, modelURL: files.modelURL, projectorURL: files.projectorURL, imageURL: image, prompt: question, availableMemoryBytes: fresh.availableMemoryBytes))
            } catch { result = .failure(error) }
            // answer returns only after its native worker has freed the specialist handle.
            do { try await Task.detached { try await lease.resume() }.value }
            catch { throw VisionWorkflowError.invalid("Vision stopped, but the previous text model could not be restored. Retry text-model setup. \(String(error.localizedDescription.prefix(512)))") }
            let text = try result.get(); try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 262_144, !text.contains("\0"), text.range(of: #"</?(?:think|tool_call)|<\|(?:im_start|im_end|channel)|<｜"#, options: [.regularExpression, .caseInsensitive]) == nil else { throw VisionWorkflowError.invalid("The runtime did not return a complete final answer.") }
            answer = text; status = "Final answer from the selected still-image model."
        }
    }
}

public struct VisionView: View {
    @ObservedObject private var controller: VisionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var picking = false
    public init(controller: VisionController) { self.controller = controller }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about one still image").font(.headline)
            Text("Separate from your answer model. PNG or JPEG only; video and tools are unavailable. Experimental source integration: model inference has not been validated.").font(.callout).foregroundStyle(.secondary)
            Picker("Vision model", selection: Binding(get: { controller.selectedID }, set: controller.select)) {
                ForEach(VisionModels.all, id: \.id) { Text($0.label).tag($0.id) }
            }.disabled(controller.busy)
            Text("\(controller.model.minimumMemoryBytes / 1_073_741_824) GiB available app memory required, including projector and context. Large models are never selected automatically.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Both required components · \(ByteCountFormatter.string(fromByteCount: controller.model.artifacts.reduce(0) { $0 + $1.bytes }, countStyle: .file))") {
                ForEach(controller.model.artifacts, id: \.role) { part in
                    VStack(alignment: .leading) { Text(part.filename).font(.caption); Text("\(part.bytes) bytes · SHA-256 \(part.sha256)").font(.caption2).textSelection(.enabled); Text(part.url.absoluteString).font(.caption2).textSelection(.enabled) }
                }
            }
            if let reason = controller.unavailableReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            Button(controller.installed ? "Verify complete installation" : "Install complete model and projector") { controller.install() }.disabled(controller.busy || controller.unavailableReason != nil)
            if let progress = controller.progress { ProgressView(value: progress).accessibilityLabel("Vision component installation") }
            Button("Choose PNG or JPEG…") { picking = true }.disabled(controller.busy)
            Text(controller.imageLabel).font(.caption).lineLimit(2)
            Text("Up to 8 MiB, 4,096 pixels per side and 16 million pixels. Only your chosen image is copied into private app storage.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $controller.prompt).frame(minHeight: 90).disabled(controller.busy).accessibilityLabel("Question about the selected still image")
                .onChange(of: controller.prompt) { text in if text.count > 8192 { controller.prompt = String(text.prefix(8192)) } }
            Text("\(controller.prompt.utf8.count) / 8,192 UTF-8 bytes · 512 output tokens · 4,096-token context").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Ask about image") { controller.ask() }.disabled(controller.busy || !controller.installed || controller.imageURL == nil || controller.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.prompt.utf8.count > 8192 || !controller.runtimeAvailable)
                if controller.busy { Button("Cancel") { controller.cancel() } }
            }
            Text(controller.status).font(.callout).foregroundStyle(.secondary)
            if let error = controller.failure { Text(error).font(.callout).foregroundStyle(.red) }
            if !controller.answer.isEmpty { Text(controller.answer).textSelection(.enabled).accessibilityLabel("Vision answer") }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.png, .jpeg]) { result in switch result { case .success(let url): controller.chooseImage(url); case .failure(let error): controller.report(error) } }
        .task { controller.refresh() }
        .onDisappear { controller.cancel() }
        .onChange(of: scenePhase) { phase in if phase != .active { controller.cancel() } }
    }
}
#endif
