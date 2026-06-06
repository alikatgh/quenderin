import Foundation

/// A versioned, language-neutral description of the available model modules.
///
/// This is the shape meant to become the **one source of truth** across
/// platforms: the desktop (TS) emits it, and iOS (Swift) / Android (Kotlin)
/// decode it — instead of three hand-synced catalogs. For now `current` mirrors
/// the embedded `ModelCatalog`; later it can be loaded from a bundled/remote JSON.
public struct ModelManifest: Codable, Sendable, Equatable {
    public let version: Int
    public let models: [ModelEntry]

    public init(version: Int = 1, models: [ModelEntry]) {
        self.version = version
        self.models = models
    }

    /// The manifest backed by the embedded catalog.
    public static let current = ModelManifest(version: 1, models: ModelCatalog.models)

    /// Encode to stable, pretty JSON (sorted keys → diff-friendly, cross-platform).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: data)
    }
}
