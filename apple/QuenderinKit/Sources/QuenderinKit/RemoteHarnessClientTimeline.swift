import Foundation

public struct RemoteHarnessClientWorkspace: Identifiable, NativeConnectionPrivateValue {
    public var id: String { workspaceID }
    public let workspaceID: String
    public let title: String
    public let path: String
    public let sessionIDs: [String]
    init(_ value: RemoteHarnessJSON) throws {
        let f = try value.fields(); workspaceID = try f.text("workspaceId"); title = try f.text("title"); path = try f.text("path")
        sessionIDs = try f.required("sessionIds").elements().map { try $0.stringValue() }
        guard sessionIDs.count <= 1024, Set(sessionIDs).count == sessionIDs.count else { throw RemoteHarnessClientFailure.protocolMismatch }
    }
}
public struct RemoteHarnessClientSession: Identifiable, NativeConnectionPrivateValue {
    public var id: String { sessionID }
    public let sessionID: String
    public let title: String
    public let running: Bool
    init(_ value: RemoteHarnessJSON) throws {
        let f = try value.fields(); sessionID = try f.text("sessionId"); title = try f["title"]?.stringValue() ?? "Untitled session"; running = try f.required("running").booleanValue()
        _ = try f.required("updatedAt").integerValue(); _ = try f.required("blank").booleanValue()
    }
}
public struct RemoteHarnessClientModel: Identifiable, NativeConnectionPrivateValue {
    public var id: String { provider + ":" + model }
    public let provider: String
    public let model: String
    public let name: String
    public let efforts: [String]
}
public struct RemoteHarnessClientTimelineRow: Identifiable, NativeConnectionPrivateValue {
    public let id: String
    public let title: String
    public let text: String
    public let kind: String
    public let raw: Data
}

/// Ephemeral execution evidence from one authoritative durable tool/call. This
/// is deliberately separate from approval/request metadata and journal data.
public struct RemoteHarnessClientApprovalAction: Sendable, Equatable, NativeConnectionPrivateValue {
    public let sessionID: String
    public let runID: String
    public let callID: String
    public let toolName: String
    public let arguments: String
    public let sequence: Int64
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence && zip([lhs.sessionID, lhs.runID, lhs.callID, lhs.toolName, lhs.arguments],
            [rhs.sessionID, rhs.runID, rhs.callID, rhs.toolName, rhs.arguments]).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
    }
}

/// Authoritative durable records and transient attempt/index frames keep separate
/// identities. Raw bounded records are retained for unknown fields and tool data.
public struct RemoteHarnessClientTimeline: NativeConnectionPrivateValue {
    public private(set) var records: [Data] = []
    public private(set) var rows: [RemoteHarnessClientTimelineRow] = []
    public private(set) var cursor: Int64?
    public private(set) var hasMore = false
    private var attempt: String?
    private var nextIndex: Int64 = 0
    private var revision: Int64 = 0
    private var transient: [RemoteHarnessClientTimelineRow] = []
    private var seenSequences = Set<Int64>()
    private var liveCursor: Int64?
    private enum CallEvidence { case unique(RemoteHarnessClientApprovalAction), ambiguous }
    private var actionSessionID: String?
    private var actionRunID: String?
    private var maximumActionTurn: Int64?
    private var calls: [String: CallEvidence] = [:]
    private var callCount = 0, callBytes = 0
    private var actionEvidenceInvalid = false
    static let maximumApprovalCalls = 128
    static let maximumApprovalArgumentBytes = 65_536
    static let maximumApprovalEvidenceBytes = 262_144
    public var hasActiveTurn: Bool { actionRunID != nil }
    public init() {}
    public mutating func restore(_ values: [Data]) throws {
        clearApprovalEvidence()
        attempt = nil; transient = []; revision = 0; nextIndex = 0; cursor = nil; liveCursor = nil; hasMore = false
        records = values; seenSequences = Set(values.compactMap { try? RemoteHarnessJSON(data: $0).fields().required("event").fields().required("seq").integerValue() })
        rows = Self.compact(try values.enumerated().flatMap { try Self.rows(RemoteHarnessJSON(data: $0.element), key: "saved-\($0.offset)") })
    }
    public mutating func receive(_ value: RemoteHarnessJSON, expectedSessionID: String) throws {
        let f = try value.fields(), type = try f.text("type")
        if type == "snapshot" {
            guard try f.required("header").fields().text("id").utf8.elementsEqual(expectedSessionID.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }
            let rawRecords = try f.required("records").elements()
            // The official Host uses -1 for a new session with no durable
            // events. Keep that sentinel local to the snapshot cursor: event
            // sequences, assistant indexes and revisions remain unsigned.
            let rawCursor = try f.required("cursor")
            let snapshotCursor: Int64 = rawCursor.data == Data("-1".utf8) ? -1 : try rawCursor.integerValue()
            var last: Int64?
            for record in rawRecords {
                let range = try Self.sequenceRange(record)
                guard range.upperBound <= snapshotCursor, last == nil || range.lowerBound > last! else { throw RemoteHarnessClientFailure.protocolMismatch }
                last = range.upperBound
            }
            records = rawRecords.map(\.data); cursor = snapshotCursor; liveCursor = snapshotCursor; hasMore = try f.required("hasMore").booleanValue()
            seenSequences = Set(rawRecords.compactMap { try? $0.fields().required("event").fields().required("seq").integerValue() })
            transient = []; attempt = nil
            revision = (try? f["assistantStream"]?.fields().required("revision").integerValue()) ?? 0
            if let stream = try? f["assistantStream"]?.fields(), let active = try? stream["activeAttempt"]?.fields() {
                attempt = try active.text("attemptId"); nextIndex = try active.required("nextIndex").integerValue()
                guard try active.required("startedAfterSeq").integerValue() <= snapshotCursor else { throw RemoteHarnessClientFailure.protocolMismatch }
                _ = try active.required("turn").integerValue(); _ = try active.required("step").integerValue()
                revision = try stream.required("revision").integerValue()
                let compact = try active.required("stream").elements()
                for (index, value) in compact.enumerated() {
                    let chunk = try value.fields(), kind = try chunk.text("type"), key = "attempt-\(attempt!)-baseline-\(index)"
                    if kind == "text-chunks" || kind == "reasoning-chunks" {
                        let text = try chunk.required("texts").elements().map { try $0.stringValue() }.joined()
                        transient += try Self.rows(.object(["type": .string(kind == "text-chunks" ? "text-delta" : "reasoning-delta"), "text": .string(text)]), key: key)
                    } else if kind == "tool-call-chunks" {
                        let args = try chunk.required("args").elements().map { try $0.stringValue() }.joined()
                        transient.append(.init(id: key, title: (try? chunk.text("name")) ?? "Tool activity", text: args, kind: "tool", raw: value.data))
                    } else if kind == "chunk" { transient += try Self.rows(chunk.required("chunk"), key: key) }
                    else { throw RemoteHarnessClientFailure.protocolMismatch }
                }
            }
            let activeTurn = try? f["assistantStream"]?.fields()["activeAttempt"]?.fields().required("turn").integerValue()
            rebuildApprovalEvidence(sessionID: expectedSessionID, snapshotTurn: activeTurn)
        } else if type == "event" || type == "chunks" {
            let event = try f.required("event").fields(), seq = try event.required("seq").integerValue()
            guard let liveCursor else { throw RemoteHarnessClientFailure.protocolMismatch }
            if seq <= liveCursor {
                guard records.contains(value.data) else { throw RemoteHarnessClientFailure.protocolMismatch }; return
            }
            let range = try Self.sequenceRange(value)
            guard liveCursor < NativeConnectionBounds.counter, range.lowerBound == liveCursor + 1 else { throw RemoteHarnessClientFailure.protocolMismatch }
            // Replacement ranges reference the authoritative event sequence.
            if let op = try? event["surfaceOp"]?.fields(), try op["op"]?.stringValue() == "replace",
               let start = try op["startSeq"]?.integerValue(), let end = try op["endSeq"]?.integerValue() {
                records = try records.filter { bytes in
                    let old = try RemoteHarnessJSON(data: bytes).fields().required("event").fields().required("seq").integerValue(); return old < start || old > end
                }
                // A previously shown immutable call cannot be silently replaced
                // with different arguments under an outstanding approval.
                invalidateApprovalEvidence()
            }
            guard records.count < 1024 else { throw RemoteHarnessClientFailure.limit }; records.append(value.data); seenSequences.insert(seq)
            self.liveCursor = range.upperBound
            let eventType = try event.text("type")
            if eventType.hasPrefix("chunkrow/") || eventType == "assistant/chunk" || eventType == "assistant/message" { transient = [] }
            indexApprovalRecord(value)
        } else if type == "assistant-stream" {
            guard let liveCursor else { throw RemoteHarnessClientFailure.protocolMismatch }
            let frame = try f.required("frame").fields(), frameType = try frame.text("type"), id = try frame.text("attemptId")
            let nextRevision = try frame.required("revision").integerValue()
            guard nextRevision > revision else { throw RemoteHarnessClientFailure.protocolMismatch }
            if frameType == "start" {
                guard attempt == nil, try frame.required("startedAfterSeq").integerValue() <= liveCursor else { throw RemoteHarnessClientFailure.protocolMismatch }
                _ = try frame.required("turn").integerValue(); _ = try frame.required("step").integerValue()
                attempt = id; nextIndex = 0; transient = []
            }
            else if frameType == "end" {
                guard attempt == id, try frame.required("index").integerValue() == nextIndex else { throw RemoteHarnessClientFailure.protocolMismatch }; attempt = nil
            }
            else if frameType == "chunk" {
                guard attempt == id, try frame.required("index").integerValue() == nextIndex else { throw RemoteHarnessClientFailure.protocolMismatch }
                guard transient.count < 1024 else { throw RemoteHarnessClientFailure.limit }
                let chunk = try frame.required("chunk")
                transient += try Self.rows(chunk, key: "attempt-\(id)-\(nextIndex)"); nextIndex += 1
            } else { throw RemoteHarnessClientFailure.protocolMismatch }
            revision = nextRevision
        } else { throw RemoteHarnessClientFailure.protocolMismatch }
        guard records.reduce(0, { $0 + $1.count }) <= 8_388_608 else { throw RemoteHarnessClientFailure.limit }
        rows = Self.compact(try records.enumerated().flatMap { try Self.rows(RemoteHarnessJSON(data: $0.element), key: "record-\($0.offset)") } + transient)
    }
    public mutating func prependPage(_ value: RemoteHarnessJSON) throws {
        let f = try value.fields(), page = try f.required("records").elements()
        guard let cursor, let before = earliestSequence, records.count + page.count <= 1024 else { throw RemoteHarnessClientFailure.limit }
        var last: Int64?
        for record in page {
            let range = try Self.sequenceRange(record)
            guard range.upperBound <= cursor, range.upperBound < before, last == nil || range.lowerBound > last! else { throw RemoteHarnessClientFailure.protocolMismatch }; last = range.upperBound
        }
        guard records.reduce(0, { $0 + $1.count }) + page.reduce(0, { $0 + $1.data.count }) <= 8_388_608 else { throw RemoteHarnessClientFailure.limit }
        records = page.map(\.data) + records; hasMore = try f.required("hasMore").booleanValue()
        seenSequences.formUnion(page.compactMap { try? $0.fields().required("event").fields().required("seq").integerValue() })
        rows = Self.compact(try records.enumerated().flatMap { try Self.rows(RemoteHarnessJSON(data: $0.element), key: "record-\($0.offset)") } + transient)
        // Earlier records may disclose another use of a call ID. Never let a
        // page turn a previously invalid current run back into valid evidence.
        let wasInvalid = actionEvidenceInvalid, activeRun = actionRunID
        if let sessionID = actionSessionID {
            actionSessionID = sessionID; resetActionRun(activeRun)
            for bytes in records { if let record = try? RemoteHarnessJSON(data: bytes) { indexToolCall(record) } }
            if wasInvalid { invalidateApprovalEvidence() }
        }
    }
    public mutating func clearApprovalEvidence() {
        actionSessionID = nil; maximumActionTurn = nil; resetActionRun(nil)
    }
    public func approvalAction(for approval: RemoteHarnessPendingApproval) -> RemoteHarnessClientApprovalAction? {
        guard !actionEvidenceInvalid, let binding = approval.extensionBinding,
              binding.sessionID == actionSessionID, approval.binding.sessionID == actionSessionID,
              binding.workspaceID == approval.binding.workspaceID, binding.runID == actionRunID,
              let request = try? approval.request.fields(), let callID = try? request.text("callId"),
              let toolName = try? request.text("toolName"), case .unique(let action)? = calls[callID],
              action.callID.utf8.elementsEqual(callID.utf8), action.toolName.utf8.elementsEqual(toolName.utf8) else { return nil }
        return action
    }
    private mutating func resetActionRun(_ runID: String?) {
        actionRunID = runID; calls = [:]; callCount = 0; callBytes = 0; actionEvidenceInvalid = false
    }
    private mutating func invalidateApprovalEvidence() {
        calls = [:]; callBytes = 0; actionEvidenceInvalid = true
    }
    private mutating func startActionTurn(_ turn: Int64) {
        guard maximumActionTurn == nil || turn > maximumActionTurn! else {
            actionRunID = "turn:\(turn)"; invalidateApprovalEvidence(); return
        }
        maximumActionTurn = turn; resetActionRun("turn:\(turn)")
    }
    private mutating func rebuildApprovalEvidence(sessionID: String, snapshotTurn: Int64?) {
        let sameSession = actionSessionID == sessionID, priorRun = actionRunID, priorMaximum = maximumActionTurn, wasInvalid = actionEvidenceInvalid
        let priorCalls = calls
        actionSessionID = sessionID; maximumActionTurn = nil; resetActionRun(nil)
        for bytes in records { if let record = try? RemoteHarnessJSON(data: bytes) { indexApprovalRecord(record) } }
        if let turn = snapshotTurn, actionRunID != "turn:\(turn)" {
            startActionTurn(turn)
            for bytes in records { if let record = try? RemoteHarnessJSON(data: bytes) { indexToolCall(record) } }
        }
        // A shorter same-connection snapshot cannot erase a poisoned/reused
        // run or lower the scope's turn watermark. Reconnect clears both.
        if sameSession, let priorMaximum, maximumActionTurn == nil || maximumActionTurn! <= priorMaximum {
            maximumActionTurn = priorMaximum
            if actionRunID != nil, actionRunID != priorRun || wasInvalid { invalidateApprovalEvidence() }
        }
        if sameSession, actionRunID != nil, actionRunID == priorRun, !actionEvidenceInvalid {
            // The same durable call is immutable across snapshots. A shorter
            // snapshot must not forget it and later authorize changed arguments
            // or an identical-looking call at a different durable sequence.
            for (callID, evidence) in priorCalls {
                guard case .unique(let old) = evidence, case .unique(let current)? = calls[callID], current == old else {
                    invalidateApprovalEvidence(); break
                }
            }
        }
    }
    private mutating func indexApprovalRecord(_ record: RemoteHarnessJSON) {
        guard let fields = try? record.fields(), (try? fields.text("type")) == "event",
              let event = try? fields.required("event").fields(), let name = try? event.text("type") else { return }
        if name == "turn/start" {
            guard let turn = try? event.required("data").fields().required("turn").integerValue() else { invalidateApprovalEvidence(); return }
            startActionTurn(turn)
        } else if name == "turn/end" {
            if let turn = try? event.required("data").fields().required("turn").integerValue() {
                maximumActionTurn = max(maximumActionTurn ?? turn, turn)
            }
            resetActionRun(nil)
        }
        else if name == "tool/call" { indexToolCall(record) }
    }
    private mutating func indexToolCall(_ record: RemoteHarnessJSON) {
        guard !actionEvidenceInvalid, let sessionID = actionSessionID, let runID = actionRunID,
              let fields = try? record.fields(), (try? fields.text("type")) == "event",
              let event = try? fields.required("event").fields(), (try? event.text("type")) == "tool/call" else { return }
        guard let data = try? event.required("data").fields(), let turn = try? data.required("turn").integerValue(),
              let sequence = try? event.required("seq").integerValue() else { invalidateApprovalEvidence(); return }
        guard runID == "turn:\(turn)" else { return }
        callCount += 1
        guard callCount <= Self.maximumApprovalCalls else { invalidateApprovalEvidence(); return }
        guard let callID = try? data.text("callId"), callID.utf8.count <= 1024 else { invalidateApprovalEvidence(); return }
        if case .unique(_)? = calls[callID] { invalidateApprovalEvidence(); return }
        if calls[callID] != nil { return }
        guard let toolName = try? data.text("name"), toolName.utf8.count <= 1024,
              let arguments = try? data.required("arguments").stringValue(), arguments.utf8.count <= Self.maximumApprovalArgumentBytes,
              (try? RemoteHarnessJSON(data: Data(arguments.utf8))) != nil else { retainAmbiguousCall(callID); return }
        for scope in [fields["sessionId"], event["sessionId"], data["sessionId"]].compactMap({ $0 }) {
            guard (try? scope.stringValue()) == sessionID else { retainAmbiguousCall(callID); return }
        }
        let retainedBytes = sessionID.utf8.count + runID.utf8.count + callID.utf8.count + toolName.utf8.count + arguments.utf8.count
        guard callBytes <= Self.maximumApprovalEvidenceBytes - retainedBytes else { invalidateApprovalEvidence(); return }
        calls[callID] = .unique(.init(sessionID: sessionID, runID: runID, callID: callID, toolName: toolName, arguments: arguments, sequence: sequence))
        callBytes += retainedBytes
    }
    private mutating func retainAmbiguousCall(_ callID: String) {
        guard callBytes <= Self.maximumApprovalEvidenceBytes - callID.utf8.count else { invalidateApprovalEvidence(); return }
        calls[callID] = .ambiguous; callBytes += callID.utf8.count
        actionEvidenceInvalid = true
    }
    public var earliestSequence: Int64? { records.compactMap { try? RemoteHarnessJSON(data: $0).fields().required("event").fields().required("seq").integerValue() }.min() }
    private static func sequenceRange(_ record: RemoteHarnessJSON) throws -> ClosedRange<Int64> {
        let f = try record.fields(), type = try f.text("type")
        guard type == "event" || type == "chunks" else { throw RemoteHarnessClientFailure.protocolMismatch }
        let event = try f.required("event").fields(), seq = try event.required("seq").integerValue()
        var count: Int64 = 1
        if type == "chunks" {
            let data = try event.required("data").fields(), name = try event.text("type")
            if name == "chunkrow/text-chunks" || name == "chunkrow/reasoning-chunks" { count = Int64(try data.required("texts").elements().count) }
            else if name == "chunkrow/tool-call-chunks" { count = Int64(try data.required("args").elements().count) }
            else { throw RemoteHarnessClientFailure.protocolMismatch }
        }
        guard count > 0, seq <= NativeConnectionBounds.counter - count + 1 else { throw RemoteHarnessClientFailure.protocolMismatch }
        return seq...(seq + count - 1)
    }
    private static func rows(_ value: RemoteHarnessJSON, key: String) throws -> [RemoteHarnessClientTimelineRow] {
        let f = try value.fields()
        if let event = f["event"] { return try rows(event, key: key) }
        let type = try f["type"]?.stringValue() ?? "event"
        if type == "turn/start" || type == "turn/end" { return [] }
        let data = (try? f["data"]?.fields()) ?? f
        if let chunk = data["chunk"] { return try rows(chunk, key: key) }
        if type == "chunkrow/text-chunks" || type == "chunkrow/reasoning-chunks" {
            let text = try data.required("texts").elements().map { try $0.stringValue() }.joined()
            return [.init(id: key, title: type.contains("reasoning") ? "Reasoning" : "Assistant", text: text, kind: type.contains("reasoning") ? "reasoning" : "assistant", raw: value.data)]
        }
        if type == "chunkrow/tool-call-chunks" {
            let args = try data.required("args").elements().map { try $0.stringValue() }.joined()
            return [.init(id: key, title: (try? data.text("name")) ?? "Tool activity", text: args, kind: "tool", raw: value.data)]
        }
        let kind = type.contains("reasoning") ? "reasoning" : type.contains("tool") ? "tool" : type.contains("user") ? "user" : "assistant"
        let title = kind == "tool" ? ((try? data.text("toolName")) ?? (try? data.text("name")) ?? "Tool activity") : kind == "reasoning" ? "Reasoning" : kind == "user" ? "You" : "Assistant"
        let text = try readable(value, depth: 0)
        return [.init(id: key, title: title, text: text.isEmpty ? type : text, kind: kind, raw: value.data)]
    }
    private static func compact(_ rows: [RemoteHarnessClientTimelineRow]) -> [RemoteHarnessClientTimelineRow] {
        var result: [RemoteHarnessClientTimelineRow] = []
        for row in rows {
            if let previous = result.last, (row.kind == "assistant" || row.kind == "reasoning"), previous.kind == row.kind,
               row.id.hasPrefix("attempt-") || previous.id.hasPrefix("attempt-") {
                result[result.count - 1] = .init(id: previous.id, title: previous.title, text: previous.text + row.text, kind: previous.kind, raw: previous.raw)
            } else { result.append(row) }
        }
        return result
    }
    private static func readable(_ value: RemoteHarnessJSON, depth: Int) throws -> String {
        guard depth < 12 else { return "" }
        if let string = try? value.stringValue() { return string }
        if let list = try? value.elements() { return try list.map { try readable($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let f = try? value.fields() else { return "" }
        for key in ["text", "content", "reasoning", "message", "output", "result", "data", "chunk", "arguments", "argumentsDelta"] {
            if let child = f[key] { let text = try readable(child, depth: depth + 1); if !text.isEmpty { return text } }
        }
        return ""
    }
}
