import Foundation

/// The trust signal the off-grid user is missing: *is this model actually,
/// completely downloaded — safe to walk away from Wi-Fi?*
public struct OfflineReadiness: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notDownloaded
        case incomplete(downloadedBytes: Int64, expectedBytes: Int64)
        case verificationRequired
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
        case .verificationRequired:
            return "\(model.label) files are present. Verify them before relying on offline use."
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
        // A scalar first-file size cannot establish completeness of a split GGUF.
        if ModelArtifactSet.isMultipart(model) {
            return OfflineReadiness(model: model, status: fileExists
                ? .incomplete(downloadedBytes: max(0, fileSizeBytes), expectedBytes: model.downloadBytes ?? 0)
                : .notDownloaded)
        }
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
        if ModelArtifactSet.isMultipart(model) {
            let first = modelsDir.appendingPathComponent(model.filename)
            if ModelArtifactSet.isVerified(model, firstFile: first) {
                return OfflineReadiness(model: model, status: .ready)
            }
            let bytes = ModelArtifactSet.filenames(model).reduce(Int64(0)) { sum, name in
                let size = ((try? FileManager.default.attributesOfItem(atPath: modelsDir.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value ?? 0
                let (next, overflow) = sum.addingReportingOverflow(max(0, size))
                return overflow ? Int64.max : next
            }
            let allPresent = (try? ModelArtifactSet.estimatedRemainingDownloadBytes(model, in: modelsDir)) == 0
            return OfflineReadiness(model: model, status: allPresent ? .verificationRequired : bytes == 0 ? .notDownloaded
                : .incomplete(downloadedBytes: bytes, expectedBytes: model.downloadBytes ?? 0))
        }
        let path = modelsDir.appendingPathComponent(model.filename).path
        let exists = FileManager.default.fileExists(atPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return evaluate(model: model, fileExists: exists, fileSizeBytes: size)
    }
}
