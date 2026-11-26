#if os(macOS)
import Foundation
import Combine
import Network

/// Opt-in loopback-only (`127.0.0.1`) OpenAI-compatible HTTP server for the native macOS app.
///
/// Security & privacy invariants:
/// - OFF by default (`AppSettings.shared.localAPIEnabled == false`).
/// - Binds exclusively to `127.0.0.1:<port>` with `NWParameters.acceptLocalOnly = true`.
/// - Rejects non-loopback `Host` headers (DNS-rebinding defence), any `Origin` header (blocks
///   browser pages; never emits CORS headers), non-JSON `POST` bodies, and invalid Bearer keys
///   when an API key is configured.
/// - Serializes inference through the app's existing exclusive engine lease so Chat and the
///   Local API never run the model concurrently (waits up to 30 s, then returns 503 `server_busy`).
/// - Cancels in-flight generation immediately if the client disconnects.
/// - Never logs prompts, messages, replies, or API keys — keeps only a count of requests served.
@MainActor
public final class LocalAPIServer: ObservableObject {
    public static let shared = LocalAPIServer()

    public enum Status: Equatable, Sendable {
        case off
        case starting(port: UInt16)
        case listening(port: UInt16)
        case error(String)
    }

    @Published public private(set) var status: Status = .off
    @Published public private(set) var requestsServed: Int = 0

    /// Human-readable status string shown in Settings → Local API (for developers).
    public var statusLine: String {
        switch status {
        case .off:
            return "Off"
        case .starting(let port):
            return "Starting on http://127.0.0.1:\(port)/v1…"
        case .listening(let port):
            return "Listening on http://127.0.0.1:\(port)/v1"
        case .error(let message):
            return message
        }
    }

    /// Configured base URL for copy/display.
    public var baseURLString: String {
        let port = LocalAPIGuard.clampPort(AppSettings.shared.localAPIPort)
        return "http://127.0.0.1:\(port)/v1"
    }

    private static let busyTimeoutSeconds: Double = 30.0

    private let queue = DispatchQueue(label: "ai.quenderin.local-api")
    private let requestGate = LocalAPIRequestGate()
    private var listener: NWListener?
    private var activePort: UInt16 = LocalAPIGuard.defaultPort
    private var connections: [ObjectIdentifier: LocalAPIConnection] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var configured = false

    private weak var onboarding: OnboardingModel?
    private var engine: InferenceEngine?

    private init() {}

    /// Binds the server to the app's shared `InferenceEngine` and `OnboardingModel`, then
    /// observes `AppSettings.shared` so toggling the switch or changing the port starts,
    /// restarts, or stops the listener automatically.
    public func configure(engine: InferenceEngine, onboarding: OnboardingModel) {
        self.engine = engine
        self.onboarding = onboarding
        guard !configured else {
            applySettings()
            return
        }
        configured = true

        let settings = AppSettings.shared
        settings.$localAPIEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applySettings() }
            }
            .store(in: &cancellables)

        settings.$localAPIPort
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, AppSettings.shared.localAPIEnabled else { return }
                    self.restart()
                }
            }
            .store(in: &cancellables)

        applySettings()
    }

    /// Reconciles live listener state with `AppSettings.shared`.
    public func applySettings() {
        let settings = AppSettings.shared
        if settings.localAPIEnabled {
            let desiredPort = LocalAPIGuard.clampPort(settings.localAPIPort)
            if listener != nil, activePort == desiredPort {
                return
            }
            start(port: desiredPort)
        } else {
            stop()
        }
    }

    /// Restarts the listener on the currently configured port if enabled.
    public func restart() {
        stop()
        if AppSettings.shared.localAPIEnabled {
            start(port: LocalAPIGuard.clampPort(AppSettings.shared.localAPIPort))
        }
    }

    /// Stops accepting new connections and cancels active ones.
    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        for conn in active {
            conn.cancel()
        }
        status = .off
    }

    /// Synchronous shutdown hook called from `applicationShouldTerminate` right before `_exit(0)`.
    public func stopImmediately() {
        stop()
    }

    private func start(port: UInt16) {
        stop()
        activePort = port
        status = .starting(port: port)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .error("Invalid port \(port). Choose a port between 1024 and 65535.")
            return
        }

        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        do {
            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.status = .listening(port: port)
                    case .failed(let error):
                        self.listener?.cancel()
                        self.listener = nil
                        self.status = .error("Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)")
                    case .waiting(let error):
                        self.status = .error("Waiting on 127.0.0.1:\(port): \(error.localizedDescription)")
                    case .cancelled:
                        if case .listening = self.status {
                            self.status = .off
                        } else if case .starting = self.status {
                            self.status = .off
                        }
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] nwConnection in
                Task { @MainActor [weak self] in
                    self?.accept(nwConnection, port: port)
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            status = .error("Could not start local API on port \(port): \(error.localizedDescription)")
        }
    }

    private func accept(_ nwConnection: NWConnection, port: UInt16) {
        let conn = LocalAPIConnection(connection: nwConnection, queue: queue)
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: id)
            }
        }
        conn.onRequest = { [weak self, weak conn] request in
            guard let self, let conn else { return }
            let task = Task { [weak self, weak conn] in
                guard let self, let conn else { return }
                await self.handleRequest(request, port: port, connection: conn)
            }
            conn.attachWorkTask(task)
        }
        conn.start()
    }

    // MARK: - Request Handling (privacy: never log prompts or replies)

    private func handleRequest(_ request: LocalHTTPRequest, port: UInt16, connection: LocalAPIConnection) async {
        let requiredKey = AppSettings.shared.localAPIKey
        if let rejection = LocalAPIGuard.check(request, port: port, requiredAPIKey: requiredKey.isEmpty ? nil : requiredKey) {
            connection.sendAndClose(LocalHTTPResponse.error(rejection))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let models = await availableModels()
            requestsServed += 1
            connection.sendAndClose(LocalHTTPResponse.json(statusCode: 200, body: LocalAPICodec.encodeModelsList(models)))

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(request, connection: connection)

        case (_, "/v1/models"), (_, "/v1/chat/completions"):
            connection.sendAndClose(LocalHTTPResponse.error(.methodNotAllowed()))

        default:
            connection.sendAndClose(LocalHTTPResponse.error(.notFound("Unknown endpoint '\(request.path)'.")))
        }
    }

    private func handleChatCompletions(_ request: LocalHTTPRequest, connection: LocalAPIConnection) async {
        guard let engine else {
            connection.sendAndClose(LocalHTTPResponse.error(.serviceUnavailable("Inference engine is not ready yet.")))
            return
        }

        let models = await availableModels()
        let activeID = await currentActiveModelID()
        let availableIDs = models.map(\.id)

        let chatReq: LocalAPIChatRequest
        switch LocalAPICodec.decodeChatRequest(request.body, availableModelIDs: availableIDs, activeModelID: activeID) {
        case .failure(let apiError):
            connection.sendAndClose(LocalHTTPResponse.error(apiError))
            return
        case .success(let decoded):
            chatReq = decoded
        }

        let deadline = ContinuousClock.now + .milliseconds(Int(Self.busyTimeoutSeconds * 1000))

        // Serialize API requests one at a time (waiting up to 30 s).
        let acquiredGate = await requestGate.acquire(deadline: deadline)
        guard acquiredGate else {
            if !Task.isCancelled && !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.serverBusy()))
            }
            return
        }
        defer { Task { await requestGate.release() } }

        // Ensure the requested (or active) model is loaded through the existing load path.
        if let loadErr = await ensureModelLoaded(modelID: chatReq.model, engine: engine, deadline: deadline) {
            if !Task.isCancelled && !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(loadErr))
            }
            return
        }

        let remaining = remainingSeconds(until: deadline)
        let lease: ExclusiveInferenceLease
        do {
            lease = try await engine.acquireExclusiveInferenceLease(timeoutSeconds: remaining)
        } catch is CancellationError {
            return
        } catch {
            if !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.serverBusy()))
            }
            return
        }

        connection.setCancelInferenceHook {
            lease.requestCancel()
        }
        defer {
            connection.setCancelInferenceHook(nil)
            Task { await lease.release() }
        }

        if connection.isDisconnected || Task.isCancelled {
            lease.requestCancel()
            return
        }

        let (systemPrompt, turns) = chatReq.splitPrompt
        let history: [ChatMessage] = turns.map { msg in
            ChatMessage(role: msg.role == .assistant ? .assistant : .user, text: msg.content)
        }
        let options = GenerationOptions(
            maxTokens: chatReq.maxTokens,
            temperature: chatReq.temperature,
            topP: chatReq.topP,
            stopSequences: chatReq.stop,
            gbnfGrammar: chatReq.responseFormat.gbnfGrammar,
            collectPerformance: false,
            thinkingMode: chatReq.effectiveThinkingMode
        )

        let stream: AsyncThrowingStream<String, Error>
        do {
            stream = try await lease.generateChat(system: systemPrompt, history: history, options: options)
        } catch InferenceError.modelNotLoaded {
            connection.sendAndClose(LocalHTTPResponse.error(.serviceUnavailable("No model is loaded in Quenderin.")))
            return
        } catch InferenceError.cancelled {
            return
        } catch {
            connection.sendAndClose(LocalHTTPResponse.error(.internalError("Generation failed: \(error.localizedDescription)")))
            return
        }

        let completionID = LocalAPICodec.makeCompletionID()
        let created = Int(Date().timeIntervalSince1970)
        let splitThinking = chatReq.think && chatReq.effectiveThinkingMode == .show

        if chatReq.stream {
            await streamResponse(
                stream: stream,
                lease: lease,
                connection: connection,
                id: completionID,
                created: created,
                model: chatReq.model,
                splitThinking: splitThinking
            )
        } else {
            await bufferedResponse(
                stream: stream,
                lease: lease,
                connection: connection,
                id: completionID,
                created: created,
                model: chatReq.model,
                splitThinking: splitThinking
            )
        }
        await lease.release()
    }

    private func streamResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        splitThinking: Bool
    ) async {
        guard await connection.send(LocalHTTPResponse.sseHeaders()) else {
            lease.requestCancel()
            return
        }
        let roleChunk = LocalAPICodec.encodeStreamChunk(id: id, created: created, model: model, role: "assistant")
        guard await connection.send(roleChunk) else {
            lease.requestCancel()
            return
        }

        var splitter = ThinkingSplitter()
        do {
            for try await piece in stream {
                if Task.isCancelled || connection.isDisconnected {
                    lease.requestCancel()
                    return
                }
                if splitThinking {
                    let delta = splitter.feed(piece)
                    if !delta.thinking.isEmpty {
                        let chunk = LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, reasoningContent: delta.thinking
                        )
                        guard await connection.send(chunk) else {
                            lease.requestCancel()
                            return
                        }
                    }
                    if !delta.answer.isEmpty {
                        let chunk = LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, content: delta.answer
                        )
                        guard await connection.send(chunk) else {
                            lease.requestCancel()
                            return
                        }
                    }
                } else if !piece.isEmpty {
                    let chunk = LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, content: piece
                    )
                    guard await connection.send(chunk) else {
                        lease.requestCancel()
                        return
                    }
                }
            }

            if splitThinking {
                let tail = splitter.finish()
                if !tail.thinking.isEmpty {
                    let chunk = LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, reasoningContent: tail.thinking
                    )
                    _ = await connection.send(chunk)
                }
                if !tail.answer.isEmpty {
                    let chunk = LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, content: tail.answer
                    )
                    _ = await connection.send(chunk)
                }
            }

            let cap = await lease.chatCapStatus()
            let finishReason: LocalAPIFinishReason = (cap == .hit) ? .length : .stop
            var tailData = LocalAPICodec.encodeStreamChunk(
                id: id, created: created, model: model, finishReason: finishReason
            )
            tailData.append(LocalAPICodec.streamDoneFrame)
            requestsServed += 1
            connection.sendAndClose(tailData)
        } catch {
            lease.requestCancel()
            connection.cancel()
        }
    }

    private func bufferedResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        splitThinking: Bool
    ) async {
        var splitter = ThinkingSplitter()
        var reasoning = ""
        var answer = ""
        do {
            for try await piece in stream {
                if Task.isCancelled || connection.isDisconnected {
                    lease.requestCancel()
                    return
                }
                if splitThinking {
                    let delta = splitter.feed(piece)
                    if !delta.thinking.isEmpty { reasoning += delta.thinking }
                    if !delta.answer.isEmpty { answer += delta.answer }
                } else {
                    answer += piece
                }
            }
            if splitThinking {
                let tail = splitter.finish()
                if !tail.thinking.isEmpty { reasoning += tail.thinking }
                if !tail.answer.isEmpty { answer += tail.answer }
            }
            if Task.isCancelled || connection.isDisconnected {
                lease.requestCancel()
                return
            }
            let cap = await lease.chatCapStatus()
            let finishReason: LocalAPIFinishReason = (cap == .hit) ? .length : .stop
            let body = LocalAPICodec.encodeChatCompletion(
                id: id,
                created: created,
                model: model,
                content: answer,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                includeReasoning: splitThinking,
                finishReason: finishReason,
                usage: nil
            )
            requestsServed += 1
            connection.sendAndClose(LocalHTTPResponse.json(statusCode: 200, body: body))
        } catch is CancellationError {
            lease.requestCancel()
        } catch {
            lease.requestCancel()
            if !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.internalError("Generation failed: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Model Discovery & On-Demand Load (existing load path only; never downloads)

    private func currentActiveModelID() async -> String? {
        if let loaded = await engine?.loadedModelID(), !loaded.isEmpty {
            return loaded
        }
        if let onboarding, case .ready(let entry) = onboarding.phase {
            return entry.id
        }
        if let manual = AutomaticModelPreferences.shared.manualModelID,
           !manual.isEmpty,
           let entry = resolveInstalledEntry(id: manual) {
            return entry.id
        }
        if let remembered = UserDefaults.standard.string(forKey: OnboardingModel.activeModelDefaultsKey),
           !remembered.isEmpty,
           let entry = resolveInstalledEntry(id: remembered) {
            return entry.id
        }
        return nil
    }

    private func availableModels() async -> [LocalAPIModelInfo] {
        let activeID = await currentActiveModelID()
        let manager = ModelManager(
            storage: OnboardingModel.defaultModelStorage(),
            activeModelID: activeID
        )
        var seen: Set<String> = []
        var result: [LocalAPIModelInfo] = []

        if let activeID, !activeID.isEmpty {
            seen.insert(activeID)
            result.append(LocalAPIModelInfo(id: activeID))
        }

        for installed in manager.installed() where ModelRuntimeSupport.supports(installed.model) {
            if seen.insert(installed.model.id).inserted {
                result.append(LocalAPIModelInfo(id: installed.model.id))
            }
        }

        return result
    }

    private func resolveInstalledEntry(id: String) -> ModelEntry? {
        guard let entry = ModelCatalog.entry(id: id) ?? SideloadedModels.shared.entry(id: id),
              ModelRuntimeSupport.supports(entry),
              OnboardingModel.resolveModelFile(model: entry) != nil else {
            return nil
        }
        return entry
    }

    private func ensureModelLoaded(
        modelID: String,
        engine: InferenceEngine,
        deadline: ContinuousClock.Instant
    ) async -> LocalAPIError? {
        if await engine.loadedModelID() == modelID {
            return nil
        }

        // Wait if another generation, install, or specialist workflow is active.
        while await engine.hasActiveInference() || (onboarding?.isInstalling ?? false) || (onboarding?.isSpecialistActive ?? false) {
            if Task.isCancelled { return nil }
            if ContinuousClock.now >= deadline {
                return .serverBusy()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if await engine.loadedModelID() == modelID {
            return nil
        }

        guard let entry = resolveInstalledEntry(id: modelID) else {
            return .serviceUnavailable("No installed model file found for '\(modelID)'. Download a model in Quenderin first.")
        }

        guard let onboarding else {
            return .serviceUnavailable("Quenderin is still starting up. Try again shortly.")
        }

        // Load through the existing onboarding load path (file is verified on disk above, so no download occurs).
        await onboarding.install(entry)
        if await engine.loadedModelID() == entry.id {
            return nil
        }
        if case .failed(let reason) = onboarding.phase {
            return .serviceUnavailable("Could not load model '\(entry.id)': \(reason)")
        }
        return .serviceUnavailable("Could not load model '\(entry.id)'. Open Quenderin to check model status.")
    }

    private func remainingSeconds(until deadline: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now.duration(to: deadline)
        let secs = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return max(0, secs)
    }
}

// MARK: - FIFO Request Serialization Gate

private actor LocalAPIRequestGate {
    private var busy = false

    func acquire(deadline: ContinuousClock.Instant) async -> Bool {
        while busy {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if Task.isCancelled { return false }
        busy = true
        return true
    }

    func release() {
        busy = false
    }
}

// MARK: - Per-Connection Bounded HTTP Reader & Writer

private final class LocalAPIConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer = Data()
    private var parsedRequest = false
    private var finished = false
    private var disconnected = false
    private var workTask: Task<Void, Never>?
    private var cancelInferenceHook: (() -> Void)?
    private var readTimeoutItem: DispatchWorkItem?

    var onRequest: ((LocalHTTPRequest) -> Void)?
    var onFinished: (() -> Void)?

    var isDisconnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnected
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func attachWorkTask(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyDisconnected = disconnected
        if !alreadyDisconnected {
            workTask = task
        }
        lock.unlock()
        if alreadyDisconnected {
            task.cancel()
        }
    }

    func setCancelInferenceHook(_ hook: (() -> Void)?) {
        lock.lock()
        let alreadyDisconnected = disconnected
        cancelInferenceHook = alreadyDisconnected ? nil : hook
        lock.unlock()
        if alreadyDisconnected {
            hook?()
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.markDisconnected()
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyParsed = self.parsedRequest
            let alreadyClosed = self.disconnected
            self.lock.unlock()
            if !alreadyParsed && !alreadyClosed {
                self.sendAndClose(LocalHTTPResponse.error(.badRequest("Timed out waiting for HTTP request.")))
            }
        }
        lock.lock()
        readTimeoutItem = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.markDisconnected()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            switch LocalHTTPRequest.parse(self.buffer) {
            case .complete(let request, _):
                self.cancelReadTimeout(markParsed: true)
                self.buffer.removeAll(keepingCapacity: false)
                self.onRequest?(request)
            case .error(let parseErr):
                self.cancelReadTimeout(markParsed: true)
                self.sendAndClose(LocalHTTPResponse.error(.fromParseError(parseErr)))
            case .needMore:
                if isComplete {
                    self.cancelReadTimeout(markParsed: true)
                    if !self.buffer.isEmpty {
                        self.sendAndClose(LocalHTTPResponse.error(.badRequest("Incomplete HTTP request.")))
                    } else {
                        self.cancel()
                    }
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func cancelReadTimeout(markParsed: Bool) {
        lock.lock()
        if markParsed { parsedRequest = true }
        let item = readTimeoutItem
        readTimeoutItem = nil
        lock.unlock()
        item?.cancel()
    }

    func send(_ data: Data) async -> Bool {
        if isDisconnected { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.markDisconnected()
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            })
        }
    }

    func sendAndClose(_ data: Data) {
        cancelReadTimeout(markParsed: false)
        connection.send(
            content: data,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.cancel()
            }
        )
    }

    func cancel() {
        cancelReadTimeout(markParsed: false)
        markDisconnected()
        connection.cancel()
    }

    private func markDisconnected() {
        lock.lock()
        let wasDisconnected = disconnected
        disconnected = true
        let task = workTask
        workTask = nil
        let hook = cancelInferenceHook
        cancelInferenceHook = nil
        let shouldNotifyFinished = !finished
        finished = true
        lock.unlock()

        if !wasDisconnected {
            hook?()
            task?.cancel()
        }
        if shouldNotifyFinished {
            onFinished?()
        }
    }
}
#endif
