import Foundation

public struct ModelArtifact: Sendable { let filename: String; let url: String; let sha256: String; let downloadBytes: Int64 }
public struct ModelEntry: Sendable { let id: String; let sha256: String?; let downloadBytes: Int64? }
public enum Role: Sendable { case user, assistant }
public struct ChatMessage: Sendable { let role: Role; let text: String }
enum ModelArtifactSet {
    static func isMultipart(_ model: ModelEntry) -> Bool { false }
    static func verify(_ model: ModelEntry, firstFile: URL) throws { fatalError("Unexpected multipart fixture") }
    static func inBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached { try work() }.value }
}
// This standalone fixture exercises specialist suspension/restoration. Automatic
// transactions use the full integrity implementation in the native controller tests.
enum InferencePerformanceIdentity {
    static func verifyInstalled(_ model: ModelEntry, firstFile: URL) throws {
        fatalError("Unexpected Automatic transaction in specialist-only fixture")
    }
}
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private(set) var running = false
    func begin() { lock.lock(); stopped = false; running = true; lock.unlock() }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func finish() { lock.lock(); running = false; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return running }
}
actor FixtureEngine: InferenceEngine {
    let state = RunState()
    private var model: String?
    private(set) var loads = 0
    private var worker: Task<Void, Never>?
    private(set) var loading = false
    var allowLoad = true
    func blockLoad() { allowLoad = false }
    func releaseLoad() { allowLoad = true }
    func loadedModelID() async -> String? { model }
    func load(model: ModelEntry, at: URL) async throws {
        loading = true
        while !allowLoad { try await Task.sleep(for: .milliseconds(1)) }
        loads += 1; self.model = model.id; loading = false
    }
    nonisolated func requestCancel() { state.cancel() }
    func unload() async {
        state.cancel(); await worker?.value
        precondition(!state.active); model = nil
    }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard model != nil else { throw InferenceError.modelNotLoaded }
        state.begin()
        return AsyncThrowingStream { continuation in
            worker = Task.detached { [state] in
                continuation.yield("partial answer")
                while !state.cancelled { try? await Task.sleep(for: .milliseconds(1)) }
                state.finish(); continuation.finish()
            }
        }
    }
}
@main struct Verify {
    static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("selected.gguf")
        try Data("GGUFsynthetic".utf8).write(to: file)
        let model = ModelEntry(id: "selected", sha256: try ModelIntegrity.sha256Hex(of: file), downloadBytes: 13)
        let native = FixtureEngine(); let engine = CoordinatedInferenceEngine(native)
        try await engine.load(model: model, at: file)
        let stream = try await engine.generate(prompt: "question", options: .init())
        let consumer = Task { var text = ""; for try await piece in stream { text += piece }; return text }
        let lease = try await engine.suspendForSpecialist()
        precondition(!native.state.active)
        let output = try await consumer.value; precondition(output == "partial answer")
        let paused = await engine.isSuspendedForSpecialist(); precondition(paused)
        do { try await engine.load(model: model, at: file); fatalError("Paused load accepted") } catch {}
        do { _ = try await engine.generate(prompt: "blocked", options: .init()); fatalError("Paused generation accepted") } catch {}
        do { _ = try await engine.suspendForSpecialist(); fatalError("Second lease accepted") } catch {}
        try await lease.resume(); try await lease.resume()
        let restored = await engine.loadedModelID(); let loads = await native.loads
        precondition(restored == model.id && loads == 2)
        let removed = try await engine.suspendForSpecialist(); try FileManager.default.removeItem(at: file)
        do { try await removed.resume(); fatalError("Missing restore artifact accepted") } catch SpecialistCoordinationError.restoreFailed {}
        let unpaused = await engine.isSuspendedForSpecialist(); precondition(!unpaused)
        try Data("GGUFsynthetic".utf8).write(to: file); try await engine.load(model: model, at: file)
        let emptyNative = FixtureEngine(); let empty = CoordinatedInferenceEngine(emptyNative)
        let firstRun = try await empty.suspendForSpecialist(); try await firstRun.resume()
        let emptyLoads = await emptyNative.loads; precondition(emptyLoads == 0)
        let gatedNative = FixtureEngine(); await gatedNative.blockLoad(); let gated = CoordinatedInferenceEngine(gatedNative)
        let loader = Task { try await gated.load(model: model, at: file) }
        for _ in 0..<1000 { if await gatedNative.loading { break }; try await Task.sleep(for: .milliseconds(1)) }
        let suspender = Task { try await gated.suspendForSpecialist() }
        try await Task.sleep(for: .milliseconds(20)); await gatedNative.releaseLoad(); try await loader.value
        let gatedLease = try await suspender.value
        let unloaded = await gatedNative.loadedModelID(); precondition(unloaded == nil)
        try await gatedLease.resume()
        let final = await gated.loadedModelID(); precondition(final == model.id)
        print("PASS: actual Swift exclusive lease joins generation/admitted load, blocks text, restores locally and recovers")
    }
}
