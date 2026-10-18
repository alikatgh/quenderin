import Foundation

/// Bounded metadata inspection before native model allocation. File names cannot identify an
/// architecture: a renamed metadata-only shard must still fail the Muse/split-model gate.
public struct GGUFModelMetadata: Sendable, Equatable {
    public let architecture: String
    public let splitCount: UInt64
    public let modelName: String
    public let blockCount: UInt64?
    public let embeddingLength: UInt64?

    public init(architecture: String, splitCount: UInt64, modelName: String = "", blockCount: UInt64? = nil, embeddingLength: UInt64? = nil) {
        self.architecture = architecture
        self.splitCount = splitCount
        self.modelName = modelName
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
    }

    public func validateForLoad(_ model: ModelEntry) throws {
        try validateForLoad(model, weeklyTextRuntimeAvailable: ModelRuntimeSupport.supportsWeeklyText)
    }

    func validateForLoad(_ model: ModelEntry, weeklyTextRuntimeAvailable: Bool, beamRuntimeAvailable: Bool = ModelRuntimeSupport.supportsBeam) throws {
        if let reason = ModelRuntimeSupport.unsupportedWorkflowReason(identifiers: [modelName], architecture: architecture, allowPinnedBeam: ModelRuntimeSupport.isVerifiedBeamManifest(model))
            ?? ModelRuntimeSupport.unsupportedWorkflowReason(for: model) {
            throw ModelArtifactError.invalidManifest(reason)
        }
        if (architecture.lowercased() == "k2-horizon" || ModelRuntimeSupport.isWeeklyIdentity(modelName)), !weeklyTextRuntimeAvailable {
            throw ModelArtifactError.invalidManifest(ModelRuntimeSupport.weeklyTextUnavailableMessage)
        }
        let actualBeam = architecture.lowercased() == "beam"
        if actualBeam {
            guard ModelRuntimeSupport.isVerifiedBeamManifest(model), beamRuntimeAvailable, splitCount == 4 else {
                throw ModelArtifactError.invalidManifest(ModelRuntimeSupport.beamUnavailableMessage)
            }
        } else if ModelRuntimeSupport.isBeam(model) {
            throw ModelArtifactError.invalidManifest("model architecture does not match Beam")
        }
        let actualMuse = architecture.lowercased().replacingOccurrences(of: "_", with: "-") == "muse-spark"
        if actualMuse {
            guard let pinned = ModelCatalog.entry(id: "muse-spark-open-q2-k"), model == pinned,
                  ModelArtifactSet.isMultipart(model) else {
                throw ModelArtifactError.invalidManifest("Muse architecture requires the complete pinned catalog model")
            }
        } else if ModelRuntimeSupport.isMuse(model) {
            throw ModelArtifactError.invalidManifest("model architecture does not match Muse Spark")
        }
        if splitCount > 1 || ModelArtifactSet.isMultipart(model) {
            let parts = try ModelArtifactSet.validate(model)
            guard UInt64(parts.count) == splitCount else {
                throw ModelArtifactError.invalidManifest("the GGUF requires a complete matching split-file manifest")
            }
        }
    }

    public static func read(from file: URL) throws -> GGUFModelMetadata {
        let reader = try Reader(file)
        guard try reader.bytes(4) == ModelIntegrity.ggufMagic else { throw ModelArtifactError.invalidManifest("invalid GGUF metadata") }
        let version = try reader.integer(4)
        guard version == 2 || version == 3 else { throw ModelArtifactError.invalidManifest("unsupported GGUF version") }
        _ = try reader.integer(8) // tensor count; no tensors are read or allocated
        let count = try reader.integer(8)
        guard count <= 100_000 else { throw ModelArtifactError.invalidManifest("too many GGUF metadata keys") }
        var architecture: String?
        var modelName = ""
        var hasModelName = false
        var splits: UInt64 = 1
        var blockCount: UInt64?
        var embeddingLength: UInt64?
        for _ in 0..<count {
            let key = try reader.string(maximum: 1024)
            let type = try reader.integer(4)
            if key == "general.architecture" {
                guard type == 8, architecture == nil else { throw ModelArtifactError.invalidManifest("architecture must be one string") }
                architecture = try reader.string(maximum: 256)
            } else if key == "general.name" {
                guard type == 8, !hasModelName else { throw ModelArtifactError.invalidManifest("model name must be one string") }
                hasModelName = true
                modelName = try reader.string(maximum: 4096)
            } else if key == "split.count" {
                guard [UInt64(0), 2, 4, 10].contains(type) else { throw ModelArtifactError.invalidManifest("invalid GGUF split count") }
                splits = try reader.integer(type == 0 ? 1 : type == 2 ? 2 : type == 4 ? 4 : 8)
                guard splits > 0, splits <= 64 else { throw ModelArtifactError.invalidManifest("invalid GGUF split count") }
            } else if key == "graniteswitch.block_count" || key == "graniteswitch.embedding_length" {
                guard [UInt64(0), 2, 4, 10].contains(type) else { throw ModelArtifactError.invalidManifest("invalid Granite dimensions") }
                let value = try reader.integer(type == 0 ? 1 : type == 2 ? 2 : type == 4 ? 4 : 8)
                if key.hasSuffix("block_count") {
                    guard blockCount == nil, value <= 1024 else { throw ModelArtifactError.invalidManifest("invalid Granite layer count") }; blockCount = value
                } else {
                    guard embeddingLength == nil, value <= 65536 else { throw ModelArtifactError.invalidManifest("invalid Granite embedding size") }; embeddingLength = value
                }
            } else { try reader.skipValue(type: type) }
        }
        guard let architecture, !architecture.isEmpty else { throw ModelArtifactError.invalidManifest("GGUF architecture is missing") }
        return GGUFModelMetadata(architecture: architecture, splitCount: splits, modelName: modelName, blockCount: blockCount, embeddingLength: embeddingLength)
    }

    private final class Reader {
        private let handle: FileHandle
        private let limit: UInt64
        private var offset: UInt64 = 0
        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            let size = try handle.seekToEnd()
            limit = min(size, 64 * 1024 * 1024) // bounded metadata work, never tensor data
            try handle.seek(toOffset: 0)
        }
        deinit { try? handle.close() }

        func bytes(_ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, UInt64(count) <= limit - offset,
                  let data = try handle.read(upToCount: count), data.count == count else {
                throw ModelArtifactError.invalidManifest("truncated or oversized GGUF metadata")
            }
            offset += UInt64(count)
            return data
        }
        func integer(_ count: Int) throws -> UInt64 {
            try bytes(count).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func string(maximum: UInt64) throws -> String {
            let length = try integer(8)
            guard length <= maximum, let value = String(data: try bytes(Int(length)), encoding: .utf8) else {
                throw ModelArtifactError.invalidManifest("invalid GGUF metadata string")
            }
            return value
        }
        func skip(_ count: UInt64) throws {
            try Task.checkCancellation()
            guard count <= limit - offset else { throw ModelArtifactError.invalidManifest("oversized GGUF metadata") }
            offset += count
            try handle.seek(toOffset: offset)
        }
        func skipValue(type: UInt64) throws {
            switch type {
            case 0, 1, 7: try skip(1)
            case 2, 3: try skip(2)
            case 4, 5, 6: try skip(4)
            case 10, 11, 12: try skip(8)
            case 8: try skip(integer(8))
            case 9:
                let element = try integer(4), count = try integer(8)
                guard count <= 2_000_000, element != 9 else { throw ModelArtifactError.invalidManifest("oversized or nested GGUF array") }
                let width: UInt64?
                switch element {
                case 0, 1, 7: width = 1
                case 2, 3: width = 2
                case 4, 5, 6: width = 4
                case 10, 11, 12: width = 8
                case 8: width = nil
                default: throw ModelArtifactError.invalidManifest("unknown GGUF array type")
                }
                if let width { try skip(count * width) }
                else { for _ in 0..<count { try skip(integer(8)) } }
            default: throw ModelArtifactError.invalidManifest("unknown GGUF metadata type")
            }
        }
    }
}
