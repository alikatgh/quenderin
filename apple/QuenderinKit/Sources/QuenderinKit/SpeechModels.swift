import Foundation
import CryptoKit

public struct SpeechVadModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let repo: String
    public let revision: String
    public let filename: String
    public let localFilename: String
    public let bytes: Int64
    public let sha256: String
    public let architecture: String
    public let variant: String
    public let license: String
    public let access: String

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(filename)?download=true")!
    }

    public func validate() throws {
        let safeName = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$"#
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(id, safeName), !id.contains(".."),
              matches(localFilename, safeName), !localFilename.contains(".."),
              localFilename.hasSuffix(".gguf"),
              matches(repo, #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#),
              matches(revision, #"^[a-f0-9]{40}$"#),
              matches(sha256, #"^[a-f0-9]{64}$"#),
              bytes > 0, bytes < 10_000_000_000 else {
            throw SpeechEngineError.invalid("The VAD model manifest is invalid.")
        }
    }
}

public struct SpeechModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let engine: String
    public let architecture: String
    public let variant: String
    public let repo: String?
    public let revision: String?
    public let filename: String?
    public let localFilename: String?
    public let bytes: Int64?
    public let sha256: String?
    public let languages: [String]
    public let acceptsLanguageHint: Bool
    public let supportsLanguageDetection: Bool
    public let streams: Bool
    public let vocabularyUse: String
    public let realtime: String?
    public let wordErrorRate: Double?
    public let license: String
    public let access: String

    public var isOnDeviceFramework: Bool { engine == "apple_speech" }

    public var downloadURL: URL? {
        guard !isOnDeviceFramework, let repo, let revision, let filename else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(filename)?download=true")
    }

    public func validate() throws {
        let safeName = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$"#
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(id, safeName), !id.contains(".."), !languages.isEmpty else {
            throw SpeechEngineError.invalid("The speech model identity is invalid.")
        }
        if engine == "transcribe.cpp" {
            guard let localFilename, let revision, let sha256, let bytes, let repo,
                  matches(localFilename, safeName), !localFilename.contains(".."),
                  localFilename.hasSuffix(".gguf") || localFilename.hasSuffix(".bin"),
                  matches(repo, #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#),
                  matches(revision, #"^[a-f0-9]{40}$"#),
                  matches(sha256, #"^[a-f0-9]{64}$"#),
                  bytes > 0, bytes < 50_000_000_000 else {
                throw SpeechEngineError.invalid("The speech model artifact metadata is invalid for \(id).")
            }
        } else if engine != "apple_speech" {
            throw SpeechEngineError.invalid("Unsupported speech engine \(engine).")
        }
    }
}

public struct SpeechModelCatalog: Codable, Sendable {
    public let version: Int
    public let status: String
    public let vad: SpeechVadModel
    public let models: [SpeechModel]

    public static func decode(_ data: Data) throws -> SpeechModelCatalog {
        guard data.count <= 1_048_576 else {
            throw SpeechEngineError.invalid("Speech catalog is too large.")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.version == 1, !catalog.models.isEmpty,
              Set(catalog.models.map(\.id)).count == catalog.models.count else {
            throw SpeechEngineError.invalid("Speech catalog is invalid.")
        }
        try catalog.vad.validate()
        try catalog.models.forEach { try $0.validate() }
        return catalog
    }

    public static func bundled() throws -> SpeechModelCatalog {
        guard let url = Bundle.module.url(forResource: "speech-model-catalog", withExtension: "json") else {
            throw SpeechEngineError.invalid("This build has no speech model catalog.")
        }
        return try decode(Data(contentsOf: url))
    }
}

public enum SpeechEngineError: LocalizedError, Sendable {
    case invalid(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .cancelled: return "Speech transcription was cancelled."
        }
    }
}

public enum SpeechModelInstaller {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quenderin/speech-models", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    public static func verify(
        _ model: SpeechModel,
        in directory: URL,
        vad: SpeechVadModel? = nil,
        cancelled: () -> Bool = { false }
    ) throws {
        try model.validate()
        guard !model.isOnDeviceFramework,
              let localFilename = model.localFilename,
              let expectedBytes = model.bytes,
              let expectedSha256 = model.sha256 else {
            throw SpeechEngineError.invalid("Speech model \(model.id) uses Apple Speech and does not verify a local GGUF file.")
        }
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw SpeechEngineError.invalid("The speech model folder must not contain symbolic links.")
        }
        try verifyFile(
            at: directory.appendingPathComponent(localFilename),
            expectedBytes: expectedBytes,
            expectedSha256: expectedSha256,
            label: localFilename,
            cancelled: cancelled
        )
        if let vad {
            try vad.validate()
            try verifyFile(
                at: directory.appendingPathComponent(vad.localFilename),
                expectedBytes: vad.bytes,
                expectedSha256: vad.sha256,
                label: vad.localFilename,
                cancelled: cancelled
            )
        }
    }

    public static func verifyFile(
        at url: URL,
        expectedBytes: Int64,
        expectedSha256: String,
        label: String,
        cancelled: () -> Bool = { false }
    ) throws {
        let identity = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard identity.isRegularFile == true, identity.isSymbolicLink != true,
              Int64(identity.fileSize ?? -1) == expectedBytes else {
            throw SpeechEngineError.invalid("Missing or incomplete speech file \(label). Existing files were preserved.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard digest == expectedSha256,
              after.fileSize == identity.fileSize,
              after.contentModificationDate == identity.contentModificationDate else {
            throw SpeechEngineError.invalid("Checksum verification failed for \(label). Existing files were preserved.")
        }
    }
}
