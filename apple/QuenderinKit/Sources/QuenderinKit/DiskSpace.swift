import Foundation

public struct StorageCheckResult: Sendable, Equatable {
    public let hasRoom: Bool
    public let requiredBytes: Int64
    public let availableBytes: Int64
    public let message: String
}

/// Will a model's download actually fit? A 2 GB pull that fails at 95% full —
/// the night before someone goes off-grid — is exactly the failure to prevent.
public enum DiskSpace {

    /// Principled download-size estimate: params × bits-per-weight ÷ 8.
    /// (8B Q4_K_M ≈ 4.5 GB, 1B Q2_K ≈ 0.33 GB — close to the catalog labels.)
    public static func estimatedDownloadBytes(for model: ModelEntry) -> Int64 {
        let bits = Quantization.info(id: model.quantization)?.bitsPerWeight ?? 4.5
        return Int64(model.paramsBillions * 1_000_000_000.0 * bits / 8.0)
    }

    /// Free bytes for important usage on `url`'s volume (best-effort, live).
    public static func availableBytes(at url: URL) -> Int64 {
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let capacity = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    /// Pure, deterministic check. 300 MB margin covers OS overhead + KV cache.
    public static func check(
        model: ModelEntry,
        availableBytes: Int64,
        marginBytes: Int64 = 300 * 1024 * 1024
    ) -> StorageCheckResult {
        let required = estimatedDownloadBytes(for: model) + marginBytes
        let hasRoom = availableBytes >= required
        let message = hasRoom
            ? "\(model.label): needs ~\(gb(required)) GB, \(gb(availableBytes)) GB free."
            : "Not enough space for \(model.label) — needs ~\(gb(required)) GB but only \(gb(availableBytes)) GB free. Free up space or pick a smaller model."
        return StorageCheckResult(hasRoom: hasRoom, requiredBytes: required, availableBytes: availableBytes, message: message)
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000.0)
    }
}
