import Foundation
import ImageIO
import CryptoKit
import Darwin

public struct VisionInstalledModel: Sendable {
    public let modelURL: URL
    public let projectorURL: URL
}

public enum VisionWorkflowError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// A separate, exact two-component installation; never changes the answer model.
public actor VisionModelInstaller {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quenderin/vision-models", isDirectory: true)
    }
    public let directory: URL
    private let downloader: any ImageComponentDownloading
    public init(directory: URL = VisionModelInstaller.defaultDirectory, downloader: any ImageComponentDownloading = ImageComponentDownloader()) {
        self.directory = directory; self.downloader = downloader
    }
    public nonisolated static func checkResources(_ model: VisionModelDescriptor, memory: Int64, disk: Int64, remaining: Int64 = 0) throws {
        guard memory >= model.minimumMemoryBytes else { throw VisionWorkflowError.invalid("This complete vision model needs at least \(model.minimumMemoryBytes / 1_073_741_824) GiB of available app memory, including its projector and context.") }
        guard remaining >= 0, remaining <= Int64.max - 67_108_864, disk >= remaining + 67_108_864 else { throw VisionWorkflowError.invalid("Insufficient disk space for every remaining component and a 64 MiB reserve.") }
    }
    private func canonical(_ descriptor: VisionModelDescriptor) throws -> VisionModelDescriptor {
        guard let model = VisionModels.model(descriptor.id) else { throw VisionWorkflowError.invalid("Choose a pinned vision preset.") }; return model
    }
    private func target(_ model: VisionModelDescriptor) throws -> URL {
        let result = directory.appendingPathComponent(model.id, isDirectory: true)
        guard result.standardizedFileURL.path == result.resolvingSymlinksInPath().standardizedFileURL.path else { throw VisionWorkflowError.invalid("The vision folder must not contain symbolic links.") }; return result
    }
    public func hasComponents(_ descriptor: VisionModelDescriptor) -> Bool {
        guard let model = try? canonical(descriptor), let folder = try? target(model) else { return false }
        return model.artifacts.allSatisfy { ModelArtifactReceipts.Identity.read(folder.appendingPathComponent($0.filename))?.size == $0.bytes }
    }
    private func verify(_ part: VisionArtifact, at url: URL) throws {
        try Task.checkCancellation()
        guard let before = ModelArtifactReceipts.Identity.read(url), before.size == part.bytes else { throw VisionWorkflowError.invalid("Missing or incomplete \(part.filename). Existing files are preserved.") }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let magic = try input.read(upToCount: 4) ?? Data()
        guard magic == Data([71, 71, 85, 70]) else { throw VisionWorkflowError.invalid("The vision component is not a GGUF.") }
        var digest = SHA256(); digest.update(data: magic); var count: Int64 = 4
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation(); guard Int64(data.count) <= part.bytes - count else { throw VisionWorkflowError.invalid("A vision component changed during verification.") }
            digest.update(data: data); count += Int64(data.count)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == part.bytes, hash == part.sha256, before == ModelArtifactReceipts.Identity.read(url) else { throw VisionWorkflowError.invalid("A vision component checksum or identity changed. Existing files are preserved.") }
    }
    public func verify(_ descriptor: VisionModelDescriptor, budget: ImageResourceBudget) throws -> VisionInstalledModel {
        let model = try canonical(descriptor); try Self.checkResources(model, memory: budget.availableMemoryBytes, disk: budget.freeDiskBytes)
        let folder = try target(model)
        for part in model.artifacts { try verify(part, at: folder.appendingPathComponent(part.filename)) }
        return VisionInstalledModel(modelURL: folder.appendingPathComponent(model.artifacts.first { $0.role == "model" }!.filename), projectorURL: folder.appendingPathComponent(model.artifacts.first { $0.role == "projector" }!.filename))
    }
    public func install(_ descriptor: VisionModelDescriptor, budget: ImageResourceBudget, progress: @escaping @Sendable (Double) -> Void) async throws -> VisionInstalledModel {
        let model = try canonical(descriptor); try Self.checkResources(model, memory: budget.availableMemoryBytes, disk: budget.freeDiskBytes)
        let folder = try target(model), manager = FileManager.default
        var remaining: Int64 = 0
        for part in model.artifacts {
            let file = folder.appendingPathComponent(part.filename)
            if manager.fileExists(atPath: file.path) || (try? manager.destinationOfSymbolicLink(atPath: file.path)) != nil { try verify(part, at: file) }
            else { remaining += part.bytes }
        }
        try Self.checkResources(model, memory: budget.availableMemoryBytes, disk: budget.freeDiskBytes, remaining: remaining)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try target(model)
        let total = model.artifacts.reduce(Int64(0)) { $0 + $1.bytes }; var completed: Int64 = 0
        for part in model.artifacts {
            try Task.checkCancellation(); let final = folder.appendingPathComponent(part.filename)
            if !manager.fileExists(atPath: final.path) {
                let staging = folder.appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? manager.removeItem(at: staging) }
                let path = part.url.pathComponents
                guard part.url.scheme == "https", part.url.host == "huggingface.co", path.count == 6, path[3] == "resolve", path[5] == part.filename else { throw VisionWorkflowError.invalid("Invalid pinned vision artifact URL.") }
                let component = ImageModelComponent(role: part.role, repo: "\(path[1])/\(path[2])", revision: path[4], filename: part.filename, localFilename: part.filename, bytes: part.bytes, sha256: part.sha256, access: "public")
                let base = completed
                for try await event in downloader.download(component, to: staging) { try Task.checkCancellation(); if case .progress(let fraction) = event { progress((Double(base) + Double(part.bytes) * fraction) / Double(total)) } }
                try verify(part, at: staging); try Task.checkCancellation()
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                guard !manager.fileExists(atPath: final.path) else { throw VisionWorkflowError.invalid("Another installation created this component. Retry; existing files are preserved.") }
                try manager.moveItem(at: staging, to: final)
            }
            completed += part.bytes; progress(Double(completed) / Double(total))
        }
        return try verify(model, budget: budget)
    }
}

/// Only the user-picked still is copied. Originals and security-scoped locations stay intact.
public enum VisionSelectedImage {
    public static let maximumBytes = 8_388_608
    public static func copy(_ source: URL, into directory: URL) throws -> URL {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw VisionWorkflowError.invalid("The selected-image folder must not contain symlinks.") }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).image")
        var complete = false
        defer { if !complete { try? manager.removeItem(at: destination) } }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw VisionWorkflowError.invalid("Could not create a new private selected-image file.") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var count = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation(); guard chunk.count <= maximumBytes - count else { throw VisionWorkflowError.invalid("Choose one PNG or JPEG no larger than 8 MiB.") }
            count += chunk.count; try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        guard count > 0, let image = CGImageSourceCreateWithURL(destination as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(image) == 1,
              let type = CGImageSourceGetType(image) as String?, ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_000_000 else { throw VisionWorkflowError.invalid("Choose one PNG or JPEG up to 4,096 pixels per side and 16 million pixels. Video and animated images are unavailable.") }
        complete = true; return destination
    }
}
