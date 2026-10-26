import Foundation
import XCTest
@testable import QuenderinKit

@MainActor
final class RemoteHarnessAttentionTests: XCTestCase {
    private enum Mismatch: Error { case fixture }
    private struct Scope: Decodable {
        let origin: String?
        let clientDeviceID: String?
        let hostID: String?
        let hostFingerprint: String?
        let workspaceID: String?
        let sessionID: String?
    }
    private struct Event: Decodable {
        let scope: Scope?
        let eventID: String?
        let kind: String?
        let generation: UInt64?
        let issuedAt: Int64?
        let expiresAt: Int64?
        let authenticatedAndNegotiated: Bool?
        let historical: Bool?
    }
    private struct Step: Decodable {
        let action: String
        let enabled: Bool?
        let foreground: Bool?
        let viewing: Bool?
        let viewedScope: Scope?
        let currentScope: Scope?
        let currentGeneration: UInt64?
        let event: Event?
        let nowEpoch: Int64?
        let nowMonotonic: Int64?
        let count: Int?
        let expect: String
        let reason: String
        let remembered: Int
    }
    private struct Fixture: Decodable { let id: String; let scope: Scope?; let steps: [Step] }
    private struct Document: Decodable {
        let schemaVersion: Int
        let policyVersion: String
        let baseScope: Scope
        let baseEvent: Event
        let cases: [Fixture]
    }
    private func require(_ value: Bool) throws { if !value { throw Mismatch.fixture } }
    private func scope(_ base: RemoteHarnessAttentionScope, _ patch: Scope?) -> RemoteHarnessAttentionScope {
        RemoteHarnessAttentionScope(origin: patch?.origin ?? base.origin, clientDeviceID: patch?.clientDeviceID ?? base.clientDeviceID,
            hostID: patch?.hostID ?? base.hostID, hostFingerprint: patch?.hostFingerprint ?? base.hostFingerprint,
            workspaceID: patch?.workspaceID ?? base.workspaceID, sessionID: patch?.sessionID ?? base.sessionID)
    }
    private func event(scope: RemoteHarnessAttentionScope, base: Event, patch: Event?, fillID: String?, defaultValidation: Bool) throws -> RemoteHarnessAttentionEvent {
        let generation = try XCTUnwrap(patch?.generation ?? base.generation)
        let eventID = try XCTUnwrap(fillID ?? patch?.eventID ?? base.eventID)
        let kind = try XCTUnwrap(patch?.kind ?? base.kind)
        let issued = try XCTUnwrap(patch?.issuedAt ?? base.issuedAt), expires = try XCTUnwrap(patch?.expiresAt ?? base.expiresAt)
        let historical = patch?.historical ?? base.historical ?? false
        if defaultValidation {
            return RemoteHarnessAttentionEvent(scope: scope, generation: generation, eventID: eventID, kind: kind,
                issuedAtEpochMilliseconds: issued, expiresAtEpochMilliseconds: expires, historical: historical)
        }
        return RemoteHarnessAttentionEvent(scope: scope, generation: generation, eventID: eventID, kind: kind,
            issuedAtEpochMilliseconds: issued, expiresAtEpochMilliseconds: expires,
            authenticatedAndNegotiated: patch?.authenticatedAndNegotiated ?? base.authenticatedAndNegotiated ?? false, historical: historical)
    }
    private func check(_ result: RemoteHarnessAttentionDecision, event: RemoteHarnessAttentionEvent, step: Step) throws {
        try require(result.disposition.rawValue == step.expect && result.reason.rawValue == step.reason)
        try require(!result.authorizesExecution)
        if result.disposition == .suppress { try require(result.payload == nil) }
        else {
            let payload = try XCTUnwrap(result.payload)
            try require(payload.title == "Remote Harness" && payload.body == "A remote session needs your attention.")
            try require(payload.eventID.utf8.elementsEqual(event.eventID.utf8) && payload.sessionID.utf8.elementsEqual(event.scope.sessionID.utf8))
            try require(payload.description == "RemoteHarnessAttentionPayload(redacted)")
        }
        try require(event.description == "RemoteHarnessAttentionEvent(redacted)" && result.description == "RemoteHarnessAttentionDecision(redacted)")
        var reflected = ""; dump(result, to: &reflected)
        try require(!reflected.contains("eventID") && !reflected.contains("sessionID"))
    }

    func testSharedSyntheticAttentionFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appendingPathComponent("shared/remote-harness-attention-fixtures.json"))
        let document = try JSONDecoder().decode(Document.self, from: source)
        try require(document.schemaVersion == 1 && document.policyVersion == "local-attention-v1")
        let empty = RemoteHarnessAttentionScope(origin: "", clientDeviceID: "", hostID: "", hostFingerprint: "", workspaceID: "", sessionID: "")
        let baseScope = scope(empty, document.baseScope)
        var seen = Set<String>()
        for fixture in document.cases {
            try require(seen.insert(fixture.id).inserted)
            do {
                let policy = RemoteHarnessAttentionPolicy(), fixtureScope = scope(baseScope, fixture.scope)
                for step in fixture.steps {
                    try require(["evaluate", "evaluateDefaultEnabled", "evaluateDefaultValidation", "fill"].contains(step.action))
                    let current = scope(fixtureScope, step.currentScope)
                    let eventScope = scope(fixtureScope, step.event?.scope)
                    let viewed = step.viewedScope.map { scope(fixtureScope, $0) } ?? ((step.viewing ?? false) ? current : nil)
                    let count = step.action == "fill" ? try XCTUnwrap(step.count) : 1
                    try require((1...256).contains(count))
                    for index in 0..<count {
                        let input = try event(scope: eventScope, base: document.baseEvent, patch: step.event,
                            fillID: step.action == "fill" ? "fill-\(index)" : nil, defaultValidation: step.action == "evaluateDefaultValidation")
                        let result: RemoteHarnessAttentionDecision
                        if step.action == "evaluateDefaultEnabled" {
                            result = policy.evaluate(event: input, currentScope: current, currentGeneration: step.currentGeneration ?? 1,
                                nowEpochMilliseconds: step.nowEpoch ?? 100_000, nowMonotonicMilliseconds: step.nowMonotonic ?? 1_000,
                                foreground: step.foreground ?? false, viewedScope: viewed)
                        } else {
                            result = policy.evaluate(event: input, currentScope: current, currentGeneration: step.currentGeneration ?? 1,
                                nowEpochMilliseconds: step.nowEpoch ?? 100_000, nowMonotonicMilliseconds: step.nowMonotonic ?? 1_000,
                                enabled: step.enabled ?? true, foreground: step.foreground ?? false, viewedScope: viewed)
                        }
                        try check(result, event: input, step: step)
                    }
                    try require(policy.rememberedCount == step.remembered)
                }
            } catch {
                XCTFail("REMOTE_ATTENTION_CASE_FAIL " + fixture.id)
                throw Mismatch.fixture
            }
            emitFixturePass("REMOTE_ATTENTION_CASE_PASS " + fixture.id)
        }
        try require(!seen.isEmpty)
    }
}
