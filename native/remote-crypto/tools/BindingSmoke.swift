import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Compiles with actual generated Swift/header/module-map source and links the
// same locked Rust Linux library. This is a host FFI test, not an Apple SDK test.
private enum BindingProbeFailure: Error { case failed }

private func require(_ condition: Bool) throws {
    if !condition { throw BindingProbeFailure.failed }
}

private func expectFailure(_ expected: NoiseError, _ action: () throws -> Void) throws {
    do {
        try action()
    } catch let failure as NoiseError {
        try require(failure == expected)
        return
    }
    throw BindingProbeFailure.failed
}

private func create(
    _ role: NoiseRole, _ privateKey: Data, _ peer: Data,
    connection: String = "host-binding-connection"
) throws -> NoiseIkSession {
    try NoiseIkSession.create(
        role: role, localPrivateKey: privateKey, enrolledRemotePublicKey: peer,
        connectionId: connection, hostDeviceId: "host-binding-host", clientDeviceId: "host-binding-client"
    )
}

private func roundTripAndLifecycle(_ firstPrivate: Data, _ secondPrivate: Data) throws {
    let firstPublic = try derivePublicKey(localPrivateKey: firstPrivate)
    let secondPublic = try derivePublicKey(localPrivateKey: secondPrivate)
    try require(firstPublic.count == 32 && secondPublic.count == 32)
    try expectFailure(.InvalidKey) { _ = try derivePublicKey(localPrivateKey: Data(repeating: 0, count: 31)) }
    let initiator = try create(.initiator, firstPrivate, secondPublic)
    let responder = try create(.responder, secondPrivate, firstPublic)
    try expectFailure(.InvalidState) { _ = try initiator.encrypt(plaintext: Data()) }
    let first = try initiator.initiate()
    try require(first.count == 96)
    let reply = try responder.readHandshake(message: first)
    guard let second = reply.response else { throw BindingProbeFailure.failed }
    try require(reply.complete && second.count == 48)
    let finished = try initiator.readHandshake(message: second)
    try require(finished.complete && finished.response == nil)
    try require(try initiator.counters() == NoiseCounters(complete: true, sending: 0, receiving: 0))
    try require(try responder.counters() == NoiseCounters(complete: true, sending: 0, receiving: 0))

    let plaintext = Data("host binding request".utf8)
    let ciphertext = try initiator.encrypt(plaintext: plaintext)
    var tampered = ciphertext
    tampered[tampered.startIndex] ^= 1
    try expectFailure(.AuthenticationFailed) { _ = try responder.decrypt(ciphertext: tampered) }
    try require(try responder.counters().receiving == 0)
    try require(try responder.decrypt(ciphertext: ciphertext) == plaintext)
    try expectFailure(.AuthenticationFailed) { _ = try responder.decrypt(ciphertext: ciphertext) }
    try require(try responder.counters().receiving == 1)
    let following = Data("next host binding request".utf8)
    try require(try responder.decrypt(ciphertext: initiator.encrypt(plaintext: following)) == following)
    let answer = Data("host binding answer".utf8)
    try require(try initiator.decrypt(ciphertext: responder.encrypt(plaintext: answer)) == answer)
    try require(try initiator.counters() == NoiseCounters(complete: true, sending: 2, receiving: 1))
    try require(try responder.counters() == NoiseCounters(complete: true, sending: 1, receiving: 2))
    try initiator.shutdown()
    try initiator.shutdown()
    try expectFailure(.Closed) { _ = try initiator.counters() }
    try expectFailure(.Closed) { _ = try initiator.encrypt(plaintext: Data()) }
    try responder.shutdown()
    try expectFailure(.Closed) { _ = try responder.decrypt(ciphertext: ciphertext) }

    var disposable: NoiseIkSession? = try create(.initiator, firstPrivate, secondPublic)
    weak var released = disposable
    try disposable?.shutdown()
    disposable = nil
    try require(released == nil)
}

private func rejectsPeerAndContext(_ firstPrivate: Data, _ secondPrivate: Data, _ wrongPrivate: Data) throws {
    let firstPublic = try derivePublicKey(localPrivateKey: firstPrivate)
    let secondPublic = try derivePublicKey(localPrivateKey: secondPrivate)
    let wrongPublic = try derivePublicKey(localPrivateKey: wrongPrivate)
    let initiator = try create(.initiator, firstPrivate, secondPublic)
    let responder = try create(.responder, secondPrivate, wrongPublic)
    try expectFailure(.PeerIdentityMismatch) { _ = try responder.readHandshake(message: initiator.initiate()) }
    try expectFailure(.Closed) { _ = try responder.counters() }
    let otherInitiator = try create(.initiator, firstPrivate, secondPublic)
    let otherResponder = try create(.responder, secondPrivate, firstPublic, connection: "other-host-binding-context")
    try expectFailure(.AuthenticationFailed) { _ = try otherResponder.readHandshake(message: otherInitiator.initiate()) }
    try expectFailure(.Closed) { _ = try otherResponder.counters() }
}

@main
private struct BindingSmoke {
    static func main() {
        var random = SystemRandomNumberGenerator()
        var firstPrivate = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        var secondPrivate = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        var wrongPrivate = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        defer {
            firstPrivate.resetBytes(in: firstPrivate.startIndex..<firstPrivate.endIndex)
            secondPrivate.resetBytes(in: secondPrivate.startIndex..<secondPrivate.endIndex)
            wrongPrivate.resetBytes(in: wrongPrivate.startIndex..<wrongPrivate.endIndex)
        }
        do {
            try roundTripAndLifecycle(firstPrivate, secondPrivate)
            try rejectsPeerAndContext(firstPrivate, secondPrivate, wrongPrivate)
            print("QUENDERIN_REMOTE_SWIFT_BINDING_SMOKE_PASS")
        } catch {
            FileHandle.standardError.write(Data("Generated Swift host binding smoke failed.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
