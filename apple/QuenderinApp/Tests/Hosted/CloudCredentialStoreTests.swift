import Foundation
import Security
import XCTest
import QuenderinKit

/// Real Keychain operations on synthetic, UUID-scoped items. The target's TEST_HOST
/// is Quenderin.app, so these assertions must run in the app's sandbox, not XCTRunner.
final class CloudCredentialStoreTests: XCTestCase {
    private enum FixtureFailure: Error { case wrongHost, existingItem, missingData }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertEqual(Bundle.main.bundleIdentifier, "ai.quenderin.Quenderin")
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
        guard Bundle.main.bundleIdentifier == "ai.quenderin.Quenderin",
              Bundle.main.bundleURL.pathExtension == "app" else {
            throw FixtureFailure.wrongHost
        }
    }

    func testDeepSeekSaveLoadUpdateReloadAndDeleteInAppSandbox() throws {
        let reference = "qcred:" + UUID().uuidString
        let reloadedReference = "qcred:" + UUID().uuidString
        let item = identity(service: "org.quenderin.deepseek", account: reference)
        let reloadedItem = identity(service: "org.quenderin.deepseek", account: reloadedReference)
        try requireAbsent(item)
        try requireAbsent(reloadedItem)

        let initial = "quenderin-cloud-synthetic-" + UUID().uuidString
        let updated = "quenderin-cloud-updated-" + UUID().uuidString
        let store = DeepSeekKeychainStore()
        try store.save(DeepSeekAPIKey(initial), reference: reference)
        registerCleanup(item)
        XCTAssertEqual(try readSyntheticData(item), Data(initial.utf8))

        // The value type intentionally hides its text. Re-saving the public load
        // result into a second owned item proves the production load's contents.
        let recreatedStore = DeepSeekKeychainStore()
        let loaded = try recreatedStore.load(reference: reference)
        try recreatedStore.save(loaded, reference: reloadedReference)
        registerCleanup(reloadedItem)
        XCTAssertEqual(try readSyntheticData(reloadedItem), Data(initial.utf8))

        try store.save(DeepSeekAPIKey(updated), reference: reference)
        let reloaded = try DeepSeekKeychainStore().load(reference: reference)
        try recreatedStore.save(reloaded, reference: reloadedReference)
        XCTAssertEqual(try readSyntheticData(item), Data(updated.utf8))
        XCTAssertEqual(try readSyntheticData(reloadedItem), Data(updated.utf8))

        try store.remove(reference: reference)
        try requireAbsent(item)
        XCTAssertThrowsError(try recreatedStore.load(reference: reference)) { error in
            XCTAssertEqual(error as? DeepSeekFailure, .credentialStorage)
        }
        try recreatedStore.remove(reference: reloadedReference)
        try requireAbsent(reloadedItem)
        // Removing an already-absent owned reference remains idempotent.
        XCTAssertNoThrow(try store.remove(reference: reference))
    }

    func testDeepSeekLoadsAndUpdatesPreexistingItem() throws {
        let reference = "qcred:" + UUID().uuidString
        let item = identity(service: "org.quenderin.deepseek", account: reference)
        try requireAbsent(item)
        let initial = "quenderin-cloud-legacy-" + UUID().uuidString
        var legacy = item
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        legacy[kSecValueData as String] = Data(initial.utf8)
        let added = SecItemAdd(legacy as CFDictionary, nil)
        XCTAssertEqual(added, errSecSuccess)
        guard added == errSecSuccess else { throw FixtureFailure.missingData }
        registerCleanup(item)

        let store = DeepSeekKeychainStore()
        _ = try store.load(reference: reference)
        let updated = "quenderin-cloud-migrated-" + UUID().uuidString
        try store.save(DeepSeekAPIKey(updated), reference: reference)
        XCTAssertEqual(try readSyntheticData(item), Data(updated.utf8))

        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, reference)
        #if !os(macOS)
        // The legacy macOS Keychain does not support kSecAttrAccessible without
        // data-protection or synchronization enabled. Keep its existing identity
        // and verify CRUD above; iOS additionally verifies accessibility migration.
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #endif
        try store.remove(reference: reference)
        try requireAbsent(item)
    }

    @MainActor
    func testComputerCredentialSaveLoadUpdateReloadAndDeleteInAppSandbox() throws {
        // .invalid is reserved and this test never creates a client or HTTP request.
        let origin = "https://quenderin-cloud-" + UUID().uuidString.lowercased() + ".invalid"
        let item = identity(service: "org.quenderin.remote-harness.client.v1", account: origin)
        try requireAbsent(item)
        let initialToken = "synthetic-access-" + UUID().uuidString
        let initial = try computerCredential(origin: origin, accessToken: initialToken)
        let store = RemoteHarnessClientKeychainStorage()
        try store.save(initial)
        registerCleanup(item)

        let loaded = try XCTUnwrap(try RemoteHarnessClientKeychainStorage().load(origin: origin))
        XCTAssertEqual(loaded.origin, origin)
        XCTAssertEqual(loaded.deviceID, initial.deviceID)
        XCTAssertEqual(try syntheticToken(loaded), initialToken)

        let updatedToken = "synthetic-updated-" + UUID().uuidString
        let updated = try computerCredential(origin: origin, deviceID: initial.deviceID,
                                             accessToken: updatedToken)
        try store.save(updated)
        let reloaded = try XCTUnwrap(try RemoteHarnessClientKeychainStorage().load(origin: origin))
        XCTAssertEqual(reloaded.deviceID, initial.deviceID)
        XCTAssertEqual(try syntheticToken(reloaded), updatedToken)

        // This production store has no removal API. Delete ONLY the item this test
        // created, then prove a new production store sees absence.
        XCTAssertEqual(SecItemDelete(item as CFDictionary), errSecSuccess)
        XCTAssertNil(try RemoteHarnessClientKeychainStorage().load(origin: origin))
        try requireAbsent(item)
    }

    private func computerCredential(origin: String, deviceID: String = UUID().uuidString.lowercased(),
                                    accessToken: String) throws -> RemoteHarnessClientCredential {
        let identityKey = Data(repeating: 0x11, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let synthetic: [String: Any] = [
            "origin": origin, "deviceID": deviceID, "role": "client",
            "privateSeed": Data(repeating: 0x22, count: 32).base64EncodedString(),
            "identityKey": identityKey, "accessToken": accessToken,
            "refreshToken": "synthetic-refresh-" + UUID().uuidString,
            "accessTokenExpiresAt": 2_000_000_000_000 as Int64,
            "refreshTokenExpiresAt": 2_000_100_000_000 as Int64
        ]
        return try JSONDecoder().decode(RemoteHarnessClientCredential.self,
                                       from: JSONSerialization.data(withJSONObject: synthetic))
    }

    private func syntheticToken(_ credential: RemoteHarnessClientCredential) throws -> String {
        let encoded = try JSONEncoder().encode(credential)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return try XCTUnwrap(object["accessToken"] as? String)
    }

    private func identity(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func requireAbsent(_ item: [String: Any], file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        XCTAssertEqual(status, errSecItemNotFound, "Synthetic reference must be absent", file: file, line: line)
        guard status == errSecItemNotFound else { throw FixtureFailure.existingItem }
    }

    private func readSyntheticData(_ item: [String: Any]) throws -> Data {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        return try XCTUnwrap(result as? Data)
    }

    private func registerCleanup(_ ownedItem: [String: Any]) {
        // Registered only after successful creation at a reference proven absent.
        // Never enumerate a service, read a saved profile, or delete a wildcard query.
        addTeardownBlock {
            let status = SecItemDelete(ownedItem as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(ownedItem as CFDictionary, nil), errSecItemNotFound)
        }
    }
}
