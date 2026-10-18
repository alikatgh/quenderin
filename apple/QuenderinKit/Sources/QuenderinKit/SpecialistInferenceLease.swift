import Foundation

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
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var selected: (model: ModelEntry, file: URL)?
    public init(_ underlying: any InferenceEngine) { self.underlying = underlying }
    public func isSuspendedForSpecialist() async -> Bool { held != nil }
    public func loadedModelID() async -> String? { held == nil ? await underlying.loadedModelID() : nil }
    public func loadedContextTokens() async -> Int? { held == nil ? await underlying.loadedContextTokens() : nil }
    public nonisolated func requestCancel() { underlying.requestCancel() }
    private func begin() throws { guard held == nil else { throw SpecialistCoordinationError.busy }; starts += 1 }
    private func end() {
        starts -= 1
        if starts == 0 { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    public func load(model: ModelEntry, at fileURL: URL) async throws {
        try begin(); defer { end() }
        try await underlying.load(model: model, at: fileURL)
        selected = (model, fileURL)
    }
    public func unload() async {
        guard held == nil else { return }
        starts += 1; defer { end() }
        await underlying.unload(); selected = nil
    }
    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try begin(); defer { end() }
        return try await underlying.generate(prompt: prompt, options: options)
    }
    public func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try begin(); defer { end() }
        return try await underlying.generateChat(system: system, history: history, options: options)
    }
    public func suspendForSpecialist() async throws -> SpecialistInferenceLease {
        guard held == nil else { throw SpecialistCoordinationError.busy }
        let id = UUID(); held = id
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
