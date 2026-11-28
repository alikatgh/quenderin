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
    enum StorageError: Error {
        case unavailable
        #if canImport(Security)
        case keychain(OSStatus)
        #endif
    }

    private let service: String
    private let account: String

    init(service: String = "org.quenderin.local-api", account: String = "bearer-key") {
        self.service = service
        self.account = account
    }

    #if canImport(Security)
    // Match DeepSeekKeychainStore/RemoteHarnessClientKeychainStorage: QuenderinMac has no
    // keychain-access-groups entitlement or provisioning profile in local/Debug/DMG builds,
    // where kSecUseDataProtectionKeychain fails with errSecMissingEntitlement (-34018).
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        guard let data = result as? Data,
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
        guard status == errSecItemNotFound else { throw StorageError.keychain(status) }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let added = SecItemAdd(item as CFDictionary, nil)
        let saved = added == errSecDuplicateItem
            ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            : added
        guard saved == errSecSuccess else { throw StorageError.keychain(saved) }
    }

    func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
    }
    #else
    func load() throws -> String? { throw StorageError.unavailable }
    func save(_ key: String) throws { throw StorageError.unavailable }
    func remove() throws { throw StorageError.unavailable }
    #endif
}
