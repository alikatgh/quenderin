import Foundation

/// Supplied by an authenticated channel adapter, never read from message payloads.
/// Nil workspace/session explicitly denotes a discovery scope, not a wildcard for
/// dispatching session or workspace mutations.
public struct RemoteHarnessBinding: Sendable, Equatable, NativeConnectionPrivateValue {
    public let generation: UInt64
    public let hostID: String
    public let workspaceID: String?
    public let sessionID: String?
    public let clientDeviceID: String?
    public init(generation: UInt64, hostID: String, workspaceID: String? = nil, sessionID: String? = nil, clientDeviceID: String? = nil) throws {
        guard generation > 0, !hostID.isEmpty, hostID.utf8.count <= 1_024,
              workspaceID == nil || !(workspaceID?.isEmpty ?? true), sessionID == nil || workspaceID != nil,
              sessionID == nil || !(sessionID?.isEmpty ?? true), (workspaceID?.utf8.count ?? 0) <= 1_024,
              (sessionID?.utf8.count ?? 0) <= 1_024,
              clientDeviceID == nil || !(clientDeviceID?.isEmpty ?? true), (clientDeviceID?.utf8.count ?? 0) <= 1_024 else { throw RemoteHarnessError.bindingMismatch }
        self.generation = generation; self.hostID = hostID; self.workspaceID = workspaceID; self.sessionID = sessionID
        self.clientDeviceID = clientDeviceID
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
    public let extensionBinding: RemoteHarnessApprovalBinding?
    /// Authenticated Host carrier timestamp, never the phone's wall clock.
    public let hostTimestamp: Int64
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
    private var approvalExtension = false
    private var botReadExtension = false
    private var botReadDescribeOrdinal: UInt64?
    private var activeRunID: String?
    private var recoveryRequired = false
    private var eventClientID: String?
    private var approvals: [String: RemoteHarnessPendingApproval] = [:]
    private var seenApprovalIDs = Set<String>()
    private var approvalDeadlines: [String: Int64] = [:]
    private var stopOrdinal: UInt64?
    public private(set) var binding: RemoteHarnessBinding?
    public private(set) var stopState: RemoteHarnessStopState = .notRequested
    public var pendingApprovalRequests: [RemoteHarnessPendingApproval] { approvals.keys.sorted().compactMap { approvals[$0] } }
    public var pendingRPCCount: Int { pending.count }
    /// The feature requires an authenticated workspace as well as both Host capabilities.
    public var supportsBotRead: Bool { botReadExtension && binding?.workspaceID != nil }
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
        botReadExtension = false; botReadDescribeOrdinal = nil
        activeRunID = nil
        seenApprovalIDs.removeAll(); approvalDeadlines.removeAll()
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
        if operation.method == .pluginRouteCall {
            guard botReadExtension else { throw RemoteHarnessError.unsupportedCapability }
            guard let workspaceID = binding.workspaceID, let requested = operation.workspaceID,
                  workspaceID.utf8.elementsEqual(requested.utf8) else { throw RemoteHarnessError.bindingMismatch }
            try RemoteHarnessBotReadContract.workspace(workspaceID)
        }
        // Upstream clientId/eventId do not establish trusted Host/workspace/
        // session/run/digest/expiry binding. Both approval decisions remain
        // encoding-only until a negotiated Host extension establishes it.
        if operation.endpoint == "$events/result" { throw RemoteHarnessError.approvalBindingUnavailable }
        if operation.endpoint == "quenderin/approval" {
            guard approvalExtension, let eventID = operation.approvalEventID, let pending = approvals[eventID],
                  let clientID = operation.approvalClientID, pending.clientID.utf8.elementsEqual(clientID.utf8), let extended = operation.approvalBinding,
                  let original = pending.extensionBinding, extended.exactlyMatches(original), extended.runID == activeRunID,
                  let expiry = approvalDeadlines[eventID], clock.monotonicMilliseconds >= 0, clock.monotonicMilliseconds < expiry,
                  extended.matches(binding, referenceTime: pending.hostTimestamp) else { throw RemoteHarnessError.approvalBindingUnavailable }
            // Consume locally before any journal/port callback can reenter.
            approvals.removeValue(forKey: eventID)
            approvalDeadlines.removeValue(forKey: eventID)
        }
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
        if operation.method == .describe {
            // Renegotiation suspends this extension immediately. Out-of-order
            // replies to earlier describes cannot restore obsolete capabilities.
            botReadExtension = false; botReadDescribeOrdinal = requestOrdinal
        }
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

    /// Typed read convenience. All correlation, deadlines and capacity remain in
    /// perform; the read cannot reserve a journal command or be replayed.
    @discardableResult public func readBotRoster(
        completion: @escaping @MainActor (Result<RemoteHarnessBotRoster, RemoteHarnessError>) -> Void
    ) throws -> String {
        guard let binding else { throw RemoteHarnessError.disconnected }
        guard let workspaceID = binding.workspaceID else { throw RemoteHarnessError.bindingMismatch }
        return try perform(.botRoster(workspaceID: workspaceID)) { result in
            switch result {
            case .response(let raw?):
                do { completion(.success(try RemoteHarnessBotRoster(routeResult: raw, expectedWorkspaceID: workspaceID))) }
                catch { completion(.failure((error as? RemoteHarnessError) ?? .invalidMessage)) }
            case .failed(let error): completion(.failure(error))
            case .response(nil), .rejected, .outcomeUnknown: completion(.failure(.invalidMessage))
            }
        }
    }

    public func receive(_ data: Data, authenticatedBinding: RemoteHarnessBinding) throws {
        // Swift String equality canonicalizes Unicode. Check authenticated bytes
        // before parsing or expiring work so a different binding cannot retire it.
        guard bindingMatchesExactly(authenticatedBinding) else { return }
        expireDeadlines()
        guard bindingMatchesExactly(authenticatedBinding) else { return }
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
                else if request.operation.method == .pluginRouteCall { request.completion(.failed(.invalidMessage)) }
                else { request.completion(.rejected(failure)) }
                if request.operation.method == .open || request.operation.method == .close {
                    retireConnection(reason: .disconnected, expectedBinding: authenticatedBinding)
                }
            case .event(let name, let data, _, let sessionID):
                if let sessionID, authenticatedBinding.sessionID != sessionID { return }
                try route(name: name, data: data, binding: authenticatedBinding, timestamp: message.timestamp)
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
        for (id, deadline) in approvalDeadlines where now < 0 || now >= deadline { approvalDeadlines.removeValue(forKey: id); approvals.removeValue(forKey: id) }
        guard bindingMatchesExactly(expectedBinding), pending.values.contains(where: { now >= $0.deadline }) else { return }
        // Retiring the channel also releases Host stream slots whose open ack
        // timed out. Nothing is resent; other sent mutations remain uncertain.
        retireConnection(reason: .deadlineExceeded, expectedBinding: expectedBinding)
    }
    public func disconnect() { retireConnection(reason: .disconnected) }

    private func requireDispatchable(_ rpcID: String, binding expectedBinding: RemoteHarnessBinding) throws {
        guard bindingMatchesExactly(expectedBinding), let request = pending[rpcID] else { throw RemoteHarnessError.disconnected }
        // Durable storage can synchronously consume the entire request budget.
        // Recheck immediately after it returns and again at the send boundary.
        let now = clock.monotonicMilliseconds
        guard bindingMatchesExactly(expectedBinding), pending[rpcID] != nil else { throw RemoteHarnessError.disconnected }
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
            approvalExtension = capabilities.contains("quenderin.approvals.v1")
            if request.ordinal == botReadDescribeOrdinal {
                botReadExtension = capabilities.contains(RemoteHarnessBotReadContract.carrierCapability)
                    && capabilities.contains(RemoteHarnessBotReadContract.capability)
            }
            negotiated = true; request.completion(.response(result))
        case .pluginRouteCall:
            do {
                guard let workspaceID = operation.workspaceID, let current = binding?.workspaceID,
                      current.utf8.elementsEqual(workspaceID.utf8) else { throw RemoteHarnessError.bindingMismatch }
                _ = try RemoteHarnessBotRoster(routeResult: result, expectedWorkspaceID: workspaceID)
            } catch {
                // A bounded route failure cannot change session, Stop, approval
                // or journal state by retiring their otherwise valid channel.
                request.completion(.failed((error as? RemoteHarnessError) ?? .invalidMessage))
                return
            }
            // Keep the existing completion vocabulary; this raw route result is
            // validated above and never passed through RemoteHarnessGatewayResult.
            request.completion(.response(result))
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
    private func route(name: String, data: RemoteHarnessJSON, binding: RemoteHarnessBinding, timestamp: Int64) throws {
        guard name == "harness.remote.frame" || name == "harness.remote.stream.closed" else { return }
        let fields = try data.fields(), streamID = try fields.text("streamId")
        guard let stream = streams[streamID], stream.binding == binding else { return }
        if name == "harness.remote.frame" {
            guard !stream.closing else { return }
            try fields.requireKeys(["streamId", "hasValue"], optional: ["value"])
            guard try fields.required("hasValue").booleanValue() else { throw RemoteHarnessError.invalidMessage }
            let value = fields["value"]
            if stream.endpoint == "session/follow", let value { try routeRun(value) }
            if stream.endpoint == "$events", let value { try routeApproval(value, binding: binding, timestamp: timestamp) }
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
    private func routeRun(_ value: RemoteHarnessJSON) throws {
        guard let fields = try? value.fields(), let type = try? fields.text("type") else { return }
        if type == "snapshot" {
            activeRunID = nil
            if let records = try? fields["records"]?.elements() {
                for record in records {
                    guard let item = try? record.fields(), (try? item.text("type")) == "event", let event = item["event"] else { continue }
                    try routeRun(.object(["type": .string("event"), "event": event]))
                }
            }
            if let stream = try? fields["assistantStream"]?.fields(), let active = try? stream["activeAttempt"]?.fields(),
               let turn = try? active.required("turn").integerValue() { activeRunID = "turn:\(turn)" }
            approvals.removeAll()
        } else if type == "event", let event = try? fields.required("event").fields(), let name = try? event.text("type") {
            if name == "turn/start", let data = try? event.required("data").fields(), let turn = try? data.required("turn").integerValue() {
                activeRunID = "turn:\(turn)"; approvals.removeAll()
            }
            if name == "turn/end" {
                activeRunID = nil; approvals.removeAll()
                if stopState == .requested || stopState == .receiptReceived { stopState = .confirmedStopped }
            }
        }
    }
    private func routeApproval(_ value: RemoteHarnessJSON, binding: RemoteHarnessBinding, timestamp: Int64) throws {
        // The upstream event router ignores non-record/unknown values. Keep
        // forwarding their exact bytes without treating JSON null as a request.
        guard let fields = try? value.fields(), let rawType = fields["type"],
              let type = try? rawType.stringValue() else { return }
        if type == "ready" { clearApprovals(); eventClientID = try fields.text("clientId"); return }
        if type == "cancel" { let id = try fields.text("eventId"); approvals.removeValue(forKey: id); approvalDeadlines.removeValue(forKey: id); return }
        guard type == "waterfall", try fields["event"]?.stringValue() == "approval/request" else { return }
        let eventID = try fields.text("eventId")
        // A replacement, including an unbound or differently scoped one,
        // invalidates the old action before any early return or parsing failure.
        approvals.removeValue(forKey: eventID); approvalDeadlines.removeValue(forKey: eventID)
        guard seenApprovalIDs.count < 4096 || seenApprovalIDs.contains(eventID) else { throw RemoteHarnessError.limitExceeded }
        let repeated = !seenApprovalIDs.insert(eventID).inserted
        guard let clientID = eventClientID, try fields.text("agentId") == binding.sessionID else { return }
        let request = try fields.required("request")
        _ = try request.fields()
        guard approvals.count < 16 else { throw RemoteHarnessError.limitExceeded }
        var extended: RemoteHarnessApprovalBinding?
        if approvalExtension, !repeated, let raw = fields["quenderinBinding"] {
            let parsed = try RemoteHarnessApprovalBinding(raw)
            guard parsed.eventID.utf8.elementsEqual(eventID.utf8), parsed.matches(binding, referenceTime: timestamp) else { throw RemoteHarnessError.bindingMismatch }
            // Independent streams may deliver a permission before its turn
            // baseline; keep it visible but require approval on the computer.
            if parsed.runID == activeRunID, let digest = try? RemoteHarnessApprovalDigest.digest(request), digest.utf8.elementsEqual(parsed.actionDigest.utf8) {
                let mono = clock.monotonicMilliseconds, delta = parsed.expiresAt - timestamp
                guard mono >= 0, mono <= Int64.max - delta else { throw RemoteHarnessError.invalidMessage }
                extended = parsed; approvalDeadlines[eventID] = mono + delta
            }
        }
        approvals[eventID] = RemoteHarnessPendingApproval(clientID: clientID, eventID: eventID, binding: binding, request: request, extensionBinding: extended, hostTimestamp: timestamp)
    }
    private func clearApprovals() { eventClientID = nil; approvals.removeAll(); approvalDeadlines.removeAll() }
    private func bindingMatchesExactly(_ expected: RemoteHarnessBinding) -> Bool {
        guard let current = binding else { return false }
        func exact(_ lhs: String?, _ rhs: String?) -> Bool {
            lhs.map { Data($0.utf8) } == rhs.map { Data($0.utf8) }
        }
        return current.generation == expected.generation && current.hostID.utf8.elementsEqual(expected.hostID.utf8)
            && exact(current.workspaceID, expected.workspaceID) && exact(current.sessionID, expected.sessionID)
            && exact(current.clientDeviceID, expected.clientDeviceID)
    }
    private func retireConnection(reason: RemoteHarnessError, expectedBinding: RemoteHarnessBinding? = nil, additional: Pending? = nil) {
        guard let previousBinding = binding else { return }
        if let expectedBinding, !bindingMatchesExactly(expectedBinding) { return }
        binding = nil; negotiated = false; approvalExtension = false; botReadExtension = false; botReadDescribeOrdinal = nil
        activeRunID = nil; clearApprovals()
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
