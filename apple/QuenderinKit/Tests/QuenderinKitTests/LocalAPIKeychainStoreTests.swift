#if os(macOS)
import Foundation
import Security
import XCTest
@testable import QuenderinKit

final class LocalAPIKeychainStoreTests: XCTestCase {
    @MainActor
    func testSaveLoadOverwriteAndRemoveOnHost() async throws {
        let service = "org.quenderin.tests.local-api.\(UUID().uuidString)"
        let account = "fixture"
        let store = LocalAPIKeychainStore(service: service, account: account)
        do {
            guard try store.load() == nil else {
                XCTFail("The UUID-scoped fixture must be absent before writing")
                return
            }
            try store.save("initial-fixture")
        } catch LocalAPIKeychainStore.StorageError.keychain(let status) where [
            errSecMissingEntitlement, errSecNotAvailable, errSecNoSuchKeychain,
            errSecNoDefaultKeychain, errSecInteractionNotAllowed, errSecReadOnly,
        ].contains(status) {
            throw XCTSkip("The test host has no writable Keychain (OSStatus \(status))")
        }
        defer { XCTAssertNoThrow(try store.remove()) }

        let reopened = LocalAPIKeychainStore(service: service, account: account)
        XCTAssertEqual(try reopened.load(), "initial-fixture")
        try reopened.save("replacement-fixture")
        XCTAssertEqual(try store.load(), "replacement-fixture")

        try store.remove()
        XCTAssertNil(try reopened.load())
    }
}
#endif
