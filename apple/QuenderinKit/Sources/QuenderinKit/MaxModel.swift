import CMaxModel
import Foundation

/// Swift wrapper over the portable MAX boundary. No vendor runner is linked in
/// the app, so `open` with `runner: nil` fails closed. A reviewed backend can
/// pass its `QMaxModelRunner` pointer once it exists.
public struct MaxModelFile: Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct MaxModelError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct MaxModelReceipt: Equatable, Sendable {
    public static let maxFiles = 8
    public static let maxContext = 4096
    public static let maxOutput = 1024
    public static let maxPromptBytes = 8192
    public static let maxFileBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let maxTotalBytes: Int64 = 12 * 1024 * 1024 * 1024
    public static let maxPathBytes = 4096

    public let files: [MaxModelFile]
    public let runnerName: String
    public let backend: String
    public let contextTokens: Int
    public let maxOutputTokens: Int

    public init(files: [MaxModelFile], runnerName: String, backend: String,
                contextTokens: Int, maxOutputTokens: Int) throws {
        guard (1...Self.maxFiles).contains(files.count) else {
            throw MaxModelError(code: 1, message: "One to \(Self.maxFiles) artifact files are required.")
        }
        guard (1...63).contains(runnerName.utf8.count) else {
            throw MaxModelError(code: 1, message: "Runner identity is outside the reviewed range.")
        }
        guard (1...15).contains(backend.utf8.count) else {
            throw MaxModelError(code: 1, message: "Compiled backend identity is outside the reviewed range.")
        }
        guard (1...Self.maxContext).contains(contextTokens),
              (1...Self.maxOutput).contains(maxOutputTokens), maxOutputTokens <= contextTokens else {
            throw MaxModelError(code: 1, message: "Context or output budget is outside the reviewed range.")
        }
        var total: Int64 = 0
        for file in files {
            guard (file.path as NSString).isAbsolutePath, !file.path.contains("\0"),
                  file.path.utf8.count <= Self.maxPathBytes else {
                throw MaxModelError(code: 1, message: "Artifact paths must be absolute app-private paths.")
            }
            guard (1...Self.maxFileBytes).contains(file.bytes) else {
                throw MaxModelError(code: 1, message: "Artifact size is outside the reviewed range.")
            }
            guard file.sha256.utf8.count == 64, file.sha256.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }) else {
                throw MaxModelError(code: 1, message: "Artifact SHA-256 must be 64 lowercase hex characters.")
            }
            guard total <= Self.maxTotalBytes - file.bytes else {
                throw MaxModelError(code: 1, message: "Artifact set exceeds the total byte budget.")
            }
            total += file.bytes
        }
        self.files = files
        self.runnerName = runnerName
        self.backend = backend
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct MaxModelVerification: Equatable, Sendable {
    public let code: Int
    public let message: String
    public var succeeded: Bool { code == 0 }
}

public struct MaxModelCapability: Equatable, Sendable {
    public let code: Int
    public let contractOk: Bool
    public let loadProbePassed: Bool
    public let available: Bool
    public let runner: String
    public let backend: String
    public let reason: String
    public let contextTokens: Int
    public let maxOutputTokens: Int
}

public struct MaxModelPerformance: Equatable, Sendable {
    public let promptTokens: Int
    public let decodedTokens: Int
    public let prefillMs: Double
    public let decodeMs: Double
    public let firstTokenMs: Double
    public let maxGapMs: Double
    public let status: Int
    public let cacheMode: Int

    init(_ value: QMaxModelPerformance) {
        func time(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        promptTokens = Int(value.prompt_tokens)
        decodedTokens = Int(value.decoded_tokens)
        prefillMs = time(value.prefill_ms)
        decodeMs = time(value.decode_ms)
        firstTokenMs = time(value.first_token_ms)
        maxGapMs = time(value.max_gap_ms)
        status = Int(value.status)
        cacheMode = Int(value.cache_mode)
    }

    static let rejected: MaxModelPerformance = {
        var value = QMaxModelPerformance()
        value.status = 6
        return MaxModelPerformance(value)
    }()

    static let cancelled: MaxModelPerformance = {
        var value = QMaxModelPerformance()
        value.status = 1
        return MaxModelPerformance(value)
    }()
}

public struct MaxGenerationResult: Equatable, Sendable {
    public let code: Int
    public let performance: MaxModelPerformance
    public let message: String?
    public var succeeded: Bool { code == 0 }
}

public enum MaxCloseResult: Equatable, Sendable {
    case closed
    case busy
    case invalid
}

private final class CReceipt {
    private let receipt: MaxModelReceipt
    private var paths: [UnsafeMutablePointer<CChar>?] = []
    private var runner: UnsafeMutablePointer<CChar>?
    private var backend: UnsafeMutablePointer<CChar>?
    private var files: [QMaxModelFile] = []

    init(_ receipt: MaxModelReceipt) throws {
        self.receipt = receipt
        var allocated: [UnsafeMutablePointer<CChar>?] = []
        var cFiles: [QMaxModelFile] = []
        for file in receipt.files {
            guard let path = strdup(file.path) else {
                allocated.forEach { if let value = $0 { free(value) } }
                throw MaxModelError(code: 1, message: "Cannot allocate an artifact path.")
            }
            allocated.append(path)
            var value = QMaxModelFile()
            value.path = UnsafePointer(path)
            value.bytes = UInt64(file.bytes)
            qmax_file_set_sha256(&value, file.sha256)
            cFiles.append(value)
        }
        guard let runnerName = strdup(receipt.runnerName), let backendName = strdup(receipt.backend) else {
            allocated.forEach { if let value = $0 { free(value) } }
            throw MaxModelError(code: 1, message: "Cannot allocate the runner identity.")
        }
        paths = allocated
        runner = runnerName
        backend = backendName
        files = cFiles
    }

    deinit {
        paths.forEach { if let value = $0 { free(value) } }
        if let runner { free(runner) }
        if let backend { free(backend) }
    }

    func withReceipt<T>(_ body: (UnsafePointer<QMaxModelReceipt>) throws -> T) rethrows -> T {
        var value = QMaxModelReceipt()
        value.runner_name = UnsafePointer(runner)
        value.runner_abi = qmax_runner_abi()
        value.backend = UnsafePointer(backend)
        value.context_tokens = UInt32(receipt.contextTokens)
        value.max_output_tokens = UInt32(receipt.maxOutputTokens)
        return try files.withUnsafeBufferPointer { buffer in
            value.files = buffer.baseAddress
            value.file_count = buffer.count
            return try withUnsafePointer(to: &value) { try body($0) }
        }
    }
}

private final class EmitBox {
    let sink: (String) -> Bool
    init(_ sink: @escaping (String) -> Bool) { self.sink = sink }
}

private func maxEmitThunk(_ context: UnsafeMutableRawPointer?, _ utf8: UnsafePointer<CChar>?,
                          _ bytes: Int) -> Int32 {
    guard let context, let utf8, bytes >= 0 else { return 0 }
    let box = Unmanaged<EmitBox>.fromOpaque(context).takeUnretainedValue()
    guard let text = String(data: Data(bytes: utf8, count: bytes), encoding: .utf8) else { return 0 }
    return box.sink(text) ? 1 : 0
}

private func maxShouldStopThunk(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<CancelFlag>.fromOpaque(context).takeUnretainedValue().isSet ? 1 : 0
}

private func maxMessage(_ error: inout QMaxError) -> String {
    guard let text = qmax_error_message(&error) else { return "" }
    return String(cString: text)
}

public enum MaxModelBinding {
    public static func verify(_ receipt: MaxModelReceipt) -> MaxModelVerification {
        do {
            let staged = try CReceipt(receipt)
            var error = QMaxError()
            let code = staged.withReceipt { qmax_model_verify($0, &error) }
            return MaxModelVerification(code: Int(qmax_code_value(code)), message: maxMessage(&error))
        } catch let error as MaxModelError {
            return MaxModelVerification(code: error.code, message: error.message)
        } catch {
            return MaxModelVerification(code: 1, message: "Cannot prepare the MAX receipt.")
        }
    }

    public static func capability(_ receipt: MaxModelReceipt,
                                  runner: UnsafePointer<QMaxModelRunner>?,
                                  loadProbePassed: Bool = false) -> MaxModelCapability {
        guard let runner else {
            return MaxModelCapability(code: 2, contractOk: false, loadProbePassed: loadProbePassed,
                                      available: false, runner: "", backend: "",
                                      reason: "No verified MAX runner is linked.", contextTokens: 0,
                                      maxOutputTokens: 0)
        }
        do {
            let staged = try CReceipt(receipt)
            var value = QMaxModelCapability()
            let code = staged.withReceipt {
                qmax_model_capability(runner, $0, loadProbePassed ? 1 : 0, &value)
            }
            return MaxModelCapability(
                code: Int(qmax_code_value(code)),
                contractOk: value.contract_ok != 0,
                loadProbePassed: value.load_probe_passed != 0,
                available: value.available != 0,
                runner: String(cString: qmax_capability_runner(&value)),
                backend: String(cString: qmax_capability_backend(&value)),
                reason: String(cString: qmax_capability_reason(&value)),
                contextTokens: Int(value.context_tokens),
                maxOutputTokens: Int(value.max_output_tokens)
            )
        } catch let error as MaxModelError {
            return MaxModelCapability(code: error.code, contractOk: false, loadProbePassed: false,
                                      available: false, runner: "", backend: "", reason: error.message,
                                      contextTokens: 0, maxOutputTokens: 0)
        } catch {
            return MaxModelCapability(code: 1, contractOk: false, loadProbePassed: false, available: false,
                                      runner: "", backend: "", reason: "Cannot prepare the MAX receipt.",
                                      contextTokens: 0, maxOutputTokens: 0)
        }
    }

    public static func open(_ receipt: MaxModelReceipt,
                            runner: UnsafePointer<QMaxModelRunner>?) -> Result<MaxModelHandle, MaxModelError> {
        guard let runner else {
            return .failure(MaxModelError(code: 2, message: "No verified MAX runner is linked."))
        }
        do {
            let staged = try CReceipt(receipt)
            var error = QMaxError()
            var model: OpaquePointer?
            let code = staged.withReceipt { qmax_model_open(runner, $0, &model, &error) }
            let value = Int(qmax_code_value(code))
            guard value == 0, let model else {
                return .failure(MaxModelError(code: value == 0 ? 2 : value,
                                              message: maxMessage(&error).isEmpty
                                              ? "The MAX model could not be opened." : maxMessage(&error)))
            }
            return .success(MaxModelHandle(model: model, maxOutputTokens: receipt.maxOutputTokens))
        } catch let error as MaxModelError {
            return .failure(error)
        } catch {
            return .failure(MaxModelError(code: 1, message: "Cannot prepare the MAX receipt."))
        }
    }
}

/// A caller-visible run identity. Mint with `MaxModelHandle.makeGenerationToken()`;
/// a stale token cannot cancel a later run.
public struct MaxGenerationToken: Equatable, Sendable {
    fileprivate let value: UInt64
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func set() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// One verified installation. Generation is serialized; `cancel()` calls the
/// native atomic lease directly, and `close()` waits for an active generation
/// to drain. Never call `close()` from the token callback; it returns `.busy`.
public final class MaxModelHandle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.quenderin.max.model")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let pointerLock = NSLock()
    private let condition = NSCondition()
    private var generating = false
    private var model: OpaquePointer?
    private let maxOutputTokens: Int
    private var nextToken: UInt64 = 0
    private var currentToken: MaxGenerationToken?
    private var pendingCancelToken: MaxGenerationToken?
    private var cancelFlag: CancelFlag?

    init(model: OpaquePointer, maxOutputTokens: Int) {
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        pointerLock.lock()
        if let model { _ = qmax_model_close(model) }
        pointerLock.unlock()
    }

    public var isClosed: Bool {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        return model == nil
    }

    private var busyResult: MaxGenerationResult {
        MaxGenerationResult(code: Int(qmax_code_value(qmax_code_busy())), performance: .rejected,
                            message: "Generation is already in progress for this model.")
    }

    private var closedResult: MaxGenerationResult {
        MaxGenerationResult(code: Int(qmax_code_value(qmax_code_invalid())), performance: .rejected,
                            message: "The MAX model handle is closed.")
    }

    private func invalidResult(_ message: String) -> MaxGenerationResult {
        MaxGenerationResult(code: Int(qmax_code_value(qmax_code_invalid())), performance: .rejected,
                            message: message)
    }

    public func makeGenerationToken() -> MaxGenerationToken {
        condition.lock()
        nextToken &+= 1
        let token = MaxGenerationToken(value: nextToken)
        condition.unlock()
        return token
    }

    private var cancelledResult: MaxGenerationResult {
        MaxGenerationResult(code: Int(qmax_code_value(qmax_code_cancelled())),
                            performance: .cancelled,
                            message: "Generation cancelled.")
    }

    public func generate(prompt: String, maxTokens: Int? = nil, temperature: Float = 0.7,
                         topP: Float = 0.9, seed: UInt32 = 0,
                         token: MaxGenerationToken? = nil,
                         onToken: @escaping (String) -> Bool) -> MaxGenerationResult {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return busyResult }
        let bytes = prompt.utf8.map { Int8(bitPattern: $0) }
        guard !bytes.isEmpty, bytes.count <= MaxModelReceipt.maxPromptBytes else {
            return invalidResult("Prompt is outside the bounded UTF-8 request size.")
        }
        let budget = maxTokens ?? maxOutputTokens
        guard (1...maxOutputTokens).contains(budget) else {
            return invalidResult("Requested output exceeds the verified output budget.")
        }
        guard (0...2).contains(temperature), topP > 0, topP <= 1 else {
            return invalidResult("Sampling parameters are outside the reviewed range.")
        }
        let run = token ?? makeGenerationToken()
        condition.lock()
        if generating {
            condition.unlock()
            return busyResult
        }
        if pendingCancelToken == run {
            pendingCancelToken = nil
            condition.unlock()
            return cancelledResult
        }
        pendingCancelToken = nil
        generating = true
        currentToken = run
        let flag = CancelFlag()
        cancelFlag = flag
        condition.unlock()
        defer {
            condition.lock()
            generating = false
            currentToken = nil
            cancelFlag = nil
            condition.broadcast()
            condition.unlock()
        }
        return queue.sync {
            pointerLock.lock()
            guard let model else {
                pointerLock.unlock()
                return closedResult
            }
            pointerLock.unlock()
            if flag.isSet { return cancelledResult }
            var request = QMaxModelRequest()
            request.max_tokens = UInt32(budget)
            request.temperature = temperature
            request.top_p = topP
            request.seed = seed
            var performance = QMaxModelPerformance()
            var error = QMaxError()
            let box = EmitBox(onToken)
            let code = bytes.withUnsafeBufferPointer { buffer -> QMaxCode in
                request.prompt = buffer.baseAddress
                request.prompt_bytes = buffer.count
                return withExtendedLifetime(box) {
                    withExtendedLifetime(flag) {
                        qmax_model_generate(model, &request, maxEmitThunk,
                                            Unmanaged.passUnretained(box).toOpaque(),
                                            maxShouldStopThunk,
                                            Unmanaged.passUnretained(flag).toOpaque(),
                                            &performance, &error)
                    }
                }
            }
            let message = maxMessage(&error)
            return MaxGenerationResult(code: Int(qmax_code_value(code)),
                                       performance: MaxModelPerformance(performance),
                                       message: message.isEmpty ? nil : message)
        }
    }

    /// Cancels the current run. Holds the pointer lock across the bounded native
    /// call so a concurrent close cannot free the model between check and cancel.
    @discardableResult
    public func cancel() -> Bool {
        condition.lock()
        let active = currentToken
        condition.unlock()
        if let active { return cancel(active) }
        pointerLock.lock()
        defer { pointerLock.unlock() }
        guard let model else { return false }
        qmax_model_cancel(model)
        return true
    }

    /// Cancels [token], including a run that has not reached native admission.
    /// A stale token never cancels a different active run.
    @discardableResult
    public func cancel(_ token: MaxGenerationToken) -> Bool {
        condition.lock()
        if generating {
            if currentToken == token {
                cancelFlag?.set()
                condition.unlock()
                return cancelNative()
            }
            condition.unlock()
            return false
        }
        pendingCancelToken = token
        condition.unlock()
        return true
    }

    private func cancelNative() -> Bool {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        guard let model else { return false }
        qmax_model_cancel(model)
        return true
    }

    /// Waits for an active generation to drain, then closes. Returns `.busy`
    /// when called from the generation callback itself.
    public func close() -> MaxCloseResult {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return .busy }
        condition.lock()
        while generating { condition.wait() }
        condition.unlock()
        return queue.sync {
            pointerLock.lock()
            defer { pointerLock.unlock() }
            guard let model else { return .closed }
            let code = qmax_model_close(model)
            let value = Int(qmax_code_value(code))
            if value == 0 {
                self.model = nil
                return .closed
            }
            return value == Int(qmax_code_value(qmax_code_busy())) ? .busy : .invalid
        }
    }
}
