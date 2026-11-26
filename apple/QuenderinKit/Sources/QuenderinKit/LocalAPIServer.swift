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
    private static let writeTimeoutSeconds: Double = 15.0
    private static let maxConcurrentConnections: Int = 16

    private let queue = DispatchQueue(label: "ai.quenderin.local-api")
    private let requestGate = LocalAPIRequestGate()
    private var listener: NWListener?
    private var listenerGeneration: UInt64 = 0
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
        listenerGeneration &+= 1
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
        let generation = listenerGeneration
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
            newListener.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listener === newListener, self.listenerGeneration == generation else { return }
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
            newListener.newConnectionHandler = { @Sendable [weak self] nwConnection in
                Task { @MainActor [weak self] in
                    guard let self else {
                        nwConnection.cancel()
                        return
                    }
                    self.accept(nwConnection, port: port, from: newListener, generation: generation)
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            status = .error("Could not start local API on port \(port): \(error.localizedDescription)")
        }
    }

    private func accept(
        _ nwConnection: NWConnection,
        port: UInt16,
        from originatingListener: NWListener,
        generation: UInt64
    ) {
        guard AppSettings.shared.localAPIEnabled,
              listener === originatingListener,
              listenerGeneration == generation else {
            nwConnection.cancel()
            return
        }
        guard connections.count < Self.maxConcurrentConnections else {
            nwConnection.cancel()
            return
        }

        let conn = LocalAPIConnection(
            connection: nwConnection,
            queue: queue,
            writeTimeoutSeconds: Self.writeTimeoutSeconds
        )
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.onFinished = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: id)
            }
        }
        conn.onRequest = { @Sendable [weak self, weak conn] request in
            let task = Task { @MainActor [weak self, weak conn] in
                guard let self, let conn else { return }
                await self.handleRequest(request, port: port, generation: generation, connection: conn)
            }
            conn?.attachWorkTask(task)
        }
        conn.start()
    }

    // MARK: - Request Handling (privacy: never log prompts or replies)

    private func isListenerActive(generation: UInt64) -> Bool {
        AppSettings.shared.localAPIEnabled && listener != nil && listenerGeneration == generation
    }

    private func handleRequest(
        _ request: LocalHTTPRequest,
        port: UInt16,
        generation: UInt64,
        connection: LocalAPIConnection
    ) async {
        guard isListenerActive(generation: generation) else {
            connection.cancel()
            return
        }

        let requiredKey = AppSettings.shared.localAPIKey
        if let rejection = LocalAPIGuard.check(request, port: port, requiredAPIKey: requiredKey.isEmpty ? nil : requiredKey) {
            connection.sendAndClose(LocalHTTPResponse.error(rejection))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let models = await availableModels()
            guard isListenerActive(generation: generation) else {
                connection.cancel()
                return
            }
            requestsServed += 1
            connection.sendAndClose(LocalHTTPResponse.json(statusCode: 200, body: LocalAPICodec.encodeModelsList(models)))

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(request, generation: generation, connection: connection)

        case (_, "/v1/models"), (_, "/v1/chat/completions"):
            connection.sendAndClose(LocalHTTPResponse.error(.methodNotAllowed()))

        default:
            connection.sendAndClose(LocalHTTPResponse.error(.notFound("Unknown endpoint '\(request.path)'.")))
        }
    }

    private func handleChatCompletions(
        _ request: LocalHTTPRequest,
        generation: UInt64,
        connection: LocalAPIConnection
    ) async {
        guard isListenerActive(generation: generation) else {
            connection.cancel()
            return
        }
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

        // Reject grammar-constrained response_format up front for models that refuse GBNF grammars.
        if chatReq.responseFormat.gbnfGrammar != nil,
           let targetEntry = lookupModelEntry(id: chatReq.model),
           !Self.supportsGrammar(targetEntry) {
            connection.sendAndClose(LocalHTTPResponse.error(.badRequest(
                "The model '\(chatReq.model)' does not support response_format / grammar-constrained JSON output.",
                code: "unsupported_response_format"
            )))
            return
        }

        let deadline = ContinuousClock.now + .milliseconds(Int(Self.busyTimeoutSeconds * 1000))

        // Serialize API requests one at a time (waiting up to 30 s).
        let acquiredGate = await requestGate.acquire(deadline: deadline)
        guard acquiredGate else {
            if !Task.isCancelled && !connection.isDisconnected && isListenerActive(generation: generation) {
                connection.sendAndClose(LocalHTTPResponse.error(.serverBusy()))
            }
            return
        }
        defer { Task { await requestGate.release() } }

        guard isListenerActive(generation: generation) else {
            connection.cancel()
            return
        }

        // Wait for any in-flight app install or specialist workflow before acquiring the engine lease.
        while (onboarding?.isInstalling ?? false) || (onboarding?.isSpecialistActive ?? false) {
            if Task.isCancelled || connection.isDisconnected || !isListenerActive(generation: generation) {
                return
            }
            if ContinuousClock.now >= deadline {
                connection.sendAndClose(LocalHTTPResponse.error(.serverBusy()))
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Acquire the exclusive lease BEFORE checking/switching the model so model load and
        // generation execute inside the same exclusive ownership interval.
        let remaining = remainingSeconds(until: deadline)
        let lease: ExclusiveInferenceLease
        do {
            lease = try await engine.acquireExclusiveInferenceLease(timeoutSeconds: remaining)
        } catch is CancellationError {
            return
        } catch {
            if !connection.isDisconnected && isListenerActive(generation: generation) {
                connection.sendAndClose(LocalHTTPResponse.error(.serverBusy()))
            }
            return
        }

        var leaseReleased = false
        let releaseLease: () async -> Void = {
            guard !leaseReleased else { return }
            leaseReleased = true
            connection.setCancelInferenceHook(nil)
            await lease.release()
        }

        connection.setCancelInferenceHook { @Sendable in
            lease.requestCancel()
        }
        defer {
            if !leaseReleased {
                leaseReleased = true
                connection.setCancelInferenceHook(nil)
                Task { await lease.release() }
            }
        }

        if connection.isDisconnected || Task.isCancelled || !isListenerActive(generation: generation) {
            lease.requestCancel()
            await releaseLease()
            return
        }

        // Ensure the requested model is already loaded, or load the already-installed, hash-verified
        // file exclusively inside this lease — never delete, never download, never cancel another owner.
        if let loadErr = await ensureModelLoadedInsideLease(modelID: chatReq.model, lease: lease) {
            await releaseLease()
            if !Task.isCancelled && !connection.isDisconnected && isListenerActive(generation: generation) {
                connection.sendAndClose(LocalHTTPResponse.error(loadErr))
            }
            return
        }

        if connection.isDisconnected || Task.isCancelled || !isListenerActive(generation: generation) {
            lease.requestCancel()
            await releaseLease()
            return
        }

        // Verify the engine actually has the requested model loaded before generating.
        guard let verifiedModelID = await lease.loadedModelID(), verifiedModelID == chatReq.model else {
            await releaseLease()
            if !Task.isCancelled && !connection.isDisconnected && isListenerActive(generation: generation) {
                connection.sendAndClose(LocalHTTPResponse.error(
                    .serviceUnavailable("Model '\(chatReq.model)' is not loaded in Quenderin.")
                ))
            }
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

        let splitThinking = chatReq.effectiveThinkingMode.allowsThinking
        let includeReasoning = chatReq.effectiveThinkingMode == .show
        let startsInsideThinking = splitThinking
            ? await lease.chatPromptStartsInsideThinking(system: systemPrompt, history: history, options: options)
            : false

        let stream: AsyncThrowingStream<String, Error>
        do {
            stream = try await lease.generateChat(system: systemPrompt, history: history, options: options)
        } catch InferenceError.modelNotLoaded {
            await releaseLease()
            connection.sendAndClose(LocalHTTPResponse.error(.serviceUnavailable("No model is loaded in Quenderin.")))
            return
        } catch InferenceError.cancelled {
            await releaseLease()
            return
        } catch InferenceError.generationFailed(let reason) where options.gbnfGrammar != nil && reason.lowercased().contains("grammar") {
            await releaseLease()
            connection.sendAndClose(LocalHTTPResponse.error(.badRequest(reason, code: "unsupported_response_format")))
            return
        } catch {
            await releaseLease()
            connection.sendAndClose(LocalHTTPResponse.error(.internalError("Generation failed: \(error.localizedDescription)")))
            return
        }

        let completionID = LocalAPICodec.makeCompletionID()
        let created = Int(Date().timeIntervalSince1970)

        if chatReq.stream {
            await streamResponse(
                stream: stream,
                lease: lease,
                releaseLease: releaseLease,
                connection: connection,
                id: completionID,
                created: created,
                model: verifiedModelID,
                splitThinking: splitThinking,
                includeReasoning: includeReasoning,
                startsInsideThinking: startsInsideThinking
            )
        } else {
            await bufferedResponse(
                stream: stream,
                lease: lease,
                releaseLease: releaseLease,
                connection: connection,
                id: completionID,
                created: created,
                model: verifiedModelID,
                splitThinking: splitThinking,
                includeReasoning: includeReasoning,
                startsInsideThinking: startsInsideThinking
            )
        }
        await releaseLease()
    }

    private func streamResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        releaseLease: () async -> Void,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        splitThinking: Bool,
        includeReasoning: Bool,
        startsInsideThinking: Bool
    ) async {
        guard await connection.send(LocalHTTPResponse.sseHeaders()) else {
            lease.requestCancel()
            await releaseLease()
            return
        }
        let roleChunk = LocalAPICodec.encodeStreamChunk(id: id, created: created, model: model, role: "assistant")
        guard await connection.send(roleChunk) else {
            lease.requestCancel()
            await releaseLease()
            return
        }

        var splitter = ThinkingSplitter(startsInsideThinking: startsInsideThinking)
        do {
            for try await piece in stream {
                if Task.isCancelled || connection.isDisconnected {
                    lease.requestCancel()
                    await releaseLease()
                    return
                }
                if splitThinking {
                    let delta = splitter.feed(piece)
                    if includeReasoning && !delta.thinking.isEmpty {
                        let chunk = LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, reasoningContent: delta.thinking
                        )
                        guard await connection.send(chunk) else {
                            lease.requestCancel()
                            await releaseLease()
                            return
                        }
                    }
                    if !delta.answer.isEmpty {
                        let chunk = LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, content: delta.answer
                        )
                        guard await connection.send(chunk) else {
                            lease.requestCancel()
                            await releaseLease()
                            return
                        }
                    }
                } else if !piece.isEmpty {
                    let chunk = LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, content: piece
                    )
                    guard await connection.send(chunk) else {
                        lease.requestCancel()
                        await releaseLease()
                        return
                    }
                }
            }

            let cap = await lease.chatCapStatus()
            // Release the exclusive engine lease promptly once generation finishes so flushing
            // final socket bytes cannot starve in-app chat.
            await releaseLease()

            var tailData = Data()
            if splitThinking {
                let tail = splitter.finish()
                if includeReasoning && !tail.thinking.isEmpty {
                    tailData.append(LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, reasoningContent: tail.thinking
                    ))
                }
                if !tail.answer.isEmpty {
                    tailData.append(LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, content: tail.answer
                    ))
                }
            }

            let finishReason: LocalAPIFinishReason = (cap == .hit) ? .length : .stop
            tailData.append(LocalAPICodec.encodeStreamChunk(
                id: id, created: created, model: model, finishReason: finishReason
            ))
            tailData.append(LocalAPICodec.streamDoneFrame)
            requestsServed += 1
            connection.sendAndClose(tailData)
        } catch {
            lease.requestCancel()
            await releaseLease()
            connection.cancel()
        }
    }

    private func bufferedResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        releaseLease: () async -> Void,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        splitThinking: Bool,
        includeReasoning: Bool,
        startsInsideThinking: Bool
    ) async {
        var splitter = ThinkingSplitter(startsInsideThinking: startsInsideThinking)
        var reasoning = ""
        var answer = ""
        do {
            for try await piece in stream {
                if Task.isCancelled || connection.isDisconnected {
                    lease.requestCancel()
                    await releaseLease()
                    return
                }
                if splitThinking {
                    let delta = splitter.feed(piece)
                    if includeReasoning && !delta.thinking.isEmpty { reasoning += delta.thinking }
                    if !delta.answer.isEmpty { answer += delta.answer }
                } else {
                    answer += piece
                }
            }
            if splitThinking {
                let tail = splitter.finish()
                if includeReasoning && !tail.thinking.isEmpty { reasoning += tail.thinking }
                if !tail.answer.isEmpty { answer += tail.answer }
            }
            if Task.isCancelled || connection.isDisconnected {
                lease.requestCancel()
                await releaseLease()
                return
            }
            let cap = await lease.chatCapStatus()
            // Release the exclusive engine lease before flushing the buffered HTTP response.
            await releaseLease()

            let finishReason: LocalAPIFinishReason = (cap == .hit) ? .length : .stop
            let body = LocalAPICodec.encodeChatCompletion(
                id: id,
                created: created,
                model: model,
                content: answer,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                includeReasoning: includeReasoning,
                finishReason: finishReason,
                usage: nil
            )
            requestsServed += 1
            connection.sendAndClose(LocalHTTPResponse.json(statusCode: 200, body: body))
        } catch is CancellationError {
            lease.requestCancel()
            await releaseLease()
        } catch {
            lease.requestCancel()
            await releaseLease()
            if !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.internalError("Generation failed: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Model Discovery & Installed-Only Load (never downloads, never deletes)

    private static func supportsGrammar(_ entry: ModelEntry) -> Bool {
        !ModelRuntimeSupport.isBeam(entry)
            && !ModelRuntimeSupport.isJais(entry)
            && !ModelRuntimeSupport.isMuse(entry)
    }

    private func lookupModelEntry(id: String) -> ModelEntry? {
        ModelCatalog.entry(id: id) ?? SideloadedModels.shared.entry(id: id)
    }

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
        guard let entry = lookupModelEntry(id: id),
              ModelRuntimeSupport.supports(entry),
              OnboardingModel.resolveModelFile(model: entry) != nil else {
            return nil
        }
        return entry
    }

    /// Loads an already-installed, hash-verified model exclusively inside `lease`.
    /// Never calls `onboarding.install`, never deletes a corrupt file, never starts a download,
    /// and never calls `requestCancel()` outside the exclusive lease.
    private func ensureModelLoadedInsideLease(
        modelID: String,
        lease: ExclusiveInferenceLease
    ) async -> LocalAPIError? {
        if await lease.loadedModelID() == modelID {
            return nil
        }

        guard let entry = lookupModelEntry(id: modelID),
              ModelRuntimeSupport.supports(entry),
              let fileURL = OnboardingModel.resolveModelFile(model: entry) else {
            return .notFound(
                "The model '\(modelID)' is not installed on this Mac. Download it in Quenderin first.",
                code: "model_not_found"
            )
        }

        // Hash-verify the installed file(s) before touching the currently loaded model.
        // Failures return 404 without deleting files or triggering downloads.
        do {
            try await ModelArtifactSet.inBackground {
                try InferencePerformanceIdentity.verifyInstalled(entry, firstFile: fileURL)
            }
        } catch {
            return .notFound(
                "The installed model '\(entry.id)' failed integrity verification and cannot be loaded. Re-download it in Quenderin.",
                code: "model_not_found"
            )
        }

        if Task.isCancelled { return nil }

        await lease.setContextLengthChoice(AppSettings.shared.contextLength)
        do {
            try await lease.load(model: entry, at: fileURL)
        } catch {
            return .serviceUnavailable("Could not load model '\(entry.id)': \(OnboardingModel.describe(error))")
        }

        guard await lease.loadedModelID() == entry.id else {
            return .serviceUnavailable("Could not load model '\(entry.id)'. Open Quenderin to check model status.")
        }

        onboarding?.syncExternallyLoadedModel(entry)
        return nil
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
    private let writeTimeoutSeconds: Double
    private let lock = NSLock()
    private var buffer = Data()
    private var parsedRequest = false
    private var sendingFinal = false
    private var finished = false
    private var disconnected = false
    private var workTask: Task<Void, Never>?
    private var cancelInferenceHook: (@Sendable () -> Void)?
    private var readTimeoutItem: DispatchWorkItem?
    private var finalWriteTimeoutItem: DispatchWorkItem?
    private var pendingWrite: (continuation: CheckedContinuation<Bool, Never>, timeout: DispatchWorkItem)?

    var onRequest: (@Sendable (LocalHTTPRequest) -> Void)?
    var onFinished: (@Sendable () -> Void)?

    var isDisconnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnected
    }

    init(connection: NWConnection, queue: DispatchQueue, writeTimeoutSeconds: Double) {
        self.connection = connection
        self.queue = queue
        self.writeTimeoutSeconds = writeTimeoutSeconds
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

    func setCancelInferenceHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        let alreadyDisconnected = disconnected
        cancelInferenceHook = alreadyDisconnected ? nil : hook
        lock.unlock()
        if alreadyDisconnected {
            hook?()
        }
    }

    func start() {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable [weak self] data, _, isComplete, error in
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
                // Keep a pending receive open so an orderly peer close (EOF) cancels generation
                // immediately, even during buffered non-streaming responses.
                self.monitorPeerDisconnect()
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

    private func monitorPeerDisconnect() {
        lock.lock()
        let stopMonitoring = disconnected || sendingFinal
        lock.unlock()
        guard !stopMonitoring else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.markDisconnected()
                return
            }
            if isComplete {
                self.lock.lock()
                let flushingFinal = self.sendingFinal
                self.lock.unlock()
                if !flushingFinal {
                    self.markDisconnected()
                    self.connection.cancel()
                }
                return
            }
            // Discard any pipelined trailing bytes (one request per connection) and keep watching for EOF.
            self.monitorPeerDisconnect()
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

    private func cancelFinalWriteTimeout() {
        lock.lock()
        let item = finalWriteTimeoutItem
        finalWriteTimeoutItem = nil
        lock.unlock()
        item?.cancel()
    }

    /// Sends one SSE/response chunk with a bounded write deadline so a stalled reader cannot
    /// block inference or starve in-app chat.
    func send(_ data: Data) async -> Bool {
        if isDisconnected { return false }
        return await withCheckedContinuation { continuation in
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let timedOut = self.takePendingWrite()
                if let timedOut {
                    self.markDisconnected()
                    self.connection.cancel()
                    timedOut.continuation.resume(returning: false)
                }
            }

            lock.lock()
            if disconnected {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            pendingWrite = (continuation, timeoutItem)
            lock.unlock()

            queue.asyncAfter(deadline: .now() + writeTimeoutSeconds, execute: timeoutItem)
            connection.send(content: data, completion: .contentProcessed { @Sendable [weak self] error in
                guard let self else { return }
                guard let pending = self.takePendingWrite() else { return }
                pending.timeout.cancel()
                if error != nil {
                    self.markDisconnected()
                    pending.continuation.resume(returning: false)
                } else {
                    pending.continuation.resume(returning: true)
                }
            })
        }
    }

    private func takePendingWrite() -> (continuation: CheckedContinuation<Bool, Never>, timeout: DispatchWorkItem)? {
        lock.lock()
        let pending = pendingWrite
        pendingWrite = nil
        lock.unlock()
        return pending
    }

    func sendAndClose(_ data: Data) {
        cancelReadTimeout(markParsed: false)
        lock.lock()
        if disconnected {
            lock.unlock()
            return
        }
        sendingFinal = true
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.cancel()
        }
        finalWriteTimeoutItem?.cancel()
        finalWriteTimeoutItem = timeoutItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + writeTimeoutSeconds, execute: timeoutItem)
        connection.send(
            content: data,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { @Sendable [weak self] _ in
                self?.cancelFinalWriteTimeout()
                self?.cancel()
            }
        )
    }

    func cancel() {
        cancelReadTimeout(markParsed: false)
        cancelFinalWriteTimeout()
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
        let pending = pendingWrite
        pendingWrite = nil
        let shouldNotifyFinished = !finished
        finished = true
        lock.unlock()

        if let pending {
            pending.timeout.cancel()
            pending.continuation.resume(returning: false)
        }
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
