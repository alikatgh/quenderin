import Foundation

public struct HyMemoryInferenceRequest: Sendable {
    public let artifact: HyMemoryArtifactProof
    public let prompt: String
    public let maxOutputTokens = 512
    public let temperature = 0.0
    public let addBos = false
    public let stopSequences = ["<eos:6124c78e>"]
    public init(artifact: HyMemoryArtifactProof, prompt: String) { self.artifact = artifact; self.prompt = prompt }
}
public protocol HyMemoryInferencePort: Sendable {
    var unavailableReason: String? { get }
    func generate(_ request: HyMemoryInferenceRequest) async throws -> AsyncThrowingStream<String, Error>
    func cancel() async
}

public struct HyMemoryArtifactProof: Sendable {
    public let fileURL: URL
    public let manifestSha256 = HyMemory.manifestSha256
    public let sha256 = HyMemory.sha256
    public let architecture = "hy_v3"
    public let bytes = HyMemory.downloadBytes
    private let identity: ModelArtifactReceipts.Identity
    fileprivate init(_ url: URL, _ identity: ModelArtifactReceipts.Identity) { fileURL = url; self.identity = identity }
    public func assertCurrent() throws {
        guard identity.size == HyMemory.downloadBytes, ModelArtifactReceipts.Identity.read(fileURL) == identity else { throw HyMemoryError.invalid("The verified Hy-Memory file changed. Verify it again.") }
    }
}

public actor HyMemoryInstaller {
    public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quenderin/specialists/hy-memory", isDirectory: true)
    public let directory: URL
    private let downloader: any ImageComponentDownloading
    public init(directory: URL = HyMemoryInstaller.defaultDirectory, downloader: any ImageComponentDownloading = ImageComponentDownloader()) { self.directory = directory; self.downloader = downloader }
    public var fileURL: URL { directory.appendingPathComponent(HyMemory.filename) }
    public func isInstalled() -> Bool { ModelArtifactReceipts.Identity.read(fileURL)?.size == HyMemory.downloadBytes }
    private func resources(_ budget: ImageResourceBudget, installing: Bool) throws {
        guard budget.availableMemoryBytes >= HyMemory.minimumMemoryBytes else { throw HyMemoryError.invalid("Hy-Memory needs at least 32 GiB of available app memory for the complete specialist.") }
        guard budget.freeDiskBytes >= (installing ? HyMemory.downloadBytes : 0) + 67_108_864 else { throw HyMemoryError.invalid("Insufficient disk space for the complete Hy-Memory specialist and reserve.") }
    }
    public func verify(budget: ImageResourceBudget) throws -> HyMemoryArtifactProof {
        try resources(budget, installing: false)
        return try Self.verifyFile(fileURL)
    }
    private static func verifyFile(_ url: URL) throws -> HyMemoryArtifactProof {
        try Task.checkCancellation()
        guard let before = ModelArtifactReceipts.Identity.read(url), before.size == HyMemory.downloadBytes else { throw HyMemoryError.invalid("Hy-Memory requires the complete pinned 18,236,702,240-byte GGUF.") }
        try ModelIntegrity.verify(fileURL: url, expectedSHA256: HyMemory.sha256)
        let metadata = try GGUFModelMetadata.read(from: url)
        guard metadata.architecture == "hy_v3", metadata.splitCount == 1, ModelArtifactReceipts.Identity.read(url) == before else { throw HyMemoryError.invalid("The specialist must have actual hy_v3 architecture and unchanged pinned content.") }
        return HyMemoryArtifactProof(url, before)
    }
    public func install(budget: ImageResourceBudget, progress: @escaping @Sendable (Double) -> Void) async throws -> HyMemoryArtifactProof {
        if FileManager.default.fileExists(atPath: fileURL.path) { return try verify(budget: budget) }
        try resources(budget, installing: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw HyMemoryError.invalid("The specialist folder must not contain symbolic links.") }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staging) }
        let component = ImageModelComponent(role: "specialist", repo: "rapatsky/Hy-Memory-30B-A3B-GGUF", revision: "ac7974ba17f696b57c3c75229d127494b371f46f", filename: HyMemory.filename, localFilename: HyMemory.filename, bytes: HyMemory.downloadBytes, sha256: HyMemory.sha256, access: "public")
        for try await event in downloader.download(component, to: staging) { try Task.checkCancellation(); if case .progress(let value) = event { progress(value) } }
        _ = try Self.verifyFile(staging); try Task.checkCancellation()
        guard !manager.fileExists(atPath: fileURL.path) else { throw HyMemoryError.invalid("Another installation created this file. Retry verification; existing files are preserved.") }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try manager.moveItem(at: staging, to: fileURL)
        progress(1); return try Self.verifyFile(fileURL)
    }
}
