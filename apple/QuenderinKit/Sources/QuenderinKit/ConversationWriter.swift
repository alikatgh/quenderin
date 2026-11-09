import Foundation

/// One live writer per conversation, adapted from Turnstone's workstream owner.
///
/// A second writer does not append. Only the live permit can release the
/// conversation. After its lifetime, a new writer may replace a crashed one.
/// Releasing a stale permit leaves the newer owner in place.
public struct WriterPermit: Sendable, Equatable {
    public let conversationId: String
    public let writerId: String
    public let token: String
    public let expiresAtMs: Int64
}

public enum WriterClaim: Sendable, Equatable {
    case granted(WriterPermit)
    case busy(ownerId: String, message: String)
}

public final class ConversationWriter: @unchecked Sendable {
    public static let shared = ConversationWriter()
    private let lock = NSLock()
    private var owners: [String: WriterPermit] = [:]
    private var nonce = 0

    public init() {}

    public static func busyMessage(_ ownerId: String) -> String {
        "This conversation already has a live reply from \"\(ownerId)\". Wait for it to finish."
    }

    public static let idMessage = "A conversation writer needs a conversation and a writer."
    public static let ttlMessage = "A conversation writer needs a positive lifetime."

    public func claim(conversationId: String, writerId: String, nowMs: Int64, ttlMs: Int64) -> WriterClaim {
        let conversation = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let writer = writerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation.isEmpty || writer.isEmpty { return .busy(ownerId: "", message: Self.idMessage) }
        if ttlMs <= 0 { return .busy(ownerId: "", message: Self.ttlMessage) }
        lock.lock()
        defer { lock.unlock() }
        if let current = owners[conversation], nowMs < current.expiresAtMs {
            return .busy(ownerId: current.writerId, message: Self.busyMessage(current.writerId))
        }
        nonce += 1
        let permit = WriterPermit(
            conversationId: conversation, writerId: writer, token: String(nonce),
            expiresAtMs: nowMs &+ ttlMs
        )
        owners[conversation] = permit
        return .granted(permit)
    }

    /// True only when this permit is still the live owner.
    public func release(_ permit: WriterPermit, nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = owners[permit.conversationId], current.token == permit.token else { return false }
        owners.removeValue(forKey: permit.conversationId)
        _ = nowMs
        return true
    }
}
