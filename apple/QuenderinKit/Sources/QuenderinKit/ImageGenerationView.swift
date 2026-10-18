#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public final class ImageGenerationController: ObservableObject {
    public static let shared = ImageGenerationController()
    @Published public var selectedID = "moss-image-sft"
    @Published public var prompt = ""
    @Published public var publisherTermsAccepted = false
    @Published public private(set) var models: [ImageModel] = []
    @Published public private(set) var busy = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var status = "Choose a model to create an image locally."
    @Published public private(set) var failure: String?
    @Published public private(set) var output: URL?
    @Published public private(set) var installed = false
    public let engine: any ImageGenerationEngine
    private let installer: ImageModelInstaller
    private let directory: URL
    private let budget: @Sendable () -> ImageResourceBudget
    private var job: Task<Void, Never>?
    private var operationID: UUID?

    public init(catalog: ImageModelCatalog? = nil, engine: any ImageGenerationEngine = NativeImageGenerationEngine(),
                directory: URL = ImageModelInstaller.defaultDirectory,
                installer: ImageModelInstaller? = nil,
                budget: @escaping @Sendable () -> ImageResourceBudget = { .current() }) {
        self.engine = engine; self.directory = directory.resolvingSymlinksInPath()
        self.installer = installer ?? ImageModelInstaller(directory: directory.resolvingSymlinksInPath())
        self.budget = budget
        do {
            models = try (catalog ?? ImageModelCatalog.bundled()).models
            if !models.contains(where: { $0.id == selectedID }) { selectedID = models.first?.id ?? "" }
            refreshSelection()
        } catch { failure = error.localizedDescription }
    }

    public var selected: ImageModel? { models.first { $0.id == selectedID } }
    public func fitReason(installing: Bool) -> String? {
        // Button eligibility checks memory and output reserve. The installer hashes retained
        // components before applying the exact remaining-byte reservation on its worker.
        selected.flatMap { budget().blockReason(for: $0, installing: installing, remainingDownloadBytes: installing ? 0 : nil) }
    }
    public func refreshSelection() {
        guard !busy, let selected else { return }
        publisherTermsAccepted = false
        let folder = directory.appendingPathComponent(selected.id)
        installed = selected.components.allSatisfy { part in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(part.localFilename).path)[.size]) as? NSNumber
            return size?.int64Value == part.bytes
        }
        failure = nil
        status = installed ? "All components are present. Checksums are verified before generation." : "Download or import every component before generating."
    }

    public func install(imported: [URL] = []) {
        guard job == nil, let model = selected else { return }
        guard engine.available else { failure = "This build does not include the local image engine."; return }
        let budget = budget()
        if let reason = budget.blockReason(for: model, installing: false) { failure = reason; return }
        let accepted = publisherTermsAccepted
        let operation = UUID(); operationID = operation
        busy = true; failure = nil; progress = 0; status = imported.isEmpty ? "Downloading model components…" : "Importing and verifying model components…"
        job = Task {
            do {
                _ = try await installer.install(model, budget: budget, imported: imported, publisherTermsAccepted: accepted) { [weak self] fraction in
                    Task { @MainActor in if self?.operationID == operation { self?.progress = fraction } }
                }
                installed = true; status = "Complete model installed and verified."
            } catch is CancellationError { status = "Installation cancelled. Verified components are kept for retry." }
            catch { failure = error.localizedDescription; status = "Installation did not finish." }
            operationID = nil; busy = false; progress = nil; job = nil
        }
    }

    public func generate() {
        guard job == nil, let model = selected, installed else { return }
        let budget = budget()
        if let reason = budget.blockReason(for: model, installing: false) { failure = reason; return }
        if model.requiresPublisherAccess && !publisherTermsAccepted { failure = "Confirm that you have reviewed and accepted the publisher terms."; return }
        let description = prompt
        let operation = UUID(); operationID = operation
        busy = true; progress = nil; failure = nil; status = "Verifying components and loading the model…"
        job = Task {
            do {
                let outputs = directory.deletingLastPathComponent().appendingPathComponent("created-images", isDirectory: true)
                try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
                let request = ImageGenerationRequest(model: model, directory: directory.appendingPathComponent(model.id), prompt: description,
                                                     output: outputs.appendingPathComponent("Quenderin-\(UUID().uuidString).png"), seed: 0, budget: budget)
                let image = try await engine.generate(request) { [weak self] fraction in
                    Task { @MainActor in if self?.operationID == operation { self?.progress = fraction; self?.status = "Generating image…" } }
                }
                try Task.checkCancellation()
                output = image; status = "Image created locally."
            } catch is CancellationError { status = "Generation cancelled." }
            catch { failure = error.localizedDescription; status = "Generation did not finish." }
            operationID = nil; busy = false; progress = nil; job = nil
        }
    }

    public func cancel() { status = "Stopping… Model loading must return before cancellation finishes."; job?.cancel(); engine.cancel() }
    public func reportExport(_ result: Result<URL, Error>) {
        switch result { case .success: status = "Image saved."; case .failure(let error): failure = error.localizedDescription }
    }
}

@MainActor
public struct ImageGenerationView: View {
    @ObservedObject private var controller: ImageGenerationController
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: GeneratedImageDocument?
    @Environment(\.dismiss) private var dismiss
    private let showsDoneButton: Bool

    public init(controller: ImageGenerationController = .shared, showsDoneButton: Bool = false) {
        self.controller = controller; self.showsDoneButton = showsDoneButton
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Image model") {
                    Picker("Model", selection: $controller.selectedID) {
                        ForEach(controller.models) { model in Text(model.label).tag(model.id) }
                    }
                    .disabled(controller.busy)
                    if let model = controller.selected {
                        Text("\(model.downloadLabel) · \(model.components.count) required components · 512 × 512")
                            .foregroundStyle(.secondary)
                        Text("Experimental local image generation. Allow at least 24 GiB of available app memory. Full-weight inference and performance remain unverified.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !controller.engine.available { Text("This build does not include the local image engine.").foregroundStyle(.secondary) }
                        if let reason = controller.fitReason(installing: !controller.installed) { Text(reason).font(.callout) }
                        Link("Publisher terms: \(model.license)", destination: URL(string: model.licenseUrl)!)
                        if model.requiresPublisherAccess {
                            Text("Get access from the publisher, then import the original model, text encoder and VAE files. Quenderin does not download gated files for you.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Toggle("I have reviewed and accepted the publisher terms", isOn: $controller.publisherTermsAccepted)
                                .disabled(controller.busy)
                        }
                        if controller.installed {
                            Label("All components present", systemImage: "checkmark.circle")
                        } else {
                            if !model.requiresPublisherAccess {
                                Button("Download \(model.downloadLabel)") { controller.install() }
                                    .disabled(!canInstall)
                            }
                            Button("Import model components…") { importing = true }
                                .disabled(!canInstall || (model.requiresPublisherAccess && !controller.publisherTermsAccepted))
                        }
                    }
                }
                Section("Describe your image") {
                    TextEditor(text: $controller.prompt)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Image description")
                        .disabled(controller.busy)
                    if controller.selected?.modelKind == 1 {
                        Text("FLUX works from a complete scene caption. Include the subject, setting, lighting and composition. Reference-image input is not available in this screen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Generate one image") { controller.generate() }
                        .disabled(controller.busy || !controller.installed || !controller.engine.available || controller.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.fitReason(installing: false) != nil || (controller.selected?.requiresPublisherAccess == true && !controller.publisherTermsAccepted))
                    if controller.busy {
                        if let progress = controller.progress { ProgressView(value: progress) }
                        else { ProgressView() }
                        Button("Cancel", role: .cancel) { controller.cancel() }
                    }
                    Text(controller.status).font(.callout).foregroundStyle(.secondary)
                    if let failure = controller.failure { Text(failure).foregroundStyle(.red).accessibilityLabel("Error: \(failure)") }
                }
                if let output = controller.output {
                    Section("Created image") {
                        generatedImage(output).resizable().scaledToFit().frame(maxHeight: 512)
                            .accessibilityLabel("Generated image")
                        Button("Save image…") {
                            do { exportDocument = try GeneratedImageDocument(url: output); exporting = true }
                            catch { controller.reportExport(.failure(error)) }
                        }
                    }
                }
            }
            .navigationTitle("Images")
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
            }
            .onChange(of: controller.selectedID) { _ in controller.refreshSelection() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): controller.install(imported: urls); case .failure(let error): controller.reportExport(.failure(error)) }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .png, defaultFilename: "Quenderin-image") {
                controller.reportExport($0)
            }
        }
    }

    private var canInstall: Bool { !controller.busy && controller.engine.available && controller.fitReason(installing: true) == nil }
    private func generatedImage(_ url: URL) -> Image {
        #if os(macOS)
        return Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
        #else
        return Image(uiImage: UIImage(contentsOfFile: url.path) ?? UIImage())
        #endif
    }
}

public struct GeneratedImageDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.png] }
    private let data: Data
    public init(url: URL) throws { data = try Data(contentsOf: url, options: .mappedIfSafe) }
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
