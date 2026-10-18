import Foundation
#if canImport(QuenderinDiffusion)
import QuenderinDiffusion
#endif

public struct ImageGenerationRequest: Sendable {
    public let model: ImageModel
    public let directory: URL
    public let prompt: String
    public let output: URL
    public let seed: Int64
    public let budget: ImageResourceBudget
}

public protocol ImageGenerationEngine: Sendable {
    var available: Bool { get }
    func generate(_ request: ImageGenerationRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func cancel()
}

/// One native job per engine, with model verification and synchronous C work off the UI thread.
/// The lock protects only handle lifetime/cancellation; no lock is held during native generation.
public final class NativeImageGenerationEngine: ImageGenerationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.quenderin.images", qos: .userInitiated)
    private var running = false
    private var cancelled = false
    #if canImport(QuenderinDiffusion)
    private var handle: OpaquePointer?
    #endif

    public init() {}
    public var available: Bool {
        #if canImport(QuenderinDiffusion)
        return quenderin_diffusion_abi() == 1
        #else
        return false
        #endif
    }

    public func generate(_ request: ImageGenerationRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard available else { throw ImageGenerationError.invalid("This build does not include the local image engine.") }
        try request.model.validate()
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= 8192, !request.prompt.contains("\0"), request.seed >= 0 else {
            throw ImageGenerationError.invalid("Enter a scene description of at most 8,192 bytes.")
        }
        if let reason = request.budget.blockReason(for: request.model, installing: false) {
            throw ImageGenerationError.invalid(reason)
        }
        try Task.checkCancellation()
        try lock.withLock {
            guard !running else { throw ImageGenerationError.invalid("An image is already being generated.") }
            running = true
            cancelled = false
        }
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<URL, Error> = Result {
                        defer { lock.withLock { running = false } }
                        try ImageModelInstaller.verify(request.model, in: request.directory, cancelled: isCancelled)
                        if isCancelled() { throw CancellationError() }
                        #if canImport(QuenderinDiffusion)
                        guard let engine = quenderin_diffusion_create() else {
                            throw ImageGenerationError.invalid("The local image engine could not start.")
                        }
                        lock.withLock {
                            handle = engine
                            if cancelled { _ = quenderin_diffusion_cancel(engine) }
                        }
                        defer {
                            lock.withLock { handle = nil }
                            _ = quenderin_diffusion_destroy(engine)
                        }
                        func component(_ role: String) -> String {
                            request.model.components.first { $0.role == role }
                                .map { request.directory.appendingPathComponent($0.localFilename).path } ?? ""
                        }
                        let values: [String] = [component("diffusion"), component("text_encoder"), component("vae"),
                                                component("tokenizer"), request.prompt, "", request.output.path(percentEncoded: false)]
                        let strings = values.map { strdup($0)! }
                        defer { strings.forEach { free($0) } }
                        var native = quenderin_diffusion_request()
                        native.abi_version = 1
                        native.struct_size = MemoryLayout<quenderin_diffusion_request>.size
                        native.model = quenderin_diffusion_model(rawValue: UInt32(request.model.modelKind))
                        native.diffusion_path = UnsafePointer(strings[0])
                        native.text_encoder_path = UnsafePointer(strings[1])
                        native.vae_path = UnsafePointer(strings[2])
                        native.tokenizer_path = request.model.modelKind == 1 ? nil : UnsafePointer(strings[3])
                        native.prompt = UnsafePointer(strings[4])
                        native.negative_prompt = UnsafePointer(strings[5])
                        native.output_path = UnsafePointer(strings[6])
                        native.width = UInt32(request.model.defaults.width)
                        native.height = UInt32(request.model.defaults.height)
                        native.steps = UInt32(request.model.defaults.steps)
                        native.threads = UInt32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount)))
                        native.seed = request.seed
                        let callback = Unmanaged.passRetained(ImageProgressCallback(progress))
                        defer { callback.release() }
                        var error = [CChar](repeating: 0, count: 1024)
                        let status = quenderin_diffusion_generate(engine, &native, { step, total, context in
                            guard let context, total > 0 else { return }
                            Unmanaged<ImageProgressCallback>.fromOpaque(context).takeUnretainedValue()
                                .progress(min(1, Double(step) / Double(total)))
                        }, callback.toOpaque(), &error, error.count)
                        if isCancelled() || status == QUENDERIN_DIFFUSION_CANCELLED { throw CancellationError() }
                        guard status == QUENDERIN_DIFFUSION_OK else {
                            throw ImageGenerationError.invalid(String(cString: error))
                        }
                        let data = try FileHandle(forReadingFrom: request.output)
                        defer { try? data.close() }
                        guard try data.read(upToCount: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
                            throw ImageGenerationError.invalid("The image engine did not produce a valid PNG.")
                        }
                        return request.output
                        #else
                        throw ImageGenerationError.invalid("This build does not include the local image engine.")
                        #endif
                    }
                    // Destruction and cancellation-handle cleanup must finish before a text
                    // engine waiting on the specialist lease can restore its own allocations.
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancel() }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            #if canImport(QuenderinDiffusion)
            if let handle { _ = quenderin_diffusion_cancel(handle) }
            #endif
        }
    }

    private func isCancelled() -> Bool { lock.withLock { cancelled } }
}

#if canImport(QuenderinDiffusion)
private final class ImageProgressCallback {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
}
#endif
