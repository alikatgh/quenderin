import Foundation

public enum DefaultHyMemoryInference {
    public static func make() -> any HyMemoryInferencePort { HyMemoryNativeInference() }
}

private final class HyMemoryNativeInference: HyMemoryInferencePort, @unchecked Sendable {
    private let engine = LlamaEngine(deviceBudgetGB: HardwareProbe.appMemoryBudgetGB())
    private let state = NSCondition()
    private var busy = false
    private var cancelled = false
    var unavailableReason: String? { ModelRuntimeSupport.supportsBonsai ? nil : "The verified native Prism specialist runtime is unavailable." }
    private func claim() -> Bool { state.lock(); defer { state.unlock() }; if busy { return false }; busy = true; cancelled = false; return true }
    private func release() { state.lock(); busy = false; state.broadcast(); state.unlock() }
    private func isCancelled() -> Bool { state.lock(); defer { state.unlock() }; return cancelled }
    private func markCancelled() { state.lock(); cancelled = true; state.unlock() }
    private func waitUntilIdle() { state.lock(); while busy { state.wait() }; state.unlock() }
    func cancel() async {
        markCancelled(); engine.requestCancel()
        await engine.unload()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { self.waitUntilIdle(); continuation.resume() }
        }
    }
    func generate(_ request: HyMemoryInferenceRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard claim() else { throw HyMemoryError.invalid("A specialist generation is already running.") }
        do {
            let source = try await engine.generateHyMemory(request, externalCancellation: { self.isCancelled() })
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var bytes = 0
                        for try await piece in source {
                            try Task.checkCancellation()
                            bytes += piece.utf8.count
                            guard bytes <= 65_536 else { throw HyMemoryError.invalid("Specialist output exceeded its bound.") }
                            continuation.yield(piece)
                        }
                        try request.artifact.assertCurrent()
                        await engine.unload(); release(); continuation.finish()
                    } catch {
                        engine.requestCancel(); await engine.unload(); release(); continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch {
            await engine.unload(); release(); throw error
        }
    }
}
