import Foundation
import XCTest
@testable import QuenderinKit

private actor ReleaseFixtureProvider: ModelReleasesProviding {
    var calls = 0
    var result: ModelReleaseFeed?
    init(_ result: ModelReleaseFeed?) { self.result = result }
    func fetch() async throws -> ModelReleaseFeed {
        calls += 1
        // Yield so the concurrent-refresh test exercises the actor's in-flight path.
        await Task.yield()
        guard let result else { throw ModelReleaseFeed.FeedError.unavailable }
        return result
    }
}

final class ModelReleasesTests: XCTestCase, @unchecked Sendable {
    private func seed() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "model-releases", withExtension: "json")))
    }

    private func changed(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func cacheURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quenderin-release-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("snapshot.json")
    }

    func testBundledFeedIsCurrentMetadataWithBoundedFiles() throws {
        let feed = try ModelReleaseFeed.decode(seed())
        XCTAssertEqual(feed.version, 1)
        XCTAssertFalse(feed.models.isEmpty)
        XCTAssertTrue(feed.models.allSatisfy { $0.sourceURL.host == "huggingface.co" && $0.downloadGB <= 24 })
        XCTAssertEqual(feed.models.map(\.id).count, Set(feed.models.map(\.id)).count)
    }

    func testInvalidRowsAndDuplicatesCannotBecomeLinks() throws {
        let data = try changed(seed()) { json in
            var rows = json["models"] as! [[String: Any]]
            let good = rows[0]
            rows[0]["id"] = "evil.test/@user?redirect=1"
            rows[1]["sha256"] = "not-a-checksum"
            rows.append(good)
            rows.append(good)
            json["models"] = rows
        }
        let feed = try ModelReleaseFeed.decode(data)
        XCTAssertTrue(feed.partial)
        XCTAssertFalse(feed.models.contains { $0.id.contains("?") || $0.sha256 == "not-a-checksum" })
        XCTAssertEqual(feed.models.map(\.id).count, Set(feed.models.map(\.id)).count)
    }

    func testSchemaEmptyOversizedAndTraversalPayloadsAreRejected() throws {
        XCTAssertThrowsError(try ModelReleaseFeed.decode(Data(repeating: 32, count: ModelReleaseFeed.maxBytes + 1)))
        for key in ["version", "checkedAt", "models"] {
            let data = try changed(seed()) { json in
                switch key {
                case "version": json[key] = 2
                case "checkedAt": json[key] = "yesterday"
                default: json[key] = []
                }
            }
            XCTAssertThrowsError(try ModelReleaseFeed.decode(data))
        }
        let bad = try changed(seed()) { json in
            var rows = json["models"] as! [[String: Any]]
            for index in rows.indices { rows[index]["filename"] = "../weights.gguf" }
            json["models"] = rows
        }
        XCTAssertThrowsError(try ModelReleaseFeed.decode(bad))
    }

    func testOnlyExactCatalogChecksumsEnableInstallActions() throws {
        var feed = try JSONSerialization.jsonObject(with: seed()) as! [String: Any]
        var rows = feed["models"] as! [[String: Any]]
        let known = ModelCatalog.models[0]
        rows[0]["sha256"] = known.sha256!.uppercased()
        feed["models"] = rows
        let decoded = try ModelReleaseFeed.decode(JSONSerialization.data(withJSONObject: feed))
        XCTAssertEqual(decoded.models.first { $0.id == rows[0]["id"] as? String }?.catalogEntry()?.id, known.id)
        XCTAssertNil(decoded.models.first { $0.id == rows[1]["id"] as? String }?.catalogEntry())
    }

    func testOfflineRefreshKeepsTheLastGoodFileAndTimestamp() async throws {
        let data = try seed()
        let cache = try cacheURL()
        try data.write(to: cache)
        let repository = try ModelReleaseRepository(cacheURL: cache, bundledData: data, provider: ReleaseFixtureProvider(nil))
        let before = await repository.current()
        let after = await repository.refresh()
        XCTAssertEqual(after.feed, before.feed)
        XCTAssertTrue(after.saved)
        XCTAssertTrue(after.refreshFailed)
        XCTAssertEqual(try Data(contentsOf: cache), data)
    }

    func testRefreshIsSavedForOfflineRelaunchAndThrottled() async throws {
        let data = try seed()
        let liveData = try changed(data) { $0["checkedAt"] = "2026-09-30T13:00:00Z" }
        let live = try ModelReleaseFeed.decode(liveData)
        let provider = ReleaseFixtureProvider(live)
        let cache = try cacheURL()
        let repository = try ModelReleaseRepository(cacheURL: cache, bundledData: data, provider: provider)
        let now = Date()
        let first = await repository.refresh(now: now)
        _ = await repository.refresh(now: now.addingTimeInterval(30))
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(first.saved)
        let offline = try ModelReleaseRepository(cacheURL: cache, bundledData: data, provider: ReleaseFixtureProvider(nil))
        let saved = await offline.current()
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(saved.feed.checkedAt, live.checkedAt)
    }

    func testOlderServerResponseCannotRollBackTheCache() async throws {
        let data = try seed()
        let old = try ModelReleaseFeed.decode(changed(data) { $0["checkedAt"] = "2026-01-01T00:00:00Z" })
        let cache = try cacheURL()
        try data.write(to: cache)
        let repository = try ModelReleaseRepository(cacheURL: cache, bundledData: data, provider: ReleaseFixtureProvider(old))
        let result = await repository.refresh()
        XCTAssertTrue(result.refreshFailed)
        XCTAssertEqual(try Data(contentsOf: cache), data)
    }

    func testConcurrentRefreshesShareOneRequestAndReturnFreshResults() async throws {
        let data = try seed()
        let provider = ReleaseFixtureProvider(try ModelReleaseFeed.decode(data))
        let repository = try ModelReleaseRepository(cacheURL: cacheURL(), bundledData: data, provider: provider)
        async let a = repository.refresh()
        async let b = repository.refresh()
        let results = await [a, b]
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(results.allSatisfy { !$0.saved && !$0.refreshFailed })
    }
}
