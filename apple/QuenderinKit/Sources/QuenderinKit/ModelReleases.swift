import Foundation

/// Discovery metadata is deliberately separate from ModelEntry: recency does not prove that
/// the shipped engine can load a model, or that it is a good default on a particular device.
public struct ModelRelease: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: String
    public let quantization: String
    public let downloadBytes: Int64
    public let sha256: String
    public let revision: String
    public let filename: String
    public let license: String

    public var sourceURL: URL { URL(string: "https://huggingface.co/\(id)")! }
    public var downloadGB: Double { Double(downloadBytes) / 1_000_000_000 }

    /// Only the exact file already in the shipped catalog is eligible for its install flow.
    public func catalogEntry(in models: [ModelEntry] = ModelCatalog.models) -> ModelEntry? {
        models.first { $0.sha256?.lowercased() == sha256.lowercased() }
    }

    fileprivate var isValid: Bool {
        Self.matches(id, #"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,95}/[A-Za-z0-9_-][A-Za-z0-9._-]{0,95}$"#)
            && !name.isEmpty && name.count <= 160 && !name.contains(where: { $0.isNewline || $0.asciiValue == 0 })
            && ModelReleaseFeed.date(createdAt) != nil
            && Self.matches(quantization, #"^[A-Za-z0-9_-]{1,32}$"#)
            && (200_000_000...24_000_000_000).contains(downloadBytes)
            && Self.matches(sha256, #"^[a-fA-F0-9]{64}$"#)
            && Self.matches(revision, #"^[a-fA-F0-9]{40}$"#)
            && filename.utf8.count <= 240 && filename.lowercased().hasSuffix(".gguf")
            && !filename.contains("/") && !filename.contains("\\") && !filename.contains("..")
            && !filename.contains(where: { $0.isNewline || $0.asciiValue == 0 })
            && license.count <= 120
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct ModelReleaseFeed: Codable, Sendable, Equatable {
    public static let maxBytes = 1_048_576
    public static let refreshInterval: TimeInterval = 3600
    public let version: Int
    public let checkedAt: String
    public let partial: Bool
    public let models: [ModelRelease]
    public let freshness: String?

    public static func decode(_ data: Data) throws -> ModelReleaseFeed {
        guard data.count <= maxBytes else { throw FeedError.invalid }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.version == 1, date(decoded.checkedAt) != nil,
              !decoded.models.isEmpty, decoded.models.count <= 60 else { throw FeedError.invalid }
        var ids = Set<String>()
        let valid = decoded.models.filter { $0.isValid && ids.insert($0.id).inserted }
            .sorted { date($0.createdAt)! > date($1.createdAt)! }
        guard !valid.isEmpty else { throw FeedError.invalid }
        return Self(version: 1, checkedAt: decoded.checkedAt,
                    partial: decoded.partial || valid.count != decoded.models.count,
                    models: valid, freshness: decoded.freshness)
    }

    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public enum FeedError: Error { case invalid, unavailable }
}

public protocol ModelReleasesProviding: Sendable {
    func fetch() async throws -> ModelReleaseFeed
}

public struct LiveModelReleases: ModelReleasesProviding {
    public init() {}

    public func fetch() async throws -> ModelReleaseFeed {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // A fixed first-party URL; no chats, account, device profile or search terms are sent.
        let url = URL(string: "https://quenderin.org/api/model-releases")!
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.host == url.host,
              response.expectedContentLength <= Int64(ModelReleaseFeed.maxBytes)
        else { throw ModelReleaseFeed.FeedError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < ModelReleaseFeed.maxBytes else { throw ModelReleaseFeed.FeedError.invalid }
            data.append(byte)
        }
        return try ModelReleaseFeed.decode(data)
    }
}

public struct ModelReleaseSnapshot: Sendable, Equatable {
    public let feed: ModelReleaseFeed
    public let saved: Bool
    public let refreshFailed: Bool
}

/// One small app-private snapshot. Never touches installed weights, selection or downloads.
public actor ModelReleaseRepository {
    private let cacheURL: URL
    private let provider: any ModelReleasesProviding
    private var snapshot: ModelReleaseSnapshot
    private var lastAttempt: Date?
    private var inFlight: Task<ModelReleaseFeed, Error>?

    public init(cacheURL: URL, bundledData: Data, provider: any ModelReleasesProviding = LiveModelReleases()) throws {
        self.cacheURL = cacheURL
        self.provider = provider
        let bundled = try ModelReleaseFeed.decode(bundledData)
        let saved = (try? Data(contentsOf: cacheURL)).flatMap { try? ModelReleaseFeed.decode($0) }
        // A downgraded app, stale response or damaged cache must not replace a newer snapshot.
        let feed = saved.map { ModelReleaseFeed.date($0.checkedAt)! >= ModelReleaseFeed.date(bundled.checkedAt)! ? $0 : bundled } ?? bundled
        self.snapshot = ModelReleaseSnapshot(feed: feed, saved: true, refreshFailed: false)
    }

    public func current() -> ModelReleaseSnapshot { snapshot }

    public func refresh(force: Bool = false, now: Date = Date()) async -> ModelReleaseSnapshot {
        let task: Task<ModelReleaseFeed, Error>
        let ownsRequest: Bool
        if let inFlight {
            task = inFlight
            ownsRequest = false
        } else {
            let delay = snapshot.refreshFailed ? 60.0 : ModelReleaseFeed.refreshInterval
            if !force, let lastAttempt {
                let elapsed = now.timeIntervalSince(lastAttempt)
                if elapsed >= 0 && elapsed < delay { return snapshot }
            }
            lastAttempt = now
            task = Task { try await provider.fetch() }
            inFlight = task
            ownsRequest = true
        }
        defer { if ownsRequest { inFlight = nil } }
        do {
            // Validate injected providers too; ModelReleaseFeed's Codable initializer is public.
            let feed = try ModelReleaseFeed.decode(JSONEncoder().encode(try await task.value))
            guard ModelReleaseFeed.date(feed.checkedAt)! >= ModelReleaseFeed.date(snapshot.feed.checkedAt)! else {
                throw ModelReleaseFeed.FeedError.invalid
            }
            let updated = ModelReleaseSnapshot(feed: feed, saved: feed.freshness == "saved", refreshFailed: false)
            if snapshot == updated { return snapshot }
            snapshot = updated
            // Atomic write keeps the last good file intact on interruption / out-of-space.
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(feed) { try? data.write(to: cacheURL, options: .atomic) }
        } catch {
            snapshot = ModelReleaseSnapshot(feed: snapshot.feed, saved: true, refreshFailed: true)
        }
        return snapshot
    }
}
