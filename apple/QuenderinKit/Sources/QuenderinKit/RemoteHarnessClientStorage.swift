import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum RemoteHarnessClientFailure: String, Error, Sendable, LocalizedError {
    case cryptoUnavailable, companionRequired, invalidServer, authorization, reauthorize, storage, protocolMismatch, connection, timeout, pinChanged, busy, limit, unknownOutcome
    public var errorDescription: String? {
        switch self {
        case .cryptoUnavailable: return "This build does not include the secure computer connection runtime. Install a build with Remote Harness support."
        case .companionRequired: return "Install and pair the Quenderin Host companion on this computer, then reconnect to create sessions, send tasks, or change models. You can still read existing sessions and stop a running task."
        case .invalidServer: return "Enter the HTTPS origin of your self-hosted Remote Harness server."
        case .authorization: return "The server did not authorize this account or device. Check your account on that server."
        case .reauthorize: return "Sign in again to renew this device. An interrupted token rotation cannot be retried."
        case .storage: return "Protected computer connection data could not be read or saved. Existing data has been preserved."
        case .protocolMismatch: return "The computer or server returned an unsupported connection response."
        case .connection: return "The computer connection ended. Reconnect to recover the authoritative session."
        case .timeout: return "The computer connection timed out. Reconnect to check the session before sending again."
        case .pinChanged: return "This computer’s identity has changed. Verify it on the computer before setting up a new trusted connection."
        case .busy: return "A computer connection operation is already in progress."
        case .limit: return "The connection reached its bounded data limit. Reconnect to recover history."
        case .unknownOutcome: return "The command may have reached the computer. Recover the session before deciding what to send next."
        }
    }
}

enum RemoteHarnessClientEncoding {
    static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func key(_ value: String) throws -> Data {
        guard value.utf8.count == 43, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32,
              base64(bytes).utf8.elementsEqual(value.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }
        return bytes
    }
    static func digest(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        throw RemoteHarnessClientFailure.cryptoUnavailable
        #endif
    }
    static func randomSeed() throws -> Data {
        #if canImport(Security)
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RemoteHarnessClientFailure.storage }; return data
        #else
        throw RemoteHarnessClientFailure.cryptoUnavailable
        #endif
    }
    static func deviceID(_ text: String) throws {
        guard text.range(of: #"^(?:[0-9A-HJKMNP-TV-Z]{26}|[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$"#, options: [.regularExpression, .caseInsensitive]) != nil else { throw RemoteHarnessClientFailure.protocolMismatch }
    }
}

/// Only this record contains device secrets. It is scoped to one canonical
/// server/device/client role and is never part of a profile or transcript.
public struct RemoteHarnessClientCredential: Codable, NativeConnectionPrivateValue {
    public let origin: String
    public let deviceID: String
    public let role: String
    let privateSeed: Data
    let identityKey: String
    var accessToken: String?
    var accessTokenExpiresAt: Int64?
    var refreshToken: String?
    var refreshTokenExpiresAt: Int64?
    var refreshAttemptID: String?
    init(origin: String, deviceID: String, privateSeed: Data, identityKey: String) throws {
        self.origin = try NativeConnectionOrigin.canonical(origin); try RemoteHarnessClientEncoding.deviceID(deviceID)
        guard privateSeed.count == 32 else { throw RemoteHarnessClientFailure.storage }
        _ = try RemoteHarnessClientEncoding.key(identityKey)
        self.deviceID = deviceID; self.role = "client"; self.privateSeed = privateSeed; self.identityKey = identityKey
    }
    func validate(origin: String) throws {
        guard self.origin == (try NativeConnectionOrigin.canonical(origin)), role == "client", privateSeed.count == 32 else { throw RemoteHarnessClientFailure.storage }
        try RemoteHarnessClientEncoding.deviceID(deviceID); _ = try RemoteHarnessClientEncoding.key(identityKey)
        let count = [accessToken != nil, accessTokenExpiresAt != nil, refreshToken != nil, refreshTokenExpiresAt != nil].filter { $0 }.count
        guard count == 0 || count == 4 else { throw RemoteHarnessClientFailure.storage }
        for token in [accessToken, refreshToken].compactMap({ $0 }) { guard (16...8192).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteHarnessClientFailure.storage } }
        for expiry in [accessTokenExpiresAt, refreshTokenExpiresAt].compactMap({ $0 }) { guard expiry > 0, expiry <= NativeConnectionBounds.counter else { throw RemoteHarnessClientFailure.storage } }
    }
    mutating func install(_ value: RemoteHarnessJSON) throws {
        let f = try value.fields()
        accessToken = try f.text("accessToken"); refreshToken = try f.text("refreshToken")
        accessTokenExpiresAt = try f.required("accessTokenExpiresAt").integerValue(); refreshTokenExpiresAt = try f.required("refreshTokenExpiresAt").integerValue()
        refreshAttemptID = nil; try validate(origin: origin)
    }
}

@MainActor public protocol RemoteHarnessClientCredentialStorage: AnyObject {
    func load(origin: String) throws -> RemoteHarnessClientCredential?
    /// Atomic update preserving the previous record on failure.
    func save(_ credential: RemoteHarnessClientCredential) throws
}

@MainActor public final class RemoteHarnessClientKeychainStorage: RemoteHarnessClientCredentialStorage {
    public init() {}
    #if canImport(Security)
    private func identity(_ origin: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.quenderin.remote-harness.client.v1",
         kSecAttrAccount as String: try NativeConnectionOrigin.canonical(origin), kSecAttrSynchronizable as String: false]
    }
    public func load(origin: String) throws -> RemoteHarnessClientCredential? {
        var q = try identity(origin); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw RemoteHarnessClientFailure.storage }
        do { try NativeStrictJSON.validate(data); let record = try JSONDecoder().decode(RemoteHarnessClientCredential.self, from: data); try record.validate(origin: origin); return record }
        catch { throw RemoteHarnessClientFailure.storage }
    }
    public func save(_ credential: RemoteHarnessClientCredential) throws {
        try credential.validate(origin: credential.origin)
        let data = try JSONEncoder().encode(credential); guard data.count <= 65_536 else { throw RemoteHarnessClientFailure.storage }
        let q = try identity(credential.origin)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }; guard status == errSecItemNotFound else { throw RemoteHarnessClientFailure.storage }
        var add = q; attrs.forEach { add[$0.key] = $0.value }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || (added == errSecDuplicateItem && SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecSuccess) else { throw RemoteHarnessClientFailure.storage }
    }
    #else
    public func load(origin: String) throws -> RemoteHarnessClientCredential? { throw RemoteHarnessClientFailure.storage }
    public func save(_ credential: RemoteHarnessClientCredential) throws { throw RemoteHarnessClientFailure.storage }
    #endif
}

public struct RemoteHarnessClientSavedCommand: Codable, NativeConnectionPrivateValue {
    let id: String
    let hostID: String
    let workspaceID: String?
    let sessionID: String?
    let endpoint: String
    /// The exact private operation is protected by the local journal, never logged.
    let params: Data
    var outcome: String
}
/// Durable navigation restriction only; this contains no Bot display data.
/// A missing optional marker in an older record means no known restriction.
struct RemoteHarnessClientBotSessionScope: Codable, NativeConnectionPrivateValue {
    let origin: String
    let hostID: String
    let hostFingerprint: String
    let workspaceID: String
    let sessionID: String
    func matches(origin: String?, hostID: String?, hostFingerprint: String?, workspaceID: String?, sessionID: String?) -> Bool {
        guard let origin, let hostID, let hostFingerprint, let workspaceID, let sessionID else { return false }
        return self.origin.utf8.elementsEqual(origin.utf8) && self.hostID.utf8.elementsEqual(hostID.utf8)
            && self.hostFingerprint.utf8.elementsEqual(hostFingerprint.utf8) && self.workspaceID.utf8.elementsEqual(workspaceID.utf8)
            && self.sessionID.utf8.elementsEqual(sessionID.utf8)
    }
}
public struct RemoteHarnessClientSavedSession: Codable, NativeConnectionPrivateValue {
    let hostID: String
    let workspaceID: String
    let sessionID: String
    var draft: String
    var history: [Data]
    var botReadOnlyScope: RemoteHarnessClientBotSessionScope? = nil
}
struct RemoteHarnessClientRecoveryHost: Codable, NativeConnectionPrivateValue {
    let hostID: String
    let fingerprint: String
    func matches(_ host: RemoteHarnessClientHost) -> Bool {
        hostID.utf8.elementsEqual(host.deviceID.utf8) && host.fingerprint.map { fingerprint.utf8.elementsEqual($0.utf8) } == true
    }
}

/// Kept separately from transcript writes so a protected-journal failure cannot
/// discard the user's explicit choice to stay disconnected.
@MainActor public protocol RemoteHarnessClientRecoveryIntentStorage: AnyObject {
    func loadAutomaticRecoveryIntent() throws -> Bool
    func saveAutomaticRecoveryIntent(_ allowed: Bool) throws
}
@MainActor public final class RemoteHarnessClientRecoveryPreferences: RemoteHarnessClientRecoveryIntentStorage {
    private let defaults: UserDefaults
    private let key = "remoteHarness.connection.automaticRecoveryAllowed"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func loadAutomaticRecoveryIntent() throws -> Bool {
        guard let value = defaults.object(forKey: key) else { return true }
        return value as? Bool ?? false
    }
    public func saveAutomaticRecoveryIntent(_ allowed: Bool) throws { defaults.set(allowed, forKey: key) }
}

public struct RemoteHarnessClientComposerDestination: Sendable, Equatable, NativeConnectionPrivateValue {
    let origin: String
    let hostID: String
    let fingerprint: String
    let workspaceID: String
    let sessionID: String
    public static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.origin, lhs.hostID, lhs.fingerprint, lhs.workspaceID, lhs.sessionID],
            [rhs.origin, rhs.hostID, rhs.fingerprint, rhs.workspaceID, rhs.sessionID]).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
    }
}
public struct RemoteHarnessClientComposerSubmission: NativeConnectionPrivateValue {
    let destination: RemoteHarnessClientComposerDestination
    let text: String
    let acceptedEditID: UUID
}
struct RemoteHarnessClientUnsavedDraft: NativeConnectionPrivateValue {
    let destination: RemoteHarnessClientComposerDestination
    let text: String
}
public struct RemoteHarnessClientJournal: Codable, NativeConnectionPrivateValue {
    public var schemaVersion = 1
    public var origin: String?
    public var deviceID: String?
    public var pins: [String: String] = [:]
    public var profile: NativeConnectionProfile?
    public var sessionID: String?
    public var draft = ""
    public var history: [Data] = []
    public var commands: [RemoteHarnessClientSavedCommand] = []
    public var savedSessions: [RemoteHarnessClientSavedSession] = []
    var botReadOnlyScope: RemoteHarnessClientBotSessionScope?
    var recoveryHost: RemoteHarnessClientRecoveryHost?
    public init() {}
    func validate() throws {
        guard schemaVersion == 1, pins.count <= 256, history.count <= 1024, commands.count <= 4096, savedSessions.count <= 50, draft.utf8.count <= 65_536 else { throw RemoteHarnessClientFailure.storage }
        if let origin { guard try NativeConnectionOrigin.canonical(origin) == origin else { throw RemoteHarnessClientFailure.storage } }
        if let deviceID { try RemoteHarnessClientEncoding.deviceID(deviceID) }
        if let profile { guard profile.kind == .remoteHarness, profile.endpoint == origin, let hostID = profile.hostID, pins[hostID] == profile.hostFingerprint else { throw RemoteHarnessClientFailure.storage } }
        if let recoveryHost {
            try RemoteHarnessClientEncoding.deviceID(recoveryHost.hostID)
            try NativeConnectionBounds.digest(recoveryHost.fingerprint)
            guard origin != nil, pins[recoveryHost.hostID]?.utf8.elementsEqual(recoveryHost.fingerprint.utf8) == true,
                  profile == nil || (profile?.hostID?.utf8.elementsEqual(recoveryHost.hostID.utf8) == true && profile?.hostFingerprint?.utf8.elementsEqual(recoveryHost.fingerprint.utf8) == true) else { throw RemoteHarnessClientFailure.storage }
        }
        guard sessionID == nil || profile != nil, Set(commands.map(\.id)).count == commands.count else { throw RemoteHarnessClientFailure.storage }
        if let scope = botReadOnlyScope {
            guard scope.matches(origin: origin, hostID: profile?.hostID, hostFingerprint: profile?.hostFingerprint, workspaceID: profile?.workspaceID, sessionID: sessionID) else { throw RemoteHarnessClientFailure.storage }
        }
        for data in history { _ = try RemoteHarnessJSON(data: data) }
        for command in commands { _ = try RemoteHarnessJSON(data: command.params) }
        for session in savedSessions {
            guard !session.hostID.isEmpty, !session.workspaceID.isEmpty, !session.sessionID.isEmpty, session.draft.utf8.count <= 65_536, session.history.count <= 1024 else { throw RemoteHarnessClientFailure.storage }
            if let scope = session.botReadOnlyScope {
                guard scope.matches(origin: origin, hostID: session.hostID, hostFingerprint: pins[session.hostID], workspaceID: session.workspaceID, sessionID: session.sessionID) else { throw RemoteHarnessClientFailure.storage }
            }
            for data in session.history { _ = try RemoteHarnessJSON(data: data) }
        }
    }
}
@MainActor public protocol RemoteHarnessClientJournalStorage: AnyObject {
    func load() throws -> RemoteHarnessClientJournal?
    func save(_ journal: RemoteHarnessClientJournal) throws
}
@MainActor public final class RemoteHarnessClientFileStorage: RemoteHarnessClientJournalStorage {
    private let file: URL?
    public init(directory: URL? = nil) {
        file = (directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("remote-harness", isDirectory: true))?.appendingPathComponent("client-v1.json")
    }
    public func load() throws -> RemoteHarnessClientJournal? {
        guard let file else { throw RemoteHarnessClientFailure.storage }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attrs[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else { throw RemoteHarnessClientFailure.storage }
            let bytes = try Data(contentsOf: file); try NativeStrictJSON.validate(bytes, integerNumbersOnly: false)
            let value = try JSONDecoder().decode(RemoteHarnessClientJournal.self, from: bytes); try value.validate(); return value
        } catch { throw RemoteHarnessClientFailure.storage }
    }
    public func save(_ journal: RemoteHarnessClientJournal) throws {
        guard let file else { throw RemoteHarnessClientFailure.storage }
        do {
            try journal.validate(); let data = try JSONEncoder().encode(journal)
            guard data.count <= 16 * 1024 * 1024 else { throw RemoteHarnessClientFailure.storage }
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var excluded = directory; var attrs = URLResourceValues(); attrs.isExcludedFromBackup = true; try excluded.setResourceValues(attrs)
            let staged = directory.appendingPathComponent(".client-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            #if os(iOS)
            try data.write(to: staged, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: staged, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            guard rename(staged.path, file.path) == 0 else { throw RemoteHarnessClientFailure.storage }
        } catch { throw RemoteHarnessClientFailure.storage }
    }
}
