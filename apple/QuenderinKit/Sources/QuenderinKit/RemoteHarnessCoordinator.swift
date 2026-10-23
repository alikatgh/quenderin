import Foundation

/// Supplied by an authenticated channel adapter, never read from message payloads.
/// Nil workspace/session explicitly denotes a discovery scope, not a wildcard for
/// dispatching session or workspace mutations.
public struct RemoteHarnessBinding: Sendable, Equatable, NativeConnectionPrivateValue {
    public let generation: UInt64
    public let hostID: String
    public let workspaceID: String?
    public let sessionID: String?
    public init(generation: UInt64, hostID: String, workspaceID: String? = nil, sessionID: String? = nil) throws {
        guard generation > 0, !hostID.isEmpty, hostID.utf8.count <= 1_024,
              workspaceID == nil || !(workspaceID?.isEmpty ?? true), sessionID == nil || workspaceID != nil,
              sessionID == nil || !(sessionID?.isEmpty ?? true), (workspaceID?.utf8.count ?? 0) <= 1_024,
              (sessionID?.utf8.count ?? 0) <= 1_024 else { throw RemoteHarnessError.bindingMismatch }
        self.generation = generation; self.hostID = hostID; self.workspaceID = workspaceID; self.sessionID = sessionID
    }
}

@MainActor public protocol RemoteHarnessBusinessPort: AnyObject {
    /// Sending may synchronously deliver a decrypted callback, including before
    /// an open response. A thrown send has an uncertain delivery outcome.
    func send(_ data: Data, binding: RemoteHarnessBinding) throws
    /// Must retire the authenticated connection. No new connection is opened here.
    func invalidate(binding: RemoteHarnessBinding)
}
@MainActor public protocol RemoteHarnessClock: AnyObject {
    var nowEpochMilliseconds: Int64 { get }
    /// Must advance independently of wall-clock and timezone adjustments.
    var monotonicMilliseconds: Int64 { get }
}

public enum RemoteHarnessJournalOutcome: String, Sendable { case responseReceived, rejected, notDispatched, outcomeUnknown }
public struct RemoteHarnessJournalCommand: Sendable, Equatable, NativeConnectionPrivateValue {
    public let commandID: String
    public let rpcID: String
    public let binding: RemoteHarnessBinding
    public let operation: RemoteHarnessOperation
    public let preparedAtEpochMilliseconds: Int64
}
@MainActor public protocol RemoteHarnessCommandJournal: AnyObject {
    /// Atomically persist before dispatch, rejecting any previously reserved
    /// command ID, including across restarts and connections. Throw on failure.
    /// Implementations must protect private params and retain uncertain commands.
    func persistBeforeDispatch(_ command: RemoteHarnessJournalCommand) throws
    func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws
}

public enum RemoteHarnessCompletion: Sendable, Equatable, NativeConnectionPrivateValue {
    /// Receipt/value only. Prompt has no invented `accepted` result.
    case response(RemoteHarnessJSON?)
    case rejected(RemoteHarnessFailure)
    case failed(RemoteHarnessError)
    case outcomeUnknown
}
public enum RemoteHarnessStreamUpdate: Sendable, Equatable, NativeConnectionPrivateValue {
    /// nil is an omitted upstream value (JavaScript undefined). Explicit JSON
    /// null is a nonnil RemoteHarnessJSON retaining the exact `null` bytes.
    case value(RemoteHarnessJSON?)
    case closed(RemoteHarnessCloseReason, RemoteHarnessFailure?)
    case failed(RemoteHarnessError)
}
public enum RemoteHarnessStopState: String, Sendable { case notRequested, requested, receiptReceived, confirmedStopped, outcomeUnknown }
public struct RemoteHarnessPendingApproval: Sendable, Equatable, NativeConnectionPrivateValue {
    public let clientID: String
    public let eventID: String
    public let binding: RemoteHarnessBinding
    /// Preserves tool arguments, nested data, and unknown fields. Upstream does
    /// not establish run/digest/expiry binding, so it cannot authorize either decision.
    public let request: RemoteHarnessJSON
}

/// Serialized deterministic carrier. The adapter must call expireDeadlines on
/// its injected scheduler at or before the monotonic nextDeadline, and on channel loss call
/// disconnect. There are no retries, reconnects, transfer fallbacks or UI entry.
@MainActor public final class RemoteHarnessCoordinator: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public nonisolated var description: String { "RemoteHarnessCoordinator(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
    public typealias Completion = @MainActor (RemoteHarnessCompletion) -> Void
    public typealias StreamReceiver = @MainActor (RemoteHarnessStreamUpdate) -> Void
    private struct Pending {
        let operation: RemoteHarnessOperation
        let commandID: String?
        let deadline: Int64
        let ordinal: UInt64
        let completion: Completion
        var dispatched: Bool
    }
    private struct Stream {
        let endpoint: String
        let binding: RemoteHarnessBinding
        let receive: StreamReceiver
        var closing: Bool
    }
    private let port: any RemoteHarnessBusinessPort
    private let clock: any RemoteHarnessClock
    private let journal: any RemoteHarnessCommandJournal
    private let codec = RemoteHarnessCodec()
    private var pending: [String: Pending] = [:]
    private var streams: [String: Stream] = [:]
    private var usedStreams = Set<String>()
    private var ordinal: UInt64 = 0
    private var streamOrdinal: UInt64 = 0
    private var maximumGeneration: UInt64 = 0
    private var everConnected = false
    private var negotiated = false
    private var recoveryRequired = false
    private var eventClientID: String?
    private var approvals: [String: RemoteHarnessPendingApproval] = [:]
    private var stopOrdinal: UInt64?
    public private(set) var binding: RemoteHarnessBinding?
    public private(set) var stopState: RemoteHarnessStopState = .notRequested
    public var pendingApprovalRequests: [RemoteHarnessPendingApproval] { approvals.keys.sorted().compactMap { approvals[$0] } }
    public var pendingRPCCount: Int { pending.count }
    /// Reserved Host slots, including local listeners awaiting close confirmation.
    public var activeStreamCount: Int { streams.count }
    public var nextDeadline: Int64? { pending.values.map(\.deadline).min() }

    public init(port: any RemoteHarnessBusinessPort, clock: any RemoteHarnessClock, journal: any RemoteHarnessCommandJournal) {
        self.port = port; self.clock = clock; self.journal = journal
    }
    public func connect(authenticatedBinding: RemoteHarnessBinding) throws {
        guard authenticatedBinding.generation > maximumGeneration else { throw RemoteHarnessError.bindingMismatch }
        // Reserve before retirement: port/journal/completion callbacks may
        // synchronously connect a newer generation while disconnect unwinds.
        // Neither this attempt nor a nested attempt can lower the watermark.
        maximumGeneration = authenticatedBinding.generation
        if binding != nil { disconnect() }
        guard maximumGeneration == authenticatedBinding.generation, binding == nil else { throw RemoteHarnessError.bindingMismatch }
        binding = authenticatedBinding; negotiated = false; recoveryRequired = everConnected; everConnected = true
        ordinal = 0; streamOrdinal = 0; usedStreams.removeAll(); stopOrdinal = nil; stopState = .notRequested
    }
    public func nextStreamID() throws -> String {
        guard let binding else { throw RemoteHarnessError.disconnected }
        guard streamOrdinal < 4_096 else { throw RemoteHarnessError.limitExceeded }
        streamOrdinal += 1
        return "stream-\(binding.generation)-\(streamOrdinal)"
    }

    @discardableResult public func perform(_ operation: RemoteHarnessOperation, commandID: String? = nil,
                                          onStream: StreamReceiver? = nil, completion: @escaping Completion) throws -> String {
        expireDeadlines()
        guard let binding else { throw RemoteHarnessError.disconnected }
        guard negotiated || operation.method == .describe else { throw RemoteHarnessError.unsupportedCapability }
        guard pending.count < RemoteHarnessLimits.pendingRPCs, ordinal < 4_096 else { throw RemoteHarnessError.limitExceeded }
        if let sessionID = operation.sessionID { guard binding.sessionID == sessionID else { throw RemoteHarnessError.bindingMismatch } }
        if let workspaceID = operation.workspaceID { guard binding.workspaceID == workspaceID else { throw RemoteHarnessError.bindingMismatch } }
        // Upstream clientId/eventId do not establish trusted Host/workspace/
        // session/run/digest/expiry binding. Both approval decisions remain
        // encoding-only until a negotiated Host extension establishes it.
        if operation.endpoint == "$events/result" { throw RemoteHarnessError.approvalBindingUnavailable }
        if operation.isMutation { guard let commandID, !commandID.isEmpty, commandID.utf8.count <= 1_024 else { throw RemoteHarnessError.invalidMessage } }
        else if commandID != nil { throw RemoteHarnessError.invalidMessage }
        if let promptID = operation.promptCommandID { guard promptID == commandID else { throw RemoteHarnessError.bindingMismatch } }
        if operation.method == .open {
            guard !recoveryRequired else { throw RemoteHarnessError.recoveryRequired }
            guard let streamID = operation.streamID, let endpoint = operation.endpoint, onStream != nil,
                  !usedStreams.contains(streamID), streams.count < RemoteHarnessLimits.streams,
                  usedStreams.count < 4_096, !streamID.isEmpty else { throw RemoteHarnessError.limitExceeded }
            // Generation-prefixed IDs prevent an old stream ID being restored on
            // a new channel. Builders remain independently usable for fixtures.
            guard streamID.hasPrefix("stream-\(binding.generation)-") else { throw RemoteHarnessError.bindingMismatch }
            _ = endpoint
        }
        if operation.method == .close {
            guard let streamID = operation.streamID, let stream = streams[streamID], stream.binding == binding,
                  !stream.closing else { throw RemoteHarnessError.bindingMismatch }
        }
        let now = clock.nowEpochMilliseconds
        let monotonicNow = clock.monotonicMilliseconds
        guard now > 0, now <= NativeConnectionBounds.counter, monotonicNow >= 0,
              monotonicNow <= Int64.max - RemoteHarnessLimits.deadlineMilliseconds else { throw RemoteHarnessError.invalidMessage }
        ordinal += 1
        let requestOrdinal = ordinal
        let rpcID = "rpc-\(binding.generation)-\(requestOrdinal)"
        let bytes = try codec.encodeRequest(id: rpcID, timestamp: now, operation: operation)
        // Reserve the bounded RPC slot before invoking the injected journal.
        // Even a synchronously reentrant journal cannot overbook pending work.
        pending[rpcID] = Pending(operation: operation, commandID: commandID, deadline: monotonicNow + RemoteHarnessLimits.deadlineMilliseconds, ordinal: requestOrdinal, completion: completion, dispatched: false)
        if let commandID {
            let command = RemoteHarnessJournalCommand(commandID: commandID, rpcID: rpcID, binding: binding, operation: operation, preparedAtEpochMilliseconds: now)
            do { try journal.persistBeforeDispatch(command) }
            catch RemoteHarnessError.duplicateCommand { pending.removeValue(forKey: rpcID); throw RemoteHarnessError.duplicateCommand }
            catch { pending.removeValue(forKey: rpcID); throw RemoteHarnessError.journalUnavailable }
        }
        try requireDispatchable(rpcID, binding: binding)
        // The listener exists BEFORE handing stream.open to the port.
        if operation.method == .open, let streamID = operation.streamID, let endpoint = operation.endpoint, let onStream {
            streams[streamID] = Stream(endpoint: endpoint, binding: binding, receive: onStream, closing: false); usedStreams.insert(streamID)
        }
        if operation.method == .close, let streamID = operation.streamID {
            let stream = streams[streamID]
            // Removing the visible listener cannot release the Host's slot.
            // Keep the reservation until an authoritative close or retirement.
            streams[streamID]?.closing = true
            if stream?.endpoint == "$events" { clearApprovals() }
            stream?.receive(.closed(.cancelled, nil))
        }
        if operation.endpoint == "session/cancel" { stopOrdinal = requestOrdinal; stopState = .requested }
        try requireDispatchable(rpcID, binding: binding)
        pending[rpcID]?.dispatched = true
        do { try port.send(bytes, binding: binding) }
        catch {
            // A transport may throw after accepting bytes; never infer unsent.
            retireConnection(reason: .disconnected, expectedBinding: binding)
        }
        return rpcID
    }

    public func receive(_ data: Data, authenticatedBinding: RemoteHarnessBinding) throws {
        guard binding == authenticatedBinding else { return }
        expireDeadlines()
        guard binding == authenticatedBinding else { return }
        var completing: Pending?
        do {
            let message = try codec.decode(data)
            switch message.body {
            case .response(let requestID, let result):
                guard let request = pending[requestID], request.dispatched else { return }
                pending.removeValue(forKey: requestID)
                completing = request
                try complete(request, result: result)
                completing = nil
            case .error(let requestID, let failure):
                guard let request = pending[requestID], request.dispatched else { return }
                pending.removeValue(forKey: requestID)
                // RESPONSE_TOO_LARGE can be raised AFTER a mutation executes.
                // No transfer fallback or retry is safe at this boundary.
                if request.commandID != nil { settle(request, outcome: .outcomeUnknown, completion: .outcomeUnknown) }
                else { request.completion(.rejected(failure)) }
                if request.operation.method == .open || request.operation.method == .close {
                    retireConnection(reason: .disconnected, expectedBinding: authenticatedBinding)
                }
            case .event(let name, let data, _, let sessionID):
                if let sessionID, authenticatedBinding.sessionID != sessionID { return }
                try route(name: name, data: data, binding: authenticatedBinding)
            case .request: throw RemoteHarnessError.invalidMessage
            }
        } catch {
            retireConnection(reason: (error as? RemoteHarnessError) ?? .invalidMessage, expectedBinding: authenticatedBinding, additional: completing)
            throw (error as? RemoteHarnessError) ?? .invalidMessage
        }
    }

    public func expireDeadlines() {
        guard let expectedBinding = binding else { return }
        let now = clock.monotonicMilliseconds
        guard binding == expectedBinding, pending.values.contains(where: { now >= $0.deadline }) else { return }
        // Retiring the channel also releases Host stream slots whose open ack
        // timed out. Nothing is resent; other sent mutations remain uncertain.
        retireConnection(reason: .deadlineExceeded, expectedBinding: expectedBinding)
    }
    public func disconnect() { retireConnection(reason: .disconnected) }

    private func requireDispatchable(_ rpcID: String, binding expectedBinding: RemoteHarnessBinding) throws {
        guard binding == expectedBinding, let request = pending[rpcID] else { throw RemoteHarnessError.disconnected }
        // Durable storage can synchronously consume the entire request budget.
        // Recheck immediately after it returns and again at the send boundary.
        let now = clock.monotonicMilliseconds
        guard binding == expectedBinding, pending[rpcID] != nil else { throw RemoteHarnessError.disconnected }
        guard now < request.deadline else {
            retireConnection(reason: .deadlineExceeded, expectedBinding: expectedBinding)
            throw RemoteHarnessError.deadlineExceeded
        }
    }

    private func complete(_ request: Pending, result: RemoteHarnessJSON) throws {
        let operation = request.operation
        switch operation.method {
        case .describe:
            let fields = try result.fields()
            let capabilities = try fields.required("capabilities").elements().map { try $0.stringValue() }
            guard Set(capabilities).count == capabilities.count else { throw RemoteHarnessError.invalidMessage }
            guard !(capabilities.contains("harness.remote.v1") && capabilities.contains("harness.remote.v3")) else { throw RemoteHarnessError.conflictingCapabilities }
            guard capabilities.contains("harness.remote.v3") else { throw RemoteHarnessError.unsupportedCapability }
            negotiated = true; request.completion(.response(result))
        case .open, .close:
            let fields = try result.fields()
            let key = operation.method == .open ? "opened" : "closed"
            let acknowledged = try fields.required(key).booleanValue()
            guard try fields.text("streamId") == operation.streamID,
                  operation.method == .close || acknowledged else { throw RemoteHarnessError.invalidMessage }
            // The pinned Host returns closed:false when the stream already
            // ended before close handling. Either Boolean confirms absence.
            if operation.method == .close, let streamID = operation.streamID { streams.removeValue(forKey: streamID) }
            request.completion(.response(result))
        case .call:
            switch try RemoteHarnessGatewayResult(result) {
            case .failure(let failure): settle(request, outcome: .rejected, completion: .rejected(failure))
            case .success(let value):
                if operation.endpoint == "session/cancel" {
                    guard let value, try value.fields().required("accepted").booleanValue() else { throw RemoteHarnessError.invalidMessage }
                    if request.ordinal == stopOrdinal, stopState != .confirmedStopped { stopState = .receiptReceived }
                }
                if operation.endpoint == "session/list" {
                    guard let value else { throw RemoteHarnessError.invalidMessage }
                    let items = try value.fields().required("items").elements()
                    recoveryRequired = false
                    if let stoppedAfter = stopOrdinal, request.ordinal > stoppedAfter, let sessionID = binding?.sessionID {
                        for item in items {
                            let fields = try item.fields()
                            if try fields.text("sessionId") == sessionID, try !fields.required("running").booleanValue() { stopState = .confirmedStopped }
                        }
                    }
                }
                settle(request, outcome: .responseReceived, completion: .response(value))
            }
        }
    }
    private func settle(_ request: Pending, outcome: RemoteHarnessJournalOutcome, completion: RemoteHarnessCompletion) {
        if let commandID = request.commandID {
            do { try journal.recordOutcome(commandID: commandID, outcome: outcome) }
            catch { request.completion(.outcomeUnknown); return }
        }
        request.completion(completion)
    }
    private func route(name: String, data: RemoteHarnessJSON, binding: RemoteHarnessBinding) throws {
        guard name == "harness.remote.frame" || name == "harness.remote.stream.closed" else { return }
        let fields = try data.fields(), streamID = try fields.text("streamId")
        guard let stream = streams[streamID], stream.binding == binding else { return }
        if name == "harness.remote.frame" {
            guard !stream.closing else { return }
            try fields.requireKeys(["streamId", "hasValue"], optional: ["value"])
            guard try fields.required("hasValue").booleanValue() else { throw RemoteHarnessError.invalidMessage }
            let value = fields["value"]
            if stream.endpoint == "$events", let value { try routeApproval(value, binding: binding) }
            stream.receive(.value(value))
        } else {
            try fields.requireKeys(["streamId", "reason"], optional: ["failure"])
            guard let reason = RemoteHarnessCloseReason(rawValue: try fields.text("reason")) else { throw RemoteHarnessError.invalidMessage }
            let failure = try fields["failure"].map { try RemoteHarnessFailure($0) }
            streams.removeValue(forKey: streamID)
            if stream.endpoint == "$events" { clearApprovals() }
            if !stream.closing { stream.receive(.closed(reason, failure)) }
        }
    }
    private func routeApproval(_ value: RemoteHarnessJSON, binding: RemoteHarnessBinding) throws {
        // The upstream event router ignores non-record/unknown values. Keep
        // forwarding their exact bytes without treating JSON null as a request.
        guard let fields = try? value.fields(), let rawType = fields["type"],
              let type = try? rawType.stringValue() else { return }
        if type == "ready" { clearApprovals(); eventClientID = try fields.text("clientId"); return }
        if type == "cancel" { approvals.removeValue(forKey: try fields.text("eventId")); return }
        guard type == "waterfall", try fields["event"]?.stringValue() == "approval/request" else { return }
        guard let clientID = eventClientID, try fields.text("agentId") == binding.sessionID else { return }
        let eventID = try fields.text("eventId"), request = try fields.required("request")
        _ = try request.fields()
        guard approvals[eventID] == nil, approvals.count < 16 else { throw RemoteHarnessError.limitExceeded }
        approvals[eventID] = RemoteHarnessPendingApproval(clientID: clientID, eventID: eventID, binding: binding, request: request)
    }
    private func clearApprovals() { eventClientID = nil; approvals.removeAll() }
    private func retireConnection(reason: RemoteHarnessError, expectedBinding: RemoteHarnessBinding? = nil, additional: Pending? = nil) {
        guard let previousBinding = binding else { return }
        if let expectedBinding, previousBinding != expectedBinding { return }
        binding = nil; negotiated = false; clearApprovals()
        let requests = (Array(pending.values) + (additional.map { [$0] } ?? [])).sorted { $0.ordinal < $1.ordinal }
        let liveStreams = streams.keys.sorted().compactMap { streams[$0] }.filter { !$0.closing }
        pending.removeAll(); streams.removeAll()
        if stopState == .requested || stopState == .receiptReceived { stopState = .outcomeUnknown }
        port.invalidate(binding: previousBinding)
        for request in requests {
            if request.commandID != nil, request.dispatched { settle(request, outcome: .outcomeUnknown, completion: .outcomeUnknown) }
            else if request.commandID != nil { settle(request, outcome: .notDispatched, completion: .failed(reason)) }
            else { request.completion(.failed(reason)) }
        }
        for stream in liveStreams { stream.receive(.failed(reason)) }
    }
}
