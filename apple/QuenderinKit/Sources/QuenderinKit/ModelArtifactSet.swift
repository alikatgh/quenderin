import Foundation

public enum ModelArtifactError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case incomplete(String)
    case incorrectSize(String)
    case existingInvalid(String)
    case changedDuringVerification(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "Invalid model file manifest: \(reason)"
        case .incomplete(let name): return "The model is incomplete. Finish downloading \(name)."
        case .incorrectSize(let name): return "The model file \(name) has an incorrect size."
        case .existingInvalid(let name): return "Existing model file \(name) failed verification. Delete this model explicitly before retrying; its files have been preserved."
        case .changedDuringVerification(let name): return "Model file \(name) changed during verification. Try again after other file operations finish."
        }
    }
}

/// Split GGUF validation and completion checks, shared by installers, storage and inference.
public enum ModelArtifactSet {
    public static func looksLikeSplitFilename(_ filename: String) -> Bool {
        filename.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isMultipart(_ model: ModelEntry) -> Bool { !(model.artifacts ?? []).isEmpty }

    public static func validate(_ model: ModelEntry) throws -> [ModelArtifact] {
        guard let parts = model.artifacts, !parts.isEmpty else { return [] }
        guard parts.count <= 64 else { throw ModelArtifactError.invalidManifest("too many files") }
        var names = Set<String>()
        var total: Int64 = 0
        for part in parts {
            let name = part.filename
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
                  !name.contains("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  name.lowercased().hasSuffix(".gguf"), names.insert(name.lowercased()).inserted else {
                throw ModelArtifactError.invalidManifest("unsafe or duplicate filename")
            }
            guard part.downloadBytes > 0, isHex(part.sha256, length: 64),
                  let url = URL(string: part.url), url.scheme == "https", url.host == "huggingface.co",
                  url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else {
                throw ModelArtifactError.invalidManifest("each file needs a pinned HTTPS URL, size and SHA-256")
            }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 5, components[2] == "resolve", isHex(components[3], length: 40),
                  components.last == name,
                  !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }) else {
                throw ModelArtifactError.invalidManifest("download URL must pin a Hugging Face commit and filename")
            }
            let (sum, overflow) = total.addingReportingOverflow(part.downloadBytes)
            guard !overflow else { throw ModelArtifactError.invalidManifest("file sizes overflow") }
            total = sum
        }
        guard let first = parts.first, model.filename == first.filename, model.urlString == first.url,
              model.sha256 == first.sha256, model.downloadBytes == total else {
            throw ModelArtifactError.invalidManifest("first file or total size does not match the model")
        }
        return parts
    }

    public static func filenames(_ model: ModelEntry) -> [String] {
        guard isMultipart(model) else { return [model.filename] }
        return (try? validate(model).map(\.filename)) ?? []
    }

    public static func remainingDownloadBytes(_ model: ModelEntry, in directory: URL) throws -> Int64 {
        try validate(model).reduce(Int64(0)) { total, part in
            let file = directory.appendingPathComponent(part.filename)
            // Preserve existing bytes. An invalid final file needs an explicit user removal.
            if FileManager.default.fileExists(atPath: file.path) {
                do { try verify(part, at: file) }
                catch { throw ModelArtifactError.existingInvalid(part.filename) }
                return total
            }
            return total + part.downloadBytes
        }
    }

    public static func verify(_ model: ModelEntry, firstFile: URL) throws {
        let parts = try validate(model)
        guard !parts.isEmpty else { return }
        guard firstFile.lastPathComponent == model.filename else {
            throw ModelArtifactError.invalidManifest("load must start from the first file")
        }
        for part in parts { try verify(part, at: firstFile.deletingLastPathComponent().appendingPathComponent(part.filename)) }
    }

    /// Cheap metadata-only disk estimate. It never establishes completeness or trusted reuse.
    public static func estimatedRemainingDownloadBytes(_ model: ModelEntry, in directory: URL) throws -> Int64 {
        try validate(model).reduce(Int64(0)) { total, part in
            let identity = ModelArtifactReceipts.Identity.read(directory.appendingPathComponent(part.filename))
            return identity?.size == part.downloadBytes ? total : total + part.downloadBytes
        }
    }

    /// Metadata-only receipt check for synchronous UI/storage callers; missing proof fails closed.
    public static func isVerified(_ model: ModelEntry, firstFile: URL) -> Bool {
        guard firstFile.lastPathComponent == model.filename,
              let parts = try? validate(model), !parts.isEmpty else { return false }
        let directory = firstFile.deletingLastPathComponent()
        return parts.allSatisfy { part in
            let url = directory.appendingPathComponent(part.filename)
            guard let identity = ModelArtifactReceipts.Identity.read(url), identity.size == part.downloadBytes else { return false }
            return ModelArtifactReceipts.shared.contains(part, at: url, identity: identity)
        }
    }

    public static func verify(_ part: ModelArtifact, at url: URL) throws {
        try Task.checkCancellation()
        guard let before = ModelArtifactReceipts.Identity.read(url) else {
            throw ModelArtifactError.incomplete(part.filename)
        }
        guard before.size == part.downloadBytes else { throw ModelArtifactError.incorrectSize(part.filename) }
        if ModelArtifactReceipts.shared.contains(part, at: url, identity: before) { return }
        try ModelIntegrity.verify(fileURL: url, expectedSHA256: part.sha256)
        try Task.checkCancellation()
        guard let after = ModelArtifactReceipts.Identity.read(url), before == after else {
            throw ModelArtifactError.changedDuringVerification(part.filename)
        }
        ModelArtifactReceipts.shared.record(part, at: url, identity: after)
    }

    public static func inBackground<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    public static func verifyInBackground(_ model: ModelEntry, firstFile: URL) async throws {
        try await inBackground { try verify(model, firstFile: firstFile) }
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Sequential split-file installation. A completed file is retained across cancellation/retry;
/// no completion is published until every part passes size, GGUF and hash checks.
public enum ModelArtifactInstaller {
    @MainActor
    public static func install(_ model: ModelEntry, in directory: URL, downloader: ModelDownloader,
                               availableDiskBytes: (URL) -> Int64 = { DiskSpace.availableBytes(at: $0) },
                               progress: (Double) -> Void = { _ in }) async throws -> URL {
        let parts = try ModelArtifactSet.validate(model)
        guard !parts.isEmpty, let total = model.downloadBytes else {
            throw ModelArtifactError.invalidManifest("split-file installer requires a complete manifest")
        }
        let names = parts.map(\.filename)
        while !(await DownloadCoordinator.shared.claim(names)) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let remaining = try await ModelArtifactSet.inBackground {
                try ModelArtifactSet.remainingDownloadBytes(model, in: directory)
            }
            let storage = DiskSpace.check(model: model, availableBytes: availableDiskBytes(directory),
                                          remainingDownloadBytes: remaining)
            guard storage.hasRoom else { throw DownloadError.writeFailed(reason: storage.message) }
            var completed: Int64 = 0
            for part in parts {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(part.filename)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try await ModelArtifactSet.inBackground { try ModelArtifactSet.verify(part, at: destination) }
                } else {
                    guard let url = URL(string: part.url) else { throw DownloadError.invalidURL }
                    for try await event in downloader.download(from: url, to: destination, expectedSHA256: part.sha256) {
                        try Task.checkCancellation()
                        if case .progress(let fraction) = event {
                            let bounded = fraction.isFinite ? min(1, max(0, fraction)) : 0
                            progress((Double(completed) + Double(part.downloadBytes) * bounded) / Double(total))
                        }
                    }
                    try Task.checkCancellation()
                    try await ModelArtifactSet.inBackground { try ModelArtifactSet.verify(part, at: destination) }
                }
                completed += part.downloadBytes // validated overflow-safe total
                progress(Double(completed) / Double(total))
            }
            let first = directory.appendingPathComponent(model.filename)
            await DownloadCoordinator.shared.release(names)
            return first
        } catch {
            await DownloadCoordinator.shared.release(names)
            throw error
        }
    }
}
