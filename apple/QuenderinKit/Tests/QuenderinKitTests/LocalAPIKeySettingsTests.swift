#if os(macOS)
import XCTest
@testable import QuenderinKit

@MainActor
final class InMemoryLocalAPIKeyStore: LocalAPIKeyStore {
    private enum StorageError: Error { case unavailable }

    private var key: String?
    var failLoads = false
    var failSaves = false
    var discardSaves = false

    func load() throws -> String? {
        if failLoads { throw StorageError.unavailable }
        return key
    }

    func save(_ key: String) throws {
        if failSaves { throw StorageError.unavailable }
        if !discardSaves { self.key = key }
    }

    func remove() throws {
        key = nil
    }
}

final class LocalAPIKeySettingsTests: XCTestCase {
    private let legacyPreference = "quenderin.settings.localAPIKey"
    private let port: UInt16 = 11435

    @MainActor
    func testMigrationRemovesPreferenceAfterSuccessfulReadBack() async throws {
        let defaults = try makeDefaults()
        defaults.set("legacy-fixture", forKey: legacyPreference)
        let store = InMemoryLocalAPIKeyStore()

        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(settings.localAPIKey, "legacy-fixture")
        XCTAssertEqual(try store.load(), "legacy-fixture")
        XCTAssertNil(defaults.object(forKey: legacyPreference))

        store.failSaves = true
        let reopened = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertNil(reopened.validateLocalAPIHeaders(request(key: "legacy-fixture"), port: port))
    }

    @MainActor
    func testFailedMigrationRetainsPreferenceAndEnforcesLegacyKey() async throws {
        let defaults = try makeDefaults()
        defaults.set("legacy-fixture", forKey: legacyPreference)
        let store = InMemoryLocalAPIKeyStore()
        store.failSaves = true

        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(defaults.string(forKey: legacyPreference), "legacy-fixture")
        XCTAssertNil(try store.load())
        XCTAssertNil(settings.validateLocalAPIHeaders(request(key: "legacy-fixture"), port: port))
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(), port: port)?.statusCode, 401)
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(key: "wrong-fixture"), port: port)?.statusCode, 401)

        store.failSaves = false
        let reopened = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(reopened.localAPIKey, "legacy-fixture")
        XCTAssertEqual(try store.load(), "legacy-fixture")
        XCTAssertNil(defaults.object(forKey: legacyPreference))
    }

    @MainActor
    func testMigrationKeepsPreferenceWhenReadBackDoesNotMatch() async throws {
        let defaults = try makeDefaults()
        defaults.set("legacy-fixture", forKey: legacyPreference)
        let store = InMemoryLocalAPIKeyStore()
        try store.save("different-fixture")
        store.discardSaves = true

        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(defaults.string(forKey: legacyPreference), "legacy-fixture")
        XCTAssertNil(settings.validateLocalAPIHeaders(request(key: "legacy-fixture"), port: port))
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(key: "different-fixture"), port: port)?.statusCode, 401)
    }

    @MainActor
    func testClearingFailedMigrationRemovesLegacyPreference() async throws {
        let defaults = try makeDefaults()
        defaults.set("legacy-fixture", forKey: legacyPreference)
        let store = InMemoryLocalAPIKeyStore()
        store.failSaves = true
        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)

        settings.localAPIKey = ""
        XCTAssertNil(defaults.object(forKey: legacyPreference))
        XCTAssertNil(try store.load())
        let reopened = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertNil(reopened.validateLocalAPIHeaders(request(), port: port))
    }

    @MainActor
    func testSetAndClearRoundTripThroughStoreAndUpdateGuard() async throws {
        let defaults = try makeDefaults()
        let store = InMemoryLocalAPIKeyStore()
        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertNil(settings.validateLocalAPIHeaders(request(), port: port))

        settings.localAPIKey = "set-fixture"
        XCTAssertEqual(try store.load(), "set-fixture")
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(), port: port)?.statusCode, 401)
        XCTAssertNil(settings.validateLocalAPIHeaders(request(key: "set-fixture"), port: port))
        XCTAssertNil(defaults.object(forKey: legacyPreference))
        let reopened = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(reopened.localAPIKey, "set-fixture")

        reopened.localAPIKey = ""
        XCTAssertNil(try store.load())
        XCTAssertNil(reopened.validateLocalAPIHeaders(request(), port: port))
        XCTAssertNil(defaults.object(forKey: legacyPreference))
        let cleared = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(cleared.localAPIKey, "")
        XCTAssertNil(cleared.validateLocalAPIHeaders(request(), port: port))
    }

    @MainActor
    func testUnreadableStoreWithoutLegacyKeyDoesNotDisableAuthentication() async throws {
        let defaults = try makeDefaults()
        let store = InMemoryLocalAPIKeyStore()
        store.failLoads = true
        let settings = AppSettings(defaults: defaults, localAPIKeyStore: store)
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(), port: port)?.code, "api_key_unavailable")

        settings.localAPIKey = "replacement-fixture"
        XCTAssertNil(settings.validateLocalAPIHeaders(request(key: "replacement-fixture"), port: port))
        XCTAssertEqual(settings.validateLocalAPIHeaders(request(), port: port)?.statusCode, 401)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "LocalAPIKeySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func request(key: String? = nil) -> LocalHTTPRequest {
        var headers = ["Host": "localhost:\(port)"]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        return LocalHTTPRequest(method: "GET", path: "/v1/models", headers: headers)
    }
}
#endif
