import Foundation
import QuenderinRemoteCrypto

private enum BackendProbeFailure: Error { case failed }
private func require(_ value: Bool) throws { if !value { throw BackendProbeFailure.failed } }
private func failure(_ expected: RemoteHarnessCryptoError, _ action: () throws -> Void) throws {
    do { try action() } catch let error as RemoteHarnessCryptoError {
        try require(error == expected); return
    }
    throw BackendProbeFailure.failed
}

@main private struct NativeBackendSmoke {
    @MainActor static func main() throws {
        var random = SystemRandomNumberGenerator()
        var local = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        var remote = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        defer { local.resetBytes(in: local.indices); remote.resetBytes(in: remote.indices) }
        let backend = RemoteHarnessCryptoBackends.native()
        try require(backend.isAvailable)
        let info = try RemoteHarnessSecureConnectionInfo(connectionID: "backend-synthetic", localDeviceID: "backend-client", remoteDeviceID: "backend-host")
        try failure(.invalidKey) { _ = try backend.publicKey(privateSeed: Data(repeating: 0, count: 31)) }
        try failure(.invalidKey) { _ = try backend.initiator(privateSeed: local, peerPublicKey: Data(repeating: 0, count: 31), info: info) }
        let client = try backend.initiator(privateSeed: local, peerPublicKey: derivePublicKey(localPrivateKey: remote), info: info)
        let host = try NoiseIkSession.create(role: .responder, localPrivateKey: remote,
            enrolledRemotePublicKey: backend.publicKey(privateSeed: local), connectionId: info.connectionID,
            hostDeviceId: info.remoteDeviceID, clientDeviceId: info.localDeviceID)
        defer { try? client.shutdown(); try? host.shutdown() }
        try failure(.invalidMessage) { _ = try client.initiate(emptyPayload: Data([1])) }
        let hello = try client.initiate(emptyPayload: Data())
        try require(hello.count == 96)
        let reply = try host.readHandshake(message: hello)
        guard let response = reply.response else { throw BackendProbeFailure.failed }
        try require(reply.complete)
        let complete = try client.readHandshake(response)
        try require(complete.complete && complete.payload.isEmpty && complete.response == nil)
        let request = Data("synthetic backend request".utf8)
        try require(try host.decrypt(ciphertext: client.encrypt(request)) == request)
        let answer = Data("synthetic backend answer".utf8)
        let encrypted = try host.encrypt(plaintext: answer)
        var tampered = encrypted; tampered[tampered.startIndex] ^= 1
        try failure(.authentication) { _ = try client.decrypt(tampered) }
        try require(try client.counters().receiving == 0)
        try require(try client.decrypt(encrypted) == answer)
        try require(try client.counters().sending == 1 && client.counters().receiving == 1)
        try client.shutdown(); try client.shutdown()
        try failure(.closed) { _ = try client.counters() }
        print("NATIVE_PRODUCTION_BACKEND_PASS swift")
    }
}
