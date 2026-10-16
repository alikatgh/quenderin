import Foundation

/// One assembled answer to "is this person safe to go off-grid?" — combining
/// disk space, download completeness, and connectivity into a single verdict
/// plus a plain-language list of what's left to do.
public struct PreflightChecklist: Sendable, Equatable {
    public let model: ModelEntry
    public let storage: StorageCheckResult
    public let readiness: OfflineReadiness
    public let networkAllowsDownload: Bool

    public var isReadyForOffline: Bool { readiness.isReadyForOffline }

    /// What still stands between the user and a safe offline trip — empty when ready.
    public var blockers: [String] {
        if isReadyForOffline { return [] }
        var items: [String] = []
        if !storage.hasRoom { items.append(storage.message) }
        switch readiness.status {
        case .ready:
            break
        case .notDownloaded:
            items.append(networkAllowsDownload
                ? "Download \(model.label) (~\(sizeGB) GB) while you have Wi-Fi."
                : "Connect to Wi-Fi, then download \(model.label).")
        case .verificationRequired:
            items.append("Verify \(model.label) before going offline.")
        case .incomplete:
            items.append(networkAllowsDownload
                ? "Finish downloading \(model.label) before you lose Wi-Fi."
                : "Reconnect to Wi-Fi to finish downloading \(model.label).")
        }
        return items
    }

    private var sizeGB: String {
        String(format: "%.1f", Double(DiskSpace.estimatedDownloadBytes(for: model)) / 1_000_000_000.0)
    }
}

public enum Preflight {
    /// Pure assembler — deterministic for tests.
    public static func checklist(
        model: ModelEntry,
        fileExists: Bool,
        fileSizeBytes: Int64,
        availableBytes: Int64,
        network: NetworkStatus,
        policy: DownloadPolicy
    ) -> PreflightChecklist {
        PreflightChecklist(
            model: model,
            storage: DiskSpace.check(model: model, availableBytes: availableBytes),
            readiness: OfflineReadinessChecker.evaluate(model: model, fileExists: fileExists, fileSizeBytes: fileSizeBytes),
            networkAllowsDownload: policy.allows(network)
        )
    }

    /// Live assembler — reads disk + a provided network status.
    public static func checklist(
        model: ModelEntry,
        modelsDir: URL,
        network: NetworkStatus,
        policy: DownloadPolicy
    ) -> PreflightChecklist {
        return PreflightChecklist(
            model: model,
            storage: DiskSpace.check(model: model, availableBytes: DiskSpace.availableBytes(at: modelsDir),
                                     remainingDownloadBytes: ModelArtifactSet.isMultipart(model) ? try? ModelArtifactSet.estimatedRemainingDownloadBytes(model, in: modelsDir) : nil),
            readiness: OfflineReadinessChecker.evaluate(model: model, in: modelsDir),
            networkAllowsDownload: policy.allows(network)
        )
    }
}
