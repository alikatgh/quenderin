import Foundation
#if canImport(Security)
import Security
#endif

@MainActor
protocol LocalAPIKeyStore {
    /// Returns nil when no key is stored. A read failure throws.
    func load() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

struct LocalAPIKeychainStore: LocalAPIKeyStore {
    private enum StorageError: Error { case unavailable }

    #if canImport(Security)
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.quenderin.local-api",
         kSecAttrAccount as String: "bearer-key",
         kSecAttrSynchronizable as String: false,
         // macOS applies the accessibility attribute in the data protection keychain.
         kSecUseDataProtectionKeychain as String: true]
    }

    func load() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw StorageError.unavailable }
        return key
    }

    func save(_ key: String) throws {
        let query = identity
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageError.unavailable }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess || (added == errSecDuplicateItem &&
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess) else {
            throw StorageError.unavailable
        }
    }

    func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.unavailable }
    }
    #else
    func load() throws -> String? { throw StorageError.unavailable }
    func save(_ key: String) throws { throw StorageError.unavailable }
    func remove() throws { throw StorageError.unavailable }
    #endif
}
