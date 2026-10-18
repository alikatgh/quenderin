import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum GraniteError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public struct GraniteMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}
public enum Granite41 {
    public static let sourceRevision = "0d1625d16df2d54cafb6bc5cb0650aec043f77d6"
    public static let converterSHA256 = "301fbf51eb833e8481b4f516b28a23cd374f25db88c3e6e8af8277ecad826248"
    public static let minimumMemoryBytes: Int64 = 34_359_738_368
    public static let maximumModelBytes: Int64 = 34_359_738_368
    public static func requiredMemory(bytes: Int64) -> Int64 { max(minimumMemoryBytes, (bytes * 13 + 9) / 10 + 536_870_912) }
    public static func prompt(_ messages: [GraniteMessage]) throws -> String {
        guard !messages.isEmpty, messages.count <= 32, messages.count % 2 == 1 else { throw GraniteError.invalid("Use a bounded text conversation ending in a user question.") }
        var result = ""
        for (index, message) in messages.enumerated() {
            guard message.role == (index % 2 == 0 ? .user : .assistant), !message.content.isEmpty,
                  message.content.utf8.count <= 65_536, !message.content.contains("\0") else { throw GraniteError.invalid("Invalid Granite conversation.") }
            result += "<|start_of_role|>\(message.role.rawValue)<|end_of_role|>" + message.content.replacingOccurrences(of: "<|", with: "< |") + "<|end_of_text|>\n"
        }
        result += "<|start_of_role|>assistant<|end_of_role|>"
        guard result.utf8.count <= 32_768 else { throw GraniteError.invalid("This conversation is full. Start a new Granite conversation.") }
        return result
    }
    public static func finalAnswer(_ output: String) throws -> String {
        let answer = String(output.components(separatedBy: "<|").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.utf8.count <= 65_536,
              answer.range(of: "</?think|<tool_call", options: [.regularExpression, .caseInsensitive]) == nil else { throw GraniteError.invalid("Granite did not return a final text answer.") }
        return answer
    }
}

struct GraniteConversionRecord: Decodable, Sendable {
    struct Source: Decodable, Sendable { let repository: String; let revision: String; let weightLayers: Int }
    struct Runtime: Decodable, Sendable { let repository: String; let revision: String; let graniteConverterPatchId: String; let graniteConverterPatchSha256: String }
    let version: Int; let source: Source; let runtime: Runtime; let outtype: String; let bytes: Int64; let sha256: String
    static func parse(_ data: Data) throws -> Self {
        guard data.count >= 2, data.count <= 65_536 else { throw GraniteError.invalid("The conversion record must be at most 64 KiB.") }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.version == 1, record.source.repository == "ibm-granite/granite-switch-4.1-8b",
              record.source.revision == Granite41.sourceRevision, record.source.weightLayers == 40,
              record.runtime.repository == "https://github.com/PrismML-Eng/llama.cpp.git",
              record.runtime.revision == "e8fd209c975c80aa7fb36a8423571ff3b1b7e955",
              record.runtime.graniteConverterPatchId == "granite41-official-converter-v1",
              record.runtime.graniteConverterPatchSha256 == Granite41.converterSHA256,
              ["f16", "bf16", "q8_0"].contains(record.outtype), record.bytes >= 1024, record.bytes <= Granite41.maximumModelBytes,
              record.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw GraniteError.invalid("Choose the exact Granite Switch 4.1 8B conversion and record from scripts/convert_granite41.py.")
        }
        return record
    }
    static func read(_ url: URL) throws -> (Self, Data) {
        guard let before = ModelArtifactReceipts.Identity.read(url), before.size >= 2, before.size <= 65_536 else { throw GraniteError.invalid("Missing or excessive adjacent conversion record.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw GraniteError.invalid("Cannot read the conversion record.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 65_537), data.count == before.size,
              before == ModelArtifactReceipts.Identity.read(url) else { throw GraniteError.invalid("The conversion record changed while reading.") }
        return (try parse(data), data)
    }
}

/// A verified local conversion, never reconstructed from a model name or UI JSON object.
public struct GraniteArtifactProof: Sendable {
    public let fileURL: URL
    public let bytes: Int64
    public let sha256: String
    private let identity: ModelArtifactReceipts.Identity
    private init(_ file: URL, _ record: GraniteConversionRecord, _ identity: ModelArtifactReceipts.Identity) {
        fileURL = file; bytes = record.bytes; sha256 = record.sha256; self.identity = identity
    }
    public func assertCurrent() throws {
        guard identity == ModelArtifactReceipts.Identity.read(fileURL) else { throw GraniteError.invalid("The verified Granite file changed. Import or verify it again.") }
    }
    public static func verify(_ file: URL) throws -> Self {
        try Task.checkCancellation()
        let record = try GraniteConversionRecord.read(URL(fileURLWithPath: file.path + ".quenderin.json")).0
        guard let before = ModelArtifactReceipts.Identity.read(file), before.size == record.bytes else { throw GraniteError.invalid("The complete converted GGUF is missing.") }
        try ModelIntegrity.verify(fileURL: file, expectedSHA256: record.sha256)
        let metadata = try GGUFModelMetadata.read(from: file)
        guard metadata.architecture == "graniteswitch", metadata.splitCount == 1, metadata.blockCount == 40,
              metadata.embeddingLength == 4096, before == ModelArtifactReceipts.Identity.read(file) else {
            throw GraniteError.invalid("The converted model must be actual Granite Switch 4.1 8B: 40 layers, 4096 embedding, one complete GGUF.")
        }
        return Self(file, record, before)
    }
}

public enum GraniteModelImporter {
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quenderin/granite-imports", isDirectory: true)
    /// The selected originals remain read-only. The new private pair is published only after verification.
    public static func importPair(model: URL, receipt: URL, directory: URL = directory, progress: @Sendable (Double) -> Void = { _ in }) throws -> GraniteArtifactProof {
        guard model.pathExtension.lowercased() == "gguf", receipt.lastPathComponent == model.lastPathComponent + ".quenderin.json", model != receipt else { throw GraniteError.invalid("Choose a GGUF and its matching GGUF.quenderin.json record together.") }
        let (record, data) = try GraniteConversionRecord.read(receipt)
        guard let source = ModelArtifactReceipts.Identity.read(model), source.size == record.bytes else { throw GraniteError.invalid("The selected GGUF size differs from its record.") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw GraniteError.invalid("The private import directory must not resolve through a symlink.") }
        var finalFolder = directory.appendingPathComponent(record.sha256, isDirectory: true)
        func existing(_ finalFolder: URL) throws -> GraniteArtifactProof {
            let finalOutput = finalFolder.appendingPathComponent("granite-switch-4.1-8b.gguf")
            guard finalFolder.standardizedFileURL == finalFolder.resolvingSymlinksInPath().standardizedFileURL else { throw GraniteError.invalid("The existing private import resolves through a symlink.") }
            let proof = try GraniteArtifactProof.verify(finalOutput)
            guard proof.sha256 == record.sha256, proof.bytes == record.bytes else { throw GraniteError.invalid("The existing private import differs from the selected conversion.") }
            progress(1); return proof
        }
        let candidates = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == record.sha256 || ($0.lastPathComponent.hasPrefix(record.sha256 + "-") && UUID(uuidString: String($0.lastPathComponent.dropFirst(65))) != nil) }
        guard candidates.count <= 16 else { throw GraniteError.invalid("Too many retained attempts for this conversion. Choose an existing complete import.") }
        for candidate in candidates {
            do { return try existing(candidate) }
            catch { try Task.checkCancellation() } // Preserve incomplete old attempts; retry in a new private destination.
        }
        if manager.fileExists(atPath: finalFolder.path) { finalFolder = directory.appendingPathComponent(record.sha256 + "-" + UUID().uuidString, isDirectory: true) }
        guard DiskSpace.availableBytes(at: directory) >= record.bytes + 67_108_864 else { throw GraniteError.invalid("Insufficient private storage for the complete Granite conversion.") }
        let folder = directory.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let output = folder.appendingPathComponent("granite-switch-4.1-8b.gguf")
        defer { try? manager.removeItem(at: folder) } // Only this operation's new private staging pair.
        let inputFD = open(model.path, O_RDONLY | O_NOFOLLOW)
        guard inputFD >= 0 else { throw GraniteError.invalid("Cannot open selected GGUF.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true); defer { try? input.close() }
        let outputFD = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw GraniteError.invalid("Cannot create private GGUF copy.") }
        let target = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true); defer { try? target.close() }
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= record.bytes else { throw GraniteError.invalid("Selected GGUF grew during import.") }
            try target.write(contentsOf: chunk); progress(min(0.99, Double(count) / Double(record.bytes)))
        }
        try target.synchronize()
        guard count == record.bytes, source == ModelArtifactReceipts.Identity.read(model) else { throw GraniteError.invalid("Selected GGUF changed during import.") }
        try data.write(to: URL(fileURLWithPath: output.path + ".quenderin.json"), options: .withoutOverwriting)
        _ = try GraniteArtifactProof.verify(output)
        try Task.checkCancellation()
        // Reserve the final directory exclusively; hard links never overwrite an existing path.
        do { try manager.createDirectory(at: finalFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch {
            do { return try existing(finalFolder) }
            catch { try Task.checkCancellation() }
            finalFolder = directory.appendingPathComponent(record.sha256 + "-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: finalFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let finalOutput = finalFolder.appendingPathComponent("granite-switch-4.1-8b.gguf")
        var published = false
        defer { if !published { try? manager.removeItem(at: finalFolder) } } // This operation created this directory.
        guard link(output.path, finalOutput.path) == 0,
              link(output.path + ".quenderin.json", finalOutput.path + ".quenderin.json") == 0 else { throw GraniteError.invalid("Cannot publish the private Granite conversion exclusively.") }
        // Removing staging links changes inode ctime; seal the final identity afterward.
        try manager.removeItem(at: folder)
        let proof = try GraniteArtifactProof.verify(finalOutput)
        try Task.checkCancellation(); published = true; progress(1); return proof
    }
}
