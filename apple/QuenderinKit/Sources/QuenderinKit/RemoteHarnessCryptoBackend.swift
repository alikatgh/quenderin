import Foundation
#if canImport(QuenderinRemoteCrypto)
import QuenderinRemoteCrypto
#endif

/// Fixed errors are safe for native UI; no FFI diagnostic or private input escapes.
public enum RemoteHarnessCryptoError: String, Error, Sendable, CustomStringConvertible {
    case unavailable, invalidKey, invalidContext, invalidState, invalidMessage, authentication, counter, closed, failed
    public var description: String { "Remote Harness cryptography: \(rawValue)" }
}

@MainActor public protocol RemoteHarnessCryptoBackend: AnyObject {
    var isAvailable: Bool { get }
    func publicKey(privateSeed: Data) throws -> Data
    func initiator(privateSeed: Data, peerPublicKey: Data, info: RemoteHarnessSecureConnectionInfo) throws -> any RemoteHarnessSecureNoise
}

@MainActor public enum RemoteHarnessCryptoBackends {
    public static func native() -> any RemoteHarnessCryptoBackend {
        #if canImport(QuenderinRemoteCrypto)
        return NativeRemoteHarnessCryptoBackend()
        #else
        return UnavailableRemoteHarnessCryptoBackend()
        #endif
    }
}

@MainActor private final class UnavailableRemoteHarnessCryptoBackend: RemoteHarnessCryptoBackend {
    let isAvailable = false
    func publicKey(privateSeed: Data) throws -> Data { throw RemoteHarnessCryptoError.unavailable }
    func initiator(privateSeed: Data, peerPublicKey: Data, info: RemoteHarnessSecureConnectionInfo) throws -> any RemoteHarnessSecureNoise {
        throw RemoteHarnessCryptoError.unavailable
    }
}

#if canImport(QuenderinRemoteCrypto)
private func sanitizedCrypto<T>(_ action: () throws -> T) throws -> T {
    do { return try action() }
    catch let error as NoiseError {
        switch error {
        case .InvalidKey: throw RemoteHarnessCryptoError.invalidKey
        case .InvalidPrologue: throw RemoteHarnessCryptoError.invalidContext
        case .InvalidState: throw RemoteHarnessCryptoError.invalidState
        case .MessageTooLarge, .InvalidMessage: throw RemoteHarnessCryptoError.invalidMessage
        case .AuthenticationFailed, .PeerIdentityMismatch: throw RemoteHarnessCryptoError.authentication
        case .CounterExhausted: throw RemoteHarnessCryptoError.counter
        case .Closed: throw RemoteHarnessCryptoError.closed
        case .Unavailable: throw RemoteHarnessCryptoError.unavailable
        }
    } catch let error as RemoteHarnessCryptoError { throw error }
    catch { throw RemoteHarnessCryptoError.failed }
}

@MainActor private final class NativeRemoteHarnessCryptoBackend: RemoteHarnessCryptoBackend {
    let isAvailable = true
    func publicKey(privateSeed: Data) throws -> Data {
        guard privateSeed.count == 32 else { throw RemoteHarnessCryptoError.invalidKey }
        return try sanitizedCrypto { try derivePublicKey(localPrivateKey: privateSeed) }
    }
    func initiator(privateSeed: Data, peerPublicKey: Data, info: RemoteHarnessSecureConnectionInfo) throws -> any RemoteHarnessSecureNoise {
        guard privateSeed.count == 32, peerPublicKey.count == 32 else { throw RemoteHarnessCryptoError.invalidKey }
        // The locked facade fixes the suite and encodes this exact v1 context.
        return try sanitizedCrypto { NativeRemoteHarnessNoise(try NoiseIkSession.create(role: .initiator,
            localPrivateKey: privateSeed, enrolledRemotePublicKey: peerPublicKey,
            connectionId: info.connectionID, hostDeviceId: info.remoteDeviceID, clientDeviceId: info.localDeviceID)) }
    }
}

@MainActor private final class NativeRemoteHarnessNoise: RemoteHarnessSecureNoise {
    private var handle: NoiseIkSession?
    init(_ handle: NoiseIkSession) { self.handle = handle }
    deinit { try? handle?.shutdown() }
    private func live() throws -> NoiseIkSession {
        guard let handle else { throw RemoteHarnessCryptoError.closed }; return handle
    }
    func initiate(emptyPayload: Data) throws -> Data {
        guard emptyPayload.isEmpty else { throw RemoteHarnessCryptoError.invalidMessage }
        return try sanitizedCrypto { try live().initiate() }
    }
    func readHandshake(_ bytes: Data) throws -> RemoteHarnessSecureHandshakeResult {
        try sanitizedCrypto {
            let result = try live().readHandshake(message: bytes)
            return try RemoteHarnessSecureHandshakeResult(complete: result.complete, payload: Data(), response: result.response)
        }
    }
    func counters() throws -> RemoteHarnessSecureCounters {
        try sanitizedCrypto {
            let value = try live().counters()
            guard value.sending <= UInt64(RemoteHarnessSecureLink.maximumCounter),
                  value.receiving <= UInt64(RemoteHarnessSecureLink.maximumCounter) else {
                try? shutdown(); throw RemoteHarnessCryptoError.counter
            }
            return RemoteHarnessSecureCounters(complete: value.complete, sending: Int64(value.sending), receiving: Int64(value.receiving))
        }
    }
    func encrypt(_ plaintext: Data) throws -> Data { try sanitizedCrypto { try live().encrypt(plaintext: plaintext) } }
    func decrypt(_ ciphertext: Data) throws -> Data { try sanitizedCrypto { try live().decrypt(ciphertext: ciphertext) } }
    func shutdown() throws {
        guard let value = handle else { return }; handle = nil
        try sanitizedCrypto { try value.shutdown() }
    }
}
#endif
