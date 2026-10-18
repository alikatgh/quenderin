import Foundation
#if canImport(llama) && QUENDERIN_VISION_LLAMA
import llama
#endif

public enum VisionEngineError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// One short-lived native handle per answer. Cancellation never frees a running handle.
public final class NativeVisionEngine: @unchecked Sendable {
    static let revision = "e8fd209c975c80aa7fb36a8423571ff3b1b7e955"
    static let patchSHA256 = "417a4d19ed4e05625cd4bc3ec269bf1a4331e8dd9263956b95e86b6158f938a9"
    public static var available: Bool {
        #if canImport(llama) && QUENDERIN_VISION_LLAMA
        guard quenderin_vision_runtime_abi() == 1,
              let revision = quenderin_vision_runtime_revision(), let digest = quenderin_vision_patch_sha256() else { return false }
        return String(cString: revision) == self.revision && String(cString: digest) == patchSHA256
        #else
        return false
        #endif
    }
    private let state = NSCondition()
    private var busy = false
    private var closed = false
    private var cancelled = false
    #if canImport(llama) && QUENDERIN_VISION_LLAMA
    private var handle: OpaquePointer?
    #endif
    public init() {}
    private func claim() throws {
        state.lock(); defer { state.unlock() }
        guard !busy, !closed else { throw VisionEngineError.invalid("Vision is already running or has been closed.") }
        busy = true; cancelled = false
    }
    private func finish() { state.lock(); busy = false; state.broadcast(); state.unlock() }
    private func isCancelled() -> Bool { state.lock(); defer { state.unlock() }; return cancelled }
    public func cancel() {
        state.lock(); defer { state.unlock() }
        guard busy else { return }
        cancelled = true
        #if canImport(llama) && QUENDERIN_VISION_LLAMA
        if let handle { quenderin_vision_cancel(handle) }
        #endif
    }
    private func closeAndWait() {
        state.lock(); closed = true
        if busy {
            cancelled = true
            #if canImport(llama) && QUENDERIN_VISION_LLAMA
            if let handle { quenderin_vision_cancel(handle) }
            #endif
        }
        while busy { state.wait() }
        state.unlock()
    }
    public func close() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { self.closeAndWait(); continuation.resume() }
        }
    }
    /// Both artifact identities are rehashed by the C runtime before allocation.
    public func answer(model: VisionModelDescriptor, modelURL: URL, projectorURL: URL, imageURL: URL,
                       prompt: String, availableMemoryBytes: Int64) async throws -> String {
        guard Self.available else { throw VisionEngineError.invalid("The pinned native vision runtime is unavailable in this build.") }
        try Self.validate(model: model, modelURL: modelURL, projectorURL: projectorURL, imageURL: imageURL,
                          prompt: prompt, availableMemoryBytes: availableMemoryBytes)
        try claim()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let answer = try self.run(model: model, modelURL: modelURL, projectorURL: projectorURL, imageURL: imageURL, prompt: prompt)
                        self.finish(); continuation.resume(returning: answer)
                    } catch { self.finish(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
    static func validate(model: VisionModelDescriptor, modelURL: URL, projectorURL: URL, imageURL: URL,
                         prompt: String, availableMemoryBytes: Int64) throws {
        guard let pinned = VisionModels.model(model.id), pinned.minimumMemoryBytes == model.minimumMemoryBytes,
              model.artifacts.count == 2, pinned.artifacts.count == 2,
              zip(model.artifacts, pinned.artifacts).allSatisfy({ a, b in
                  a.role == b.role && a.filename == b.filename && a.bytes == b.bytes && a.sha256 == b.sha256 && a.url == b.url
              }), availableMemoryBytes >= pinned.minimumMemoryBytes,
              let main = pinned.artifacts.first(where: { $0.role == "model" }),
              let projector = pinned.artifacts.first(where: { $0.role == "projector" }),
              modelURL.lastPathComponent == main.filename, projectorURL.lastPathComponent == projector.filename,
              modelURL != projectorURL else { throw VisionEngineError.invalid("A complete pinned vision model and sufficient available memory are required.") }
        for url in [modelURL, projectorURL, imageURL] {
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 16_384, !url.path.contains("\0"),
                  url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw VisionEngineError.invalid("Vision inputs must be local absolute paths without symbolic links.")
            }
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32_768,
              !prompt.contains("\0") else { throw VisionEngineError.invalid("Enter a question of 1–32768 UTF-8 bytes.") }
    }
    private func run(model: VisionModelDescriptor, modelURL: URL, projectorURL: URL, imageURL: URL, prompt: String) throws -> String {
        #if canImport(llama) && QUENDERIN_VISION_LLAMA
        guard !isCancelled(), ImageResourceBudget.current().availableMemoryBytes >= model.minimumMemoryBytes else {
            throw VisionEngineError.invalid("Vision was cancelled or current available memory is insufficient.")
        }
        SharedLlamaBackend.shared.acquire()
        defer { SharedLlamaBackend.shared.release() }
        guard let native = quenderin_vision_create() else { throw VisionEngineError.invalid("Unable to create the vision engine.") }
        state.lock(); handle = native; let stopped = cancelled; state.unlock()
        if stopped { quenderin_vision_cancel(native) }
        defer {
            // Cancel holds this lock while touching the handle, so free cannot race it.
            state.lock(); handle = nil; quenderin_vision_free(native); state.unlock()
        }
        func failure() -> VisionEngineError {
            let text = quenderin_vision_last_error(native).map { String(cString: $0) } ?? "Native vision failed."
            return .invalid(String(text.prefix(512)))
        }
        let loadResult = model.id.withCString { id in modelURL.path.withCString { main in projectorURL.path.withCString { projector in
            var options = quenderin_vision_load_options(abi: 1, model_id: id, model_path: main,
                projector_path: projector, context_size: 4096, threads: UInt32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))))
            return quenderin_vision_load(native, &options)
        } } }
        guard loadResult == 0, !isCancelled() else { throw failure() }
        let output = VisionNativeOutput()
        let retained = Unmanaged.passRetained(output)
        defer { retained.release() }
        let result = imageURL.path.withCString { image in prompt.withCString { question in
            var request = quenderin_vision_request(abi: 1, image_path: image, prompt: question, max_tokens: 512)
            return quenderin_vision_generate(native, &request, { bytes, count, user in
                guard let bytes, let user else { return 0 }
                let output = Unmanaged<VisionNativeOutput>.fromOpaque(user).takeUnretainedValue()
                guard count <= 65_536, output.data.count + count <= 65_536 else { output.failed = true; return 0 }
                output.data.append(contentsOf: UnsafeRawBufferPointer(start: bytes, count: count).bindMemory(to: UInt8.self))
                return 1
            }, retained.toOpaque())
        } }
        guard result == 0, !output.failed, !isCancelled(), quenderin_vision_generated_tokens(native) <= 512,
              let answer = String(data: output.data, encoding: .utf8), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure() }
        return answer
        #else
        throw VisionEngineError.invalid("The native vision runtime is not linked.")
        #endif
    }
}
#if canImport(llama) && QUENDERIN_VISION_LLAMA
private final class VisionNativeOutput {
    var data = Data()
    var failed = false
}
#endif
