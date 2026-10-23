import Foundation
#if canImport(Security)
import Security
#endif

/// Credentials deliberately have no Codable representation or reflected contents.
public struct DeepSeekAPIKey: Sendable, NativeConnectionPrivateValue {
    let value: String
    public init(_ value: String) throws {
        guard (1...256).contains(value.utf8.count), value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DeepSeekFailure.invalidCredential
        }
        self.value = value
    }
}

public protocol DeepSeekCredentialStore: Sendable {
    func load(reference: String) throws -> DeepSeekAPIKey
    func save(_ key: DeepSeekAPIKey, reference: String) throws
    func remove(reference: String) throws
}

/// Stable class/service/account matching also loads older accessibility variants.
/// Accessibility is a write attribute, never part of an item's identity.
public struct DeepSeekKeychainStore: DeepSeekCredentialStore {
    public init() {}
    #if canImport(Security)
    func identity(_ reference: String) throws -> [String: Any] {
        guard reference.hasPrefix("qcred:"), UUID(uuidString: String(reference.dropFirst(6))) != nil else {
            throw DeepSeekFailure.credentialStorage
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.quenderin.deepseek",
                kSecAttrAccount as String: reference,
                kSecAttrSynchronizable as String: false]
    }
    public func load(reference: String) throws -> DeepSeekAPIKey {
        var query = try identity(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw DeepSeekFailure.credentialStorage
        }
        return try DeepSeekAPIKey(text)
    }
    public func save(_ key: DeepSeekAPIKey, reference: String) throws {
        let query = try identity(reference)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.value.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DeepSeekFailure.credentialStorage }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let added = SecItemAdd(item as CFDictionary, nil)
        // One bounded duplicate-add recovery, preserving the old item on failure.
        guard added == errSecSuccess || (added == errSecDuplicateItem && SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess)
        else { throw DeepSeekFailure.credentialStorage }
    }
    public func remove(reference: String) throws {
        let status = SecItemDelete(try identity(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeepSeekFailure.credentialStorage }
    }
    #else
    public func load(reference: String) throws -> DeepSeekAPIKey { throw DeepSeekFailure.credentialStorage }
    public func save(_ key: DeepSeekAPIKey, reference: String) throws { throw DeepSeekFailure.credentialStorage }
    public func remove(reference: String) throws { throw DeepSeekFailure.credentialStorage }
    #endif
}
