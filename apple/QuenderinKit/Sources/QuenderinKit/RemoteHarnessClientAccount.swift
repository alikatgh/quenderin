import Foundation

/// Enrollment and single-use token rotation are independently fixture-testable.
/// Password/account bearer live only across the explicit setup call.
@MainActor public final class RemoteHarnessClientAccount: NativeConnectionPrivateValue {
    private let http: any RemoteHarnessClientHTTP
    private let storage: any RemoteHarnessClientCredentialStorage
    private let backend: any RemoteHarnessCryptoBackend
    private let clock: any RemoteHarnessClock
    private let randomSeed: () throws -> Data
    private var busy = false
    public init(http: any RemoteHarnessClientHTTP, storage: any RemoteHarnessClientCredentialStorage, backend: any RemoteHarnessCryptoBackend,
                clock: (any RemoteHarnessClock)? = nil, randomSeed: (() throws -> Data)? = nil) {
        self.http = http; self.storage = storage; self.backend = backend; self.clock = clock ?? RemoteHarnessClientSystemClock(); self.randomSeed = randomSeed ?? { try RemoteHarnessClientEncoding.randomSeed() }
    }
    public var isAvailable: Bool { backend.isAvailable }
    public func authorize(origin: String, email: String, password: String, deviceName: String) async throws -> RemoteHarnessClientCredential {
        guard backend.isAvailable else { throw RemoteHarnessClientFailure.cryptoUnavailable }
        guard !busy else { throw RemoteHarnessClientFailure.busy }; busy = true; defer { busy = false }
        let canonical = try NativeConnectionOrigin.canonical(origin)
        guard (1...254).contains(email.utf8.count), (1...1024).contains(password.utf8.count), (1...128).contains(deviceName.utf8.count), !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteHarnessClientFailure.authorization }
        var credential: RemoteHarnessClientCredential
        if let existing = try storage.load(origin: canonical) { try existing.validate(origin: canonical); credential = existing }
        else {
            let seed = try randomSeed(), key = try backend.publicKey(privateSeed: seed)
            credential = try RemoteHarnessClientCredential(origin: canonical, deviceID: UUID().uuidString.lowercased(), privateSeed: seed, identityKey: RemoteHarnessClientEncoding.base64(key))
            try storage.save(credential) // Identity MUST survive process loss before registration.
        }
        let login = try await http.request(origin: canonical, path: "/api/v1/auth/login", method: "POST", bearer: nil, body: .object(["email": .string(email), "password": .string(password)]))
        try Task.checkCancellation()
        let response = try login.fields(), token = try response.text("token")
        guard token.utf8.count >= 16, token.utf8.count <= 8192, token.utf8.allSatisfy({ (33...126).contains($0) }), try response.required("expiresAt").integerValue() > clock.nowEpochMilliseconds else { throw RemoteHarnessClientFailure.authorization }
        #if os(macOS)
        let platform = "macos"
        #elseif os(iOS)
        let platform = "ios"
        #else
        let platform = "native"
        #endif
        let pair = try await http.request(origin: canonical, path: "/api/v1/devices/register", method: "POST", bearer: token,
            body: .object(["v": .integer(1), "device": .object(["deviceId": .string(credential.deviceID), "name": .string(deviceName), "role": .string("client"), "platform": .string(platform), "identityKey": .string(credential.identityKey), "clientVersion": .string("quenderin/0.4")])]))
        try credential.install(pair)
        guard credential.accessTokenExpiresAt! > clock.nowEpochMilliseconds, credential.refreshTokenExpiresAt! > clock.nowEpochMilliseconds else { throw RemoteHarnessClientFailure.authorization }
        try storage.save(credential) // No device-token use until the whole pair is durable.
        return credential
    }
    public func credential(origin: String, deviceID: String) async throws -> RemoteHarnessClientCredential {
        guard !busy else { throw RemoteHarnessClientFailure.busy }; busy = true; defer { busy = false }
        guard var credential = try storage.load(origin: origin), credential.deviceID.utf8.elementsEqual(deviceID.utf8) else { throw RemoteHarnessClientFailure.reauthorize }
        try credential.validate(origin: origin)
        guard credential.refreshAttemptID == nil, let accessExpiry = credential.accessTokenExpiresAt,
              let refresh = credential.refreshToken, let refreshExpiry = credential.refreshTokenExpiresAt, refreshExpiry > clock.nowEpochMilliseconds else { throw RemoteHarnessClientFailure.reauthorize }
        if accessExpiry > clock.nowEpochMilliseconds + 30_000 { return credential }
        credential.refreshAttemptID = UUID().uuidString
        try storage.save(credential) // Single-use reservation precedes the request.
        do {
            let pair = try await http.request(origin: credential.origin, path: "/api/v1/auth/refresh", method: "POST", bearer: nil,
                body: .object(["deviceId": .string(credential.deviceID), "refreshToken": .string(refresh)]))
            var installed = credential; try installed.install(pair)
            guard installed.accessTokenExpiresAt! > clock.nowEpochMilliseconds, installed.refreshTokenExpiresAt == refreshExpiry,
                  installed.refreshToken != refresh else { throw RemoteHarnessClientFailure.protocolMismatch }
            try storage.save(installed); return installed
        } catch {
            // Do not clear the durable reservation or replay the consumed token.
            throw RemoteHarnessClientFailure.reauthorize
        }
    }
    public func hosts(_ credential: RemoteHarnessClientCredential) async throws -> [RemoteHarnessClientHost] {
        let value = try await http.request(origin: credential.origin, path: "/api/v1/devices", method: "GET", bearer: credential.accessToken, body: nil)
        let rows = try value.fields().required("items").elements()
        guard rows.count <= 256 else { throw RemoteHarnessClientFailure.limit }
        let hosts = try rows.map { try RemoteHarnessClientHost($0, descriptor: false) }
        guard Set(hosts.map(\.deviceID)).count == hosts.count else { throw RemoteHarnessClientFailure.protocolMismatch }; return hosts
    }
    public func host(_ summary: RemoteHarnessClientHost, credential: RemoteHarnessClientCredential) async throws -> RemoteHarnessClientHost {
        try RemoteHarnessClientEncoding.deviceID(summary.deviceID)
        let value = try await http.request(origin: credential.origin, path: "/api/v1/devices/" + summary.deviceID, method: "GET", bearer: credential.accessToken, body: nil)
        let descriptor = try RemoteHarnessClientHost(value, descriptor: true); try descriptor.requireMatch(summary)
        let presence = try await http.request(origin: credential.origin, path: "/api/v1/devices/" + summary.deviceID + "/presence", method: "GET", bearer: credential.accessToken, body: nil)
        let p = try presence.fields(); guard try p.text("deviceId").utf8.elementsEqual(summary.deviceID.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }
        guard try p.required("online").booleanValue() else { throw RemoteHarnessClientFailure.connection }; return descriptor
    }
}
