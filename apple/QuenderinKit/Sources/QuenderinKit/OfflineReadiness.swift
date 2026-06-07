import Foundation

/// The trust signal the off-grid user is missing: *is this model actually,
/// completely downloaded — safe to walk away from Wi-Fi?*
public struct OfflineReadiness: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notDownloaded
        case incomplete(downloadedBytes: Int64, expectedBytes: Int64)
        case ready
    }

    public let model: ModelEntry
    public let status: Status

    public var isReadyForOffline: Bool {
        if case .ready = status { return true }
        return false
    }

    public var message: String {
        switch status {
        case .ready:
            return "✅ \(model.label) is downloaded and ready. You can go offline."
        case .notDownloaded:
            return "\(model.label) isn't downloaded yet. Download it while you have Wi-Fi."
        case let .incomplete(downloaded, expected):
            let pct = expected > 0 ? Int(Double(downloaded) / Double(expected) * 100) : 0
            return "\(model.label) is only \(pct)% downloaded — finish before you lose Wi-Fi."
        }
    }
}

public enum OfflineReadinessChecker {
    /// Pure check from a known file size — deterministic for tests. A model is
    /// "ready" when its file is ≥85% of the estimate (a complete GGUF comfortably
    /// exceeds it; a truncated partial won't).
    public static func evaluate(model: ModelEntry, fileExists: Bool, fileSizeBytes: Int64) -> OfflineReadiness {
        guard fileExists, fileSizeBytes > 0 else {
            return OfflineReadiness(model: model, status: .notDownloaded)
        }
        let expected = DiskSpace.estimatedDownloadBytes(for: model)
        if Double(fileSizeBytes) >= Double(expected) * 0.85 {
            return OfflineReadiness(model: model, status: .ready)
        }
        return OfflineReadiness(model: model, status: .incomplete(downloadedBytes: fileSizeBytes, expectedBytes: expected))
    }

    /// Live check against the file system.
    public static func evaluate(model: ModelEntry, in modelsDir: URL) -> OfflineReadiness {
        let path = modelsDir.appendingPathComponent(model.filename).path
        let exists = FileManager.default.fileExists(atPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return evaluate(model: model, fileExists: exists, fileSizeBytes: size)
    }
}
