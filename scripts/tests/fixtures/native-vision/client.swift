import Foundation
import llama
final class SharedLlamaBackend: @unchecked Sendable {
    static let shared = SharedLlamaBackend()
    private let lock = NSLock()
    private var refs = 0
    func acquire() { lock.lock(); refs += 1; lock.unlock() }
    func release() { lock.lock(); precondition(refs > 0); refs -= 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return refs }
}
struct ImageResourceBudget {
    let availableMemoryBytes: Int64 = 512 * 1024 * 1024 * 1024
    static func current() -> Self { Self() }
}
@main struct Verify {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, NativeVisionEngine.available else { fatalError("Runtime unavailable") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = VisionModels.all[0]
        let main = root.appendingPathComponent(model.artifacts[0].filename)
        let projector = root.appendingPathComponent(model.artifacts[1].filename)
        let image = root.appendingPathComponent("🌲.png")
        let engine = NativeVisionEngine()
        do {
            _ = try await engine.answer(model: model, modelURL: main, projectorURL: projector, imageURL: image,
                prompt: "Unicode 🌲", availableMemoryBytes: 1)
            fatalError("Low memory accepted")
        } catch {}
        precondition(qv_fixture_created() == 0)
        let answer = try await engine.answer(model: model, modelURL: main, projectorURL: projector, imageURL: image,
            prompt: "Unicode 🌲", availableMemoryBytes: Int64.max)
        precondition(answer == "Tree 🌲 < safe")
        precondition(SharedLlamaBackend.shared.count == 0 && qv_fixture_created() == qv_fixture_freed())
        let task = Task {
            try await engine.answer(model: model, modelURL: main, projectorURL: projector, imageURL: image,
                prompt: "BLOCK", availableMemoryBytes: Int64.max)
        }
        for _ in 0..<1000 { if qv_fixture_active() == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        precondition(qv_fixture_active() == 1)
        do {
            _ = try await engine.answer(model: model, modelURL: main, projectorURL: projector, imageURL: image,
                prompt: "Unicode 🌲", availableMemoryBytes: Int64.max)
            fatalError("Concurrent answer accepted")
        } catch {}
        engine.cancel()
        do { _ = try await task.value; fatalError("Cancellation accepted as success") } catch {}
        let again = try await engine.answer(model: model, modelURL: main, projectorURL: projector, imageURL: image,
            prompt: "Unicode 🌲", availableMemoryBytes: Int64.max)
        precondition(again == answer)
        await engine.close()
        precondition(SharedLlamaBackend.shared.count == 0 && qv_fixture_created() == qv_fixture_freed())
        print("PASS: Swift actual C ABI load/generate, UTF-8, memory, serialization, cancel and lifetime")
    }
}
