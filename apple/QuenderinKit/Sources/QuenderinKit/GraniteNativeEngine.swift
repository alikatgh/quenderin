import Foundation

/// Specialist streams must never commit partial text after cancellation or a deadline.
enum SpecialistGenerationTermination: Error, LocalizedError {
    case cancelled, timedOut
    static func failure(cancelled: Bool, deadlineExpired: Bool) -> Self? {
        deadlineExpired ? .timedOut : cancelled ? .cancelled : nil
    }
    var errorDescription: String? {
        switch self {
        case .cancelled: return "The specialist generation was cancelled."
        case .timedOut: return "The specialist generation exceeded its time limit."
        }
    }
}

public final class NativeGraniteEngine: @unchecked Sendable {
    private let engine = LlamaEngine(deviceBudgetGB: HardwareProbe.appMemoryBudgetGB())
    private let state = NSCondition()
    private var busy = false
    private var cancelled = false
    public static var available: Bool { ModelRuntimeSupport.supportsBonsai && ModelRuntimeSupport.supportsWeeklyText }
    public init() {}
    private func claim() throws { state.lock(); defer { state.unlock() }; try Task.checkCancellation(); guard !busy else { throw GraniteError.invalid("Granite is already running.") }; busy = true; cancelled = false }
    private func finish() { state.lock(); busy = false; state.broadcast(); state.unlock() }
    private func finishSuccess() throws {
        state.lock(); defer { state.unlock() }
        guard !cancelled else { throw SpecialistGenerationTermination.cancelled }
        busy = false; state.broadcast()
    }
    private func isCancelled() -> Bool { state.lock(); defer { state.unlock() }; return cancelled }
    private func markCancelled() { state.lock(); cancelled = true; state.unlock() }
    private func wait() { state.lock(); while busy { state.wait() }; state.unlock() }
    public func cancel() async {
        markCancelled(); engine.requestCancel(); await engine.unload()
        await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { self.wait(); continuation.resume() } }
    }
    public func answer(proof: GraniteArtifactProof, messages: [GraniteMessage]) async throws -> String {
        guard Self.available else { throw GraniteError.invalid("This build requires the verified native Prism text runtime.") }
        return try await withTaskCancellationHandler {
            try claim()
            do {
                let stream = try await engine.generateGranite(proof, messages: messages, externalCancellation: { self.isCancelled() })
                var output = ""
                for try await piece in stream {
                    try Task.checkCancellation(); output += piece
                    guard output.utf8.count <= 65_536 else { throw GraniteError.invalid("Granite output exceeded its bound.") }
                }
                try Task.checkCancellation(); try proof.assertCurrent()
                let answer = try Granite41.finalAnswer(output)
                await engine.unload(); try Task.checkCancellation(); try finishSuccess(); return answer
            } catch { engine.requestCancel(); await engine.unload(); finish(); throw error }
        } onCancel: { self.markCancelled(); self.engine.requestCancel() }
    }
}
