import Foundation
import os

public enum SpecialistCoordinationError: LocalizedError, Sendable {
    case unavailable
    case busy
    case restoreFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This text engine does not support exclusive specialist workflows."
        case .busy: return "Text inference is paused for an active specialist workflow. Finish or cancel that workflow first."
        case .restoreFailed: return "The specialist finished, but the selected text model could not be restored from its installed file. Select the text model again to retry; your conversation and draft are kept."
        }
    }
}

/// Idempotent cleanup capability. Resume always joins the same restoration task.
public actor SpecialistInferenceLease {
    private let action: @Sendable () async throws -> Void
    private var resumption: Task<Void, Error>?
    init(_ action: @escaping @Sendable () async throws -> Void) { self.action = action }
    public func resume() async throws {
        if let resumption { return try await resumption.value }
        let task = Task { try await action() }
        resumption = task
        try await task.value
    }
}

/// One ordinary engine, one explicit specialist lease; conversations and selection live above it.
public actor CoordinatedInferenceEngine: InferenceEngine {
    private let underlying: any InferenceEngine
    private var held: UUID?
    private var starts = 0
    private var automaticSwitching = false
    private var activeStreams: Set<UUID> = []
    private var agentModelOwners: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var selected: (model: ModelEntry, file: URL)?
    private struct CapSnapshot: Sendable {
        var run: UInt64 = 0
        var status: ChatCapStatus = .unknown
    }
    private let capState = OSAllocatedUnfairLock(initialState: CapSnapshot())
    @discardableResult
    private nonisolated func invalidateCapStatus() -> UInt64 {
        capState.withLock {
            $0.run &+= 1
            $0.status = .unknown
            return $0.run
        }
    }
    private func publishCapStatus(_ status: ChatCapStatus, run: UInt64) {
        guard held == nil else { return }
        capState.withLock {
            if $0.run == run { $0.status = Task.isCancelled ? .unknown : status }
        }
    }
    public init(_ underlying: any InferenceEngine) { self.underlying = underlying }
    public func isSuspendedForSpecialist() async -> Bool { held != nil }
    public func chatCapStatus() async -> ChatCapStatus { held == nil ? capState.withLock { $0.status } : .unknown }
    public func loadedModelID() async -> String? { held == nil ? await underlying.loadedModelID() : nil }
    public func loadedContextTokens() async -> Int? { held == nil ? await underlying.loadedContextTokens() : nil }
    public func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile? {
        guard held == nil else { return nil }
        return await underlying.loadedExecutionProfile(system: system, history: history, options: options)
    }
    public func knownExecutionProfiles() async -> [InferenceExecutionProfile] { await underlying.knownExecutionProfiles() }
    public nonisolated func requestCancel() {
        invalidateCapStatus()
        underlying.requestCancel()
    }
    private func begin() throws { guard held == nil, !automaticSwitching else { throw SpecialistCoordinationError.busy }; starts += 1 }
    private func end() {
        starts -= 1
        if starts == 0 { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    public func load(model: ModelEntry, at fileURL: URL) async throws {
        invalidateCapStatus()
        try begin(); defer { end() }
        try await underlying.load(model: model, at: fileURL)
        selected = (model, fileURL)
    }
    public func unload() async {
        guard held == nil, !automaticSwitching else { return }
        invalidateCapStatus()
        starts += 1; defer { end() }
        await underlying.unload(); selected = nil
    }
    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try begin(); defer { end() }
        let myCapRun = invalidateCapStatus()
        let id = UUID(); activeStreams.insert(id)
        do { return track(try await underlying.generate(prompt: prompt, options: options), id: id, capRun: myCapRun) }
        catch { activeStreams.remove(id); throw error }
    }
    public func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try begin(); defer { end() }
        let myCapRun = invalidateCapStatus()
        let id = UUID(); activeStreams.insert(id)
        do { return track(try await underlying.generateChat(system: system, history: history, options: options), id: id, capRun: myCapRun) }
        catch { activeStreams.remove(id); throw error }
    }
    private func track(_ stream: AsyncThrowingStream<String, Error>, id: UUID, capRun: UInt64) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in stream {
                        if Task.isCancelled { break }
                        continuation.yield(piece)
                    }
                    let status: ChatCapStatus
                    if Task.isCancelled { status = .unknown } else { status = await underlying.chatCapStatus() }
                    self.publishCapStatus(status, run: capRun)
                    self.activeStreams.remove(id)
                    continuation.finish()
                } catch {
                    self.publishCapStatus(.unknown, run: capRun)
                    self.activeStreams.remove(id)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func retainModelForAgentRun() async throws -> SpecialistInferenceLease {
        guard held == nil, !automaticSwitching else { throw SpecialistCoordinationError.busy }
        let id = UUID(); agentModelOwners.insert(id)
        return SpecialistInferenceLease { await self.releaseAgentModel(id) }
    }
    private func releaseAgentModel(_ id: UUID) { agentModelOwners.remove(id) }
    public func loadForAutomaticIfIdle(model: ModelEntry, at fileURL: URL,
                                       stillCurrent: @escaping @Sendable () async -> Bool,
                                       accept: @escaping @Sendable () async -> Bool) async throws -> Bool {
        guard held == nil, !automaticSwitching, starts == 0, activeStreams.isEmpty, agentModelOwners.isEmpty else { return false }
        invalidateCapStatus()
        automaticSwitching = true
        defer { automaticSwitching = false; invalidateCapStatus() }
        let previous = selected
        do {
            guard await stillCurrent(), !Task.isCancelled else { throw CancellationError() }
            try await underlying.load(model: model, at: fileURL)
            // Acceptance validates and publishes the selection in one MainActor turn while this
            // exclusive transaction is still held. There is no outer asynchronous acceptance gap.
            guard await accept() else { throw CancellationError() }
            selected = (model, fileURL)
            return true
        } catch {
            let original = error
            // Keep this transaction exclusive through its single recovery; an agent cannot acquire
            // the newly loaded model in the gap before an invalidated Automatic choice rolls back.
            if let previous {
                do {
                    try await ModelArtifactSet.inBackground {
                        try InferencePerformanceIdentity.verifyInstalled(previous.model, firstFile: previous.file)
                    }
                    try await underlying.load(model: previous.model, at: previous.file)
                    selected = previous
                } catch {
                    await underlying.unload(); selected = nil
                    throw SpecialistCoordinationError.restoreFailed
                }
            } else { await underlying.unload(); selected = nil }
            throw original
        }
    }
    public func suspendForSpecialist() async throws -> SpecialistInferenceLease {
        guard held == nil, !automaticSwitching else { throw SpecialistCoordinationError.busy }
        let id = UUID(); held = id
        invalidateCapStatus()
        underlying.requestCancel()
        // Close already-admitted async load/generate starts before joining native work.
        if starts > 0 { await withCheckedContinuation { waiters.append($0) } }
        let snapshot = await underlying.loadedModelID() == selected?.model.id ? selected : nil
        underlying.requestCancel()
        await underlying.unload() // The native engine joins its generation lock before freeing.
        return SpecialistInferenceLease { try await self.resume(id, restoring: snapshot) }
    }
    private func resume(_ id: UUID, restoring snapshot: (model: ModelEntry, file: URL)?) async throws {
        guard held == id else { return }
        invalidateCapStatus()
        defer { held = nil }
        guard let snapshot else { return }
        do {
            // Restore only the same installed path, never through a downloader/onboarding installer.
            try await ModelArtifactSet.inBackground {
                guard let before = ModelArtifactReceipts.Identity.read(snapshot.file) else { throw SpecialistCoordinationError.restoreFailed }
                if let bytes = snapshot.model.downloadBytes, before.size != bytes { throw SpecialistCoordinationError.restoreFailed }
                if ModelArtifactSet.isMultipart(snapshot.model) { try ModelArtifactSet.verify(snapshot.model, firstFile: snapshot.file) }
                else { try ModelIntegrity.verify(fileURL: snapshot.file, expectedSHA256: snapshot.model.sha256) }
                guard before == ModelArtifactReceipts.Identity.read(snapshot.file) else { throw SpecialistCoordinationError.restoreFailed }
            }
            try await underlying.load(model: snapshot.model, at: snapshot.file)
            selected = snapshot
        } catch {
            await underlying.unload()
            throw SpecialistCoordinationError.restoreFailed
        }
    }
}
