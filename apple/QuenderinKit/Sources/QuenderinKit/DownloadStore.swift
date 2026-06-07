import Foundation

/// A persisted record of an in-flight model download — so progress survives the
/// app being suspended or killed, and can be resumed/reported on relaunch.
public struct PersistedDownload: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, paused, completed, failed }

    public let modelId: String
    public let fileName: String
    public let urlString: String
    public let destinationPath: String
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var state: State

    public init(
        modelId: String,
        fileName: String,
        urlString: String,
        destinationPath: String,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        state: State = .running
    ) {
        self.modelId = modelId
        self.fileName = fileName
        self.urlString = urlString
        self.destinationPath = destinationPath
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.state = state
    }

    public var fractionComplete: Double {
        totalBytes > 0 ? min(1.0, Double(bytesDownloaded) / Double(totalBytes)) : 0
    }
}

/// Thread-safe, file-backed table of in-flight downloads. Mirrors the proven
/// persistence pattern from off-grid-mobile's DownloadManagerModule, in pure
/// Swift — the bookkeeping that makes a download *resumable* across relaunch.
public actor DownloadStore {
    private let fileURL: URL
    private var records: [String: PersistedDownload]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PersistedDownload].self, from: data) {
            self.records = Dictionary(decoded.map { ($0.modelId, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            self.records = [:]
        }
    }

    public func upsert(_ record: PersistedDownload) {
        records[record.modelId] = record
        persist()
    }

    public func updateProgress(modelId: String, bytesDownloaded: Int64, totalBytes: Int64) {
        guard var record = records[modelId] else { return }
        record.bytesDownloaded = bytesDownloaded
        if totalBytes > 0 { record.totalBytes = totalBytes }
        records[modelId] = record
        persist()
    }

    public func setState(modelId: String, _ state: PersistedDownload.State) {
        guard var record = records[modelId] else { return }
        record.state = state
        records[modelId] = record
        persist()
    }

    public func remove(modelId: String) {
        records[modelId] = nil
        persist()
    }

    public func record(modelId: String) -> PersistedDownload? { records[modelId] }
    public func all() -> [PersistedDownload] { Array(records.values) }

    /// Downloads that were mid-flight when the app last died — the resume set.
    public func resumable() -> [PersistedDownload] {
        records.values.filter { $0.state == .running || $0.state == .paused }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(records.values)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
