import Foundation
#if canImport(QuenderinSpeech)
import QuenderinSpeech
#endif

public struct SpeechSegmentResult: Codable, Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
}

public struct SpeechTranscriptionRequest: Sendable {
    public let model: SpeechModel
    public let directory: URL
    public let wavURL: URL
    public let vad: SpeechVadModel?
    public let language: String?
    public let prompt: String?
    public let formatting: SpeechFormattingOptions
    public let threads: Int
    public let translate: Bool
    public let timestamps: Bool

    public init(
        model: SpeechModel,
        directory: URL,
        wavURL: URL,
        vad: SpeechVadModel? = nil,
        language: String? = nil,
        prompt: String? = nil,
        formatting: SpeechFormattingOptions = SpeechFormattingOptions(),
        threads: Int = 4,
        translate: Bool = false,
        timestamps: Bool = false
    ) {
        self.model = model
        self.directory = directory
        self.wavURL = wavURL
        self.vad = vad
        self.language = language
        self.prompt = prompt
        self.formatting = formatting
        self.threads = threads
        self.translate = translate
        self.timestamps = timestamps
    }
}

public struct SpeechTranscriptionResult: Sendable, Equatable {
    public let text: String
    public let rawText: String
    public let language: String
    public let backend: String
    public let durationMs: Int
    public let truncated: Bool
    public let segments: [SpeechSegmentResult]
}

public protocol SpeechTranscriptionEngine: Sendable {
    var available: Bool { get }
    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscriptionResult
    func cancel()
}

/// Thread-safe wrapper over QuenderinSpeech C ABI (`quenderin_speech_*`).
/// Joins native cleanup before resuming the Swift continuation and checks ABI compatibility first.
public final class NativeSpeechEngine: SpeechTranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.quenderin.speech", qos: .userInitiated)
    private var running = false
    private var cancelled = false
    #if canImport(QuenderinSpeech)
    private var handle: OpaquePointer?
    #endif

    public init() {}

    public var available: Bool {
        #if canImport(QuenderinSpeech)
        return quenderin_speech_abi() == 1
        #else
        return false
        #endif
    }

    public func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscriptionResult {
        guard available else {
            throw SpeechEngineError.invalid("This build does not include the native QuenderinSpeech runtime.")
        }
        try request.model.validate()
        guard (1...8).contains(request.threads) else {
            throw SpeechEngineError.invalid("Speech thread count must be between 1 and 8.")
        }
        if let prompt = request.prompt {
            guard !prompt.contains("\0"), prompt.utf8.count <= 8192 else {
                throw SpeechEngineError.invalid("Speech context prompt must be at most 8,192 bytes without NUL bytes.")
            }
        }
        let wavAttrs = try request.wavURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard wavAttrs.isRegularFile == true, wavAttrs.isSymbolicLink != true,
              let wavSize = wavAttrs.fileSize, wavSize >= 44, wavSize <= 64 * 1024 * 1024 else {
            throw SpeechEngineError.invalid("Audio input must be a regular local .wav file between 44 bytes and 64 MiB.")
        }
        try Task.checkCancellation()
        try lock.withLock {
            guard !running else {
                throw SpeechEngineError.invalid("A speech transcription is already running.")
            }
            running = true
            cancelled = false
        }

        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechTranscriptionResult, Error>) in
                queue.async { [self] in
                    let result: Result<SpeechTranscriptionResult, Error> = Result {
                        try self.transcribeSync(request)
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func transcribeSync(_ request: SpeechTranscriptionRequest) throws -> SpeechTranscriptionResult {
        defer { lock.withLock { running = false } }
        try SpeechModelInstaller.verify(
            request.model,
            in: request.directory,
            vad: request.vad,
            cancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        #if canImport(QuenderinSpeech)
        guard let engine = quenderin_speech_create() else {
            throw SpeechEngineError.invalid("The native speech engine could not start.")
        }
        lock.withLock {
            handle = engine
            if cancelled { _ = quenderin_speech_cancel(engine) }
        }
        defer {
            lock.withLock { handle = nil }
            _ = quenderin_speech_destroy(engine)
        }

        guard let modelFile = request.model.localFilename else {
            throw SpeechEngineError.invalid("Speech model lacks a local filename.")
        }
        let modelPath = request.directory.appendingPathComponent(modelFile).path
        let vadPath = request.vad.map { request.directory.appendingPathComponent($0.localFilename).path } ?? ""
        let wavPath = request.wavURL.path(percentEncoded: false)
        let lang = request.language ?? ""
        let promptStr = request.prompt ?? ""
        let cStrings: [UnsafeMutablePointer<CChar>] = [modelPath, vadPath, wavPath, lang, promptStr].map { value in
            value.withCString { strdup($0)! }
        }
        defer { cStrings.forEach { free($0) } }

        let vocabItems = request.formatting.vocabulary
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)
        let vocabC: [UnsafeMutablePointer<CChar>] = vocabItems.map { value in
            value.withCString { strdup($0)! }
        }
        defer { vocabC.forEach { free($0) } }
        let vocabConstPtrs: [UnsafePointer<CChar>?] = vocabC.map { UnsafePointer($0) }

        var nativeReq = quenderin_speech_request()
        nativeReq.abi_version = 1
        nativeReq.struct_size = MemoryLayout<quenderin_speech_request>.size
        nativeReq.model_path = UnsafePointer(cStrings[0])
        nativeReq.vad_path = vadPath.isEmpty ? nil : UnsafePointer(cStrings[1])
        nativeReq.wav_path = UnsafePointer(cStrings[2])
        nativeReq.pcm_f32 = nil
        nativeReq.pcm_samples = 0
        nativeReq.sample_rate = 16000
        nativeReq.language = lang.isEmpty ? nil : UnsafePointer(cStrings[3])
        nativeReq.prompt = promptStr.isEmpty ? nil : UnsafePointer(cStrings[4])
        nativeReq.threads = UInt32(request.threads)
        nativeReq.translate = request.translate
        nativeReq.timestamps = request.timestamps

        var nativeRes = quenderin_speech_result()
        defer { quenderin_speech_result_free(&nativeRes) }
        var errorBuf = [CChar](repeating: 0, count: 1024)

        let status: quenderin_speech_status = vocabConstPtrs.withUnsafeBufferPointer { buf in
            nativeReq.vocabulary = buf.isEmpty ? nil : buf.baseAddress
            nativeReq.vocabulary_count = UInt32(buf.count)
            return quenderin_speech_transcribe(engine, &nativeReq, &nativeRes, &errorBuf, errorBuf.count)
        }
        if isCancelled() || nativeRes.aborted || status == QUENDERIN_SPEECH_CANCELLED {
            throw CancellationError()
        }
        guard status == QUENDERIN_SPEECH_OK else {
            throw SpeechEngineError.invalid(String(cString: errorBuf))
        }

        let rawText = nativeRes.text.map { String(cString: $0) } ?? ""
        let detectedLang = nativeRes.language.map { String(cString: $0) } ?? (request.language ?? "")
        let backend = nativeRes.backend.map { String(cString: $0) } ?? "transcribe.cpp"
        var segments: [SpeechSegmentResult] = []
        if let segJson = nativeRes.segments_json,
           let segData = String(cString: segJson).data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SpeechSegmentResult].self, from: segData) {
            segments = decoded
        }
        let formatted = TranscriptFormatter.format(rawText, options: request.formatting)
        return SpeechTranscriptionResult(
            text: formatted,
            rawText: rawText,
            language: detectedLang,
            backend: backend,
            durationMs: Int(nativeRes.duration_ms),
            truncated: nativeRes.truncated,
            segments: segments
        )
        #else
        throw SpeechEngineError.invalid("This build does not include the native QuenderinSpeech runtime.")
        #endif
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            #if canImport(QuenderinSpeech)
            if let handle {
                _ = quenderin_speech_cancel(handle)
            }
            #endif
        }
    }

    private func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }
}
