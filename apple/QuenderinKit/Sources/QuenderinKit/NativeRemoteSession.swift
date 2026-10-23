import Foundation

public enum RemoteSessionStatus: String, Sendable, NativeWireEnum {
    case disconnected, connecting, ready, running, awaitingApproval, stopRequested, stopped, outcomeUnknown
}
public enum RemoteCommandKind: String, Sendable, NativeWireEnum { case send, approve, deny, stop }
public enum RemoteCommandState: String, Sendable, NativeWireEnum { case prepared, sent, acknowledged, outcomeUnknown }
public enum RemoteApprovalDecision: Sendable, Equatable { case approve, deny }

public struct PendingRemoteCommand: Sendable, Equatable, NativeWireObject {
    public let requestID: String
    public let kind: RemoteCommandKind
    public private(set) var state: RemoteCommandState
    public init(requestID: String, kind: RemoteCommandKind, state: RemoteCommandState = .prepared) throws {
        try NativeConnectionBounds.identifier(requestID)
        self.requestID = requestID; self.kind = kind; self.state = state
    }
    fileprivate mutating func transition(to value: RemoteCommandState) { state = value }
    static let wireKeys: Set<String> = ["requestID", "kind", "state"]
    init(fields: NativeFields) throws { try self.init(requestID: fields.required("requestID"), kind: fields.required("kind"), state: fields.required("state")) }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("requestID", requestID); try values.put("kind", kind); try values.put("state", state)
    }
}

/// Correlation is explicit even when the transport reports a request ID it recognizes.
public struct RemoteEventIdentity: Sendable, Equatable {
    public let hostID: String
    public let deviceID: String
    public let workspaceID: String
    public let sessionID: String
    public let runID: String?
    public init(hostID: String, deviceID: String, workspaceID: String, sessionID: String, runID: String?) throws {
        for id in [hostID, deviceID, workspaceID, sessionID] { try NativeConnectionBounds.identifier(id) }
        if let runID { try NativeConnectionBounds.identifier(runID) }
        self.hostID = hostID; self.deviceID = deviceID; self.workspaceID = workspaceID; self.sessionID = sessionID; self.runID = runID
    }
}

public struct RemoteApproval: Sendable, Equatable, NativeWireObject {
    public let approvalID: String
    public let requestID: String
    public let hostID: String
    public let deviceID: String
    public let workspaceID: String
    public let sessionID: String
    public let runID: String
    public let actionDigest: String
    public let expiresAtEpochMs: Int64
    public init(approvalID: String, requestID: String, hostID: String, deviceID: String, workspaceID: String,
                sessionID: String, runID: String, actionDigest: String, expiresAtEpochMs: Int64) throws {
        for id in [approvalID, requestID, hostID, deviceID, workspaceID, sessionID, runID] { try NativeConnectionBounds.identifier(id) }
        try NativeConnectionBounds.digest(actionDigest); try NativeConnectionBounds.counter(expiresAtEpochMs)
        self.approvalID = approvalID; self.requestID = requestID; self.hostID = hostID; self.deviceID = deviceID
        self.workspaceID = workspaceID; self.sessionID = sessionID; self.runID = runID
        self.actionDigest = actionDigest; self.expiresAtEpochMs = expiresAtEpochMs
    }
    public var identity: RemoteEventIdentity {
        // All components have already passed the same identifier validation.
        RemoteEventIdentity(validatedApproval: self)
    }
    static let wireKeys: Set<String> = ["approvalID", "requestID", "hostID", "deviceID", "workspaceID", "sessionID", "runID", "actionDigest", "expiresAtEpochMs"]
    init(fields: NativeFields) throws {
        try self.init(approvalID: fields.required("approvalID"), requestID: fields.required("requestID"), hostID: fields.required("hostID"),
                      deviceID: fields.required("deviceID"), workspaceID: fields.required("workspaceID"), sessionID: fields.required("sessionID"),
                      runID: fields.required("runID"), actionDigest: fields.required("actionDigest"), expiresAtEpochMs: fields.required("expiresAtEpochMs"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("approvalID", approvalID); try values.put("requestID", requestID); try values.put("hostID", hostID)
        try values.put("deviceID", deviceID); try values.put("workspaceID", workspaceID); try values.put("sessionID", sessionID)
        try values.put("runID", runID); try values.put("actionDigest", actionDigest); try values.put("expiresAtEpochMs", expiresAtEpochMs)
    }
}

extension RemoteEventIdentity {
    fileprivate init(validatedApproval approval: RemoteApproval) {
        hostID = approval.hostID; deviceID = approval.deviceID; workspaceID = approval.workspaceID
        sessionID = approval.sessionID; runID = approval.runID
    }
    fileprivate init(validatedSession session: RemoteSessionState) {
        hostID = session.hostID; deviceID = session.deviceID; workspaceID = session.workspaceID
        sessionID = session.sessionID; runID = session.runID
    }
}

/// A bounded local ledger, not a transport or a claim of authoritative Host enforcement.
/// Mutations are never replayed automatically. A consumed approval is removed before its
/// decision can be sent; restoring the resulting envelope preserves that removal.
public struct RemoteSessionState: Sendable, Equatable, NativeWireObject {
    public let hostID: String
    public let deviceID: String
    public let workspaceID: String
    public let sessionID: String
    public let runID: String?
    public private(set) var lastConfirmedEventID: String?
    public private(set) var status: RemoteSessionStatus
    public private(set) var pendingCommands: [PendingRemoteCommand]
    public private(set) var pendingApprovals: [RemoteApproval]

    public init(hostID: String, deviceID: String, workspaceID: String, sessionID: String, runID: String? = nil,
                lastConfirmedEventID: String? = nil, status: RemoteSessionStatus = .disconnected,
                pendingCommands: [PendingRemoteCommand] = [], pendingApprovals: [RemoteApproval] = []) throws {
        for id in [hostID, deviceID, workspaceID, sessionID] { try NativeConnectionBounds.identifier(id) }
        if let runID { try NativeConnectionBounds.identifier(runID) }
        if let lastConfirmedEventID { try Self.validateEventID(lastConfirmedEventID) }
        guard pendingCommands.count <= NativeConnectionBounds.pending, pendingApprovals.count <= NativeConnectionBounds.pending
        else { throw NativeConnectionError.limitExceeded }
        try NativeConnectionBounds.unique(pendingCommands.map(\.requestID))
        try NativeConnectionBounds.unique(pendingApprovals.map(\.approvalID))
        for approval in pendingApprovals {
            guard approval.hostID == hostID, approval.deviceID == deviceID, approval.workspaceID == workspaceID,
                  approval.sessionID == sessionID, approval.runID == runID else { throw NativeConnectionError.sessionMismatch }
        }
        self.hostID = hostID; self.deviceID = deviceID; self.workspaceID = workspaceID; self.sessionID = sessionID; self.runID = runID
        self.lastConfirmedEventID = lastConfirmedEventID; self.status = status
        self.pendingCommands = pendingCommands; self.pendingApprovals = pendingApprovals
    }

    public var identity: RemoteEventIdentity { RemoteEventIdentity(validatedSession: self) }

    /// Approval commands can only be prepared by consuming their exact approval below.
    public mutating func prepareCommand(requestID: String, kind: RemoteCommandKind) throws {
        guard status == .ready || status == .running || status == .awaitingApproval
        else { throw NativeConnectionError.invalidTransition }
        guard kind == .send || kind == .stop else { throw NativeConnectionError.invalidTransition }
        let command = try PendingRemoteCommand(requestID: requestID, kind: kind)
        try requireNewCommand(command)
        pendingCommands.append(command)
        if kind == .stop { status = .stopRequested }
    }

    /// Marks the explicit point where a caller handed a previously prepared mutation to
    /// its transport. Unknown/sent commands cannot be sent again with this API.
    public mutating func markSent(requestID: String) throws {
        guard let index = pendingCommands.firstIndex(where: { $0.requestID == requestID }) else { throw NativeConnectionError.unknownCommand }
        guard pendingCommands[index].state == .prepared else { throw NativeConnectionError.invalidTransition }
        guard status == .ready || status == .running || status == .awaitingApproval || status == .stopRequested,
              status != .stopRequested || pendingCommands[index].kind == .stop
        else { throw NativeConnectionError.invalidTransition }
        pendingCommands[index].transition(to: .sent)
        if pendingCommands[index].kind == .stop { status = .stopRequested }
        else { status = pendingApprovals.isEmpty ? .running : .awaitingApproval }
    }

    /// A receipt is not a completed action. Only a matching stop acknowledgement establishes
    /// stopped state. A delayed acknowledgement may settle a previously unknown receipt.
    public mutating func acknowledge(requestID: String, identity: RemoteEventIdentity, eventID: String? = nil) throws {
        try requireIdentity(identity)
        if let eventID { try Self.validateEventID(eventID) }
        guard let index = pendingCommands.firstIndex(where: { $0.requestID == requestID }) else { throw NativeConnectionError.unknownCommand }
        guard pendingCommands[index].state == .sent || pendingCommands[index].state == .outcomeUnknown
        else { throw NativeConnectionError.invalidTransition }
        pendingCommands[index].transition(to: .acknowledged)
        if let eventID { lastConfirmedEventID = eventID }
        if pendingCommands[index].kind == .stop { status = .stopped }
    }

    public mutating func recordConfirmedEvent(_ eventID: String, identity: RemoteEventIdentity) throws {
        try requireIdentity(identity); try Self.validateEventID(eventID)
        lastConfirmedEventID = eventID
    }

    public mutating func connectionLost() {
        let wasStopped = status == .stopped
        let uncertain = status == .running || status == .awaitingApproval || status == .stopRequested || status == .outcomeUnknown
        for index in pendingCommands.indices where pendingCommands[index].state == .sent {
            pendingCommands[index].transition(to: .outcomeUnknown)
        }
        if wasStopped { return }
        if uncertain || pendingCommands.contains(where: { $0.state == .outcomeUnknown }) {
            status = .outcomeUnknown
        } else if status != .stopped { status = .disconnected }
    }

    /// The caller supplies the exact prompt it displayed, including request/session/run and
    /// action digest. Time is supplied explicitly: parsing an old envelope never approves it.
    /// Removal and command preparation happen atomically only after ALL checks succeed.
    public mutating func consumeApproval(_ expected: RemoteApproval, decision: RemoteApprovalDecision,
                                         decisionRequestID: String, nowEpochMs: Int64) throws {
        try NativeConnectionBounds.counter(nowEpochMs)
        guard status == .awaitingApproval else { throw NativeConnectionError.invalidTransition }
        guard let index = pendingApprovals.firstIndex(where: { $0.approvalID == expected.approvalID })
        else { throw NativeConnectionError.approvalUnavailable }
        let approval = pendingApprovals[index]
        guard approval == expected else { throw NativeConnectionError.sessionMismatch }
        try requireIdentity(approval.identity)
        guard nowEpochMs < approval.expiresAtEpochMs else { throw NativeConnectionError.approvalExpired }
        let command = try PendingRemoteCommand(requestID: decisionRequestID, kind: decision == .approve ? .approve : .deny)
        try requireNewCommand(command)
        pendingApprovals.remove(at: index)
        pendingCommands.append(command)
    }

    private func requireIdentity(_ candidate: RemoteEventIdentity) throws {
        guard candidate == identity else { throw NativeConnectionError.sessionMismatch }
    }
    private func requireNewCommand(_ command: PendingRemoteCommand) throws {
        guard pendingCommands.count < NativeConnectionBounds.pending else { throw NativeConnectionError.limitExceeded }
        guard !pendingCommands.contains(where: { $0.requestID == command.requestID }) else { throw NativeConnectionError.invalidTransition }
    }
    private static func validateEventID(_ value: String) throws {
        try NativeConnectionBounds.text(value)
        guard !value.isEmpty else { throw NativeConnectionError.invalidValue }
    }
    static let wireKeys: Set<String> = ["hostID", "deviceID", "workspaceID", "sessionID", "runID", "lastConfirmedEventID", "status", "pendingCommands", "pendingApprovals"]
    init(fields: NativeFields) throws {
        try self.init(hostID: fields.required("hostID"), deviceID: fields.required("deviceID"), workspaceID: fields.required("workspaceID"),
                      sessionID: fields.required("sessionID"), runID: fields.optional("runID"), lastConfirmedEventID: fields.optional("lastConfirmedEventID"),
                      status: fields.required("status"), pendingCommands: fields.required("pendingCommands"), pendingApprovals: fields.required("pendingApprovals"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("hostID", hostID); try values.put("deviceID", deviceID); try values.put("workspaceID", workspaceID); try values.put("sessionID", sessionID)
        try values.putOptional("runID", runID); try values.putOptional("lastConfirmedEventID", lastConfirmedEventID); try values.put("status", status)
        try values.put("pendingCommands", pendingCommands); try values.put("pendingApprovals", pendingApprovals)
    }
}
