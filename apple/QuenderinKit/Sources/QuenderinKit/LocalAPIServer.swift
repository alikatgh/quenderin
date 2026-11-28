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
/// - Cancels in-flight generation as soon as a transport error/reset, write timeout, or failed
///   SSE write/probe observes client disconnect (preserving valid write-half-closed clients
///   `shutdown(SHUT_WR)`; a clean FIN before the first streamed token cannot be distinguished
///   from a valid half-close until a write or transport error occurs).
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
        let port = LocalAPIGuard.clampPort(settings.localAPIPort)
        return "http://127.0.0.1:\(port)/v1"
    }

    private static let busyTimeoutSeconds: Double = 30.0
    private static let writeTimeoutSeconds: Double = 15.0
    private static let rejectionWriteTimeoutSeconds: Double = 1.0

    private let settingsOverride: AppSettings?
    private let headerReadTimeoutSeconds: Double
    private var settings: AppSettings { settingsOverride ?? .shared }

    private let queue = DispatchQueue(label: "ai.quenderin.local-api")
    private let requestGate = LocalAPIRequestGate()
    private var listener: NWListener?
    private var listenerGeneration: UInt64 = 0
    private var activePort: UInt16 = LocalAPIGuard.defaultPort
    private var connections: [ObjectIdentifier: LocalAPIConnection] = [:]
    private(set) var admission = LocalAPIAdmission<ObjectIdentifier>()
    private var cancellables: Set<AnyCancellable> = []
    private var configured = false

    private weak var onboarding: OnboardingModel?
    private var engine: InferenceEngine?

    init(settings: AppSettings? = nil, headerReadTimeoutSeconds: Double = 5) {
        self.settingsOverride = settings
        self.headerReadTimeoutSeconds = headerReadTimeoutSeconds
    }

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

        let settings = self.settings
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
                    guard let self, self.settings.localAPIEnabled else { return }
                    self.restart()
                }
            }
            .store(in: &cancellables)

        applySettings()
    }

    /// Reconciles live listener state with `AppSettings.shared`.
    public func applySettings() {
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
        if settings.localAPIEnabled {
            start(port: LocalAPIGuard.clampPort(settings.localAPIPort))
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
        admission = LocalAPIAdmission()
        for conn in active {
            conn.cancel()
        }
        status = .off
    }

    /// Synchronous shutdown hook called from `applicationShouldTerminate` right before `_exit(0)`.
    public func stopImmediately() {
        stop()
    }

    /// Port zero lets the OS assign an available loopback port.
    func start(port: UInt16) {
        stop()
        let generation = listenerGeneration
        activePort = port
        status = .starting(port: port)

        guard let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) else {
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
                        let boundPort = port == 0 ? (newListener.port?.rawValue ?? port) : port
                        self.status = .listening(port: boundPort)
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
                    let boundPort = port == 0 ? (newListener.port?.rawValue ?? port) : port
                    self.accept(nwConnection, port: boundPort, from: newListener, generation: generation)
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
        guard settings.localAPIEnabled,
              listener === originatingListener,
              listenerGeneration == generation else {
            nwConnection.cancel()
            return
        }
        let id = ObjectIdentifier(nwConnection)
        let decision = admission.admit(id)
        guard decision != .cancel else {
            nwConnection.cancel()
            return
        }

        let settings = self.settings
        let rejecting = decision == .sendRejection
        let conn = LocalAPIConnection(
            connection: nwConnection,
            queue: queue,
            writeTimeoutSeconds: rejecting ? Self.rejectionWriteTimeoutSeconds : Self.writeTimeoutSeconds,
            validateHeaders: { settings.validateLocalAPIHeaders($0, port: port) }
        )
        connections[id] = conn
        conn.onFinished = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.listenerGeneration == generation else { return }
                self.connections.removeValue(forKey: id)
                self.admission.release(id)
            }
        }
        if rejecting {
            conn.start(
                headerReadTimeoutSeconds: headerReadTimeoutSeconds,
                rejecting: LocalHTTPResponse.connectionLimit()
            )
            return
        }
        conn.onHeadersAccepted = { @Sendable [weak self, weak conn] in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connections[id] === conn else { return }
                self.admission.promote(id)
            }
        }
        conn.onRequest = { @Sendable [weak self, weak conn] request in
            let task = Task { @MainActor [weak self, weak conn] in
                guard let self, let conn else { return }
                await self.handleRequest(request, port: port, generation: generation, connection: conn)
            }
            conn?.attachWorkTask(task)
        }
        conn.start(headerReadTimeoutSeconds: headerReadTimeoutSeconds)
    }

    // MARK: - Request Handling (privacy: never log prompts or replies)

    private func isListenerActive(generation: UInt64) -> Bool {
        settings.localAPIEnabled && listener != nil && listenerGeneration == generation
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

        if let rejection = settings.validateLocalAPIHeaders(request, port: port) {
            connection.sendAndClose(LocalHTTPResponse.error(rejection))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let models = availableModels(activeID: await currentActiveModelID())
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

        let activeID = await currentActiveModelID()
        let models = availableModels(activeID: activeID)
        let availableIDs = models.map(\.id)
        let bodyData = request.body

        // Decode request JSON off the main actor so large payloads cannot block macOS UI interaction.
        let decodeResult = await Task.detached(priority: .userInitiated) {
            LocalAPICodec.decodeChatRequest(bodyData, availableModelIDs: availableIDs, activeModelID: activeID)
        }.value

        guard isListenerActive(generation: generation) && !connection.isDisconnected && !Task.isCancelled else {
            connection.cancel()
            return
        }

        let chatReq: LocalAPIChatRequest
        switch decodeResult {
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
        var gateReleased = false
        let releaseGate: () async -> Void = {
            guard !gateReleased else { return }
            gateReleased = true
            await self.requestGate.release()
        }
        defer {
            if !gateReleased {
                gateReleased = true
                Task { await self.requestGate.release() }
            }
        }

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

        // Ensure the requested model is already loaded, or load an already-installed, integrity-checked
        // file exclusively inside this lease — never delete, never download, never cancel another owner.
        if let loadErr = await ensureModelLoadedInsideLease(modelID: chatReq.model, lease: lease,
                                                            generation: generation, connection: connection) {
            await releaseLease()
            await releaseGate()
            if !Task.isCancelled && !connection.isDisconnected && isListenerActive(generation: generation) {
                connection.sendAndClose(LocalHTTPResponse.error(loadErr))
            }
            return
        }

        if connection.isDisconnected || Task.isCancelled || !isListenerActive(generation: generation) {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            return
        }

        // Verify the engine actually has the requested model loaded before generating.
        guard let verifiedModelID = await lease.loadedModelID(), verifiedModelID == chatReq.model else {
            await releaseLease()
            await releaseGate()
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
            await releaseGate()
            connection.sendAndClose(LocalHTTPResponse.error(.serviceUnavailable("No model is loaded in Quenderin.")))
            return
        } catch InferenceError.cancelled {
            await releaseLease()
            await releaseGate()
            return
        } catch InferenceError.generationFailed(let reason) where options.gbnfGrammar != nil && reason.lowercased().contains("grammar") {
            await releaseLease()
            await releaseGate()
            connection.sendAndClose(LocalHTTPResponse.error(.badRequest(reason, code: "unsupported_response_format")))
            return
        } catch {
            await releaseLease()
            await releaseGate()
            connection.sendAndClose(LocalHTTPResponse.error(.internalError("Generation failed: \(error.localizedDescription)")))
            return
        }

        let completionID = LocalAPICodec.makeCompletionID()
        let created = Int(Date().timeIntervalSince1970)
        let hasGrammar = options.gbnfGrammar != nil

        if chatReq.stream {
            await streamResponse(
                stream: stream,
                lease: lease,
                releaseLease: releaseLease,
                releaseGate: releaseGate,
                connection: connection,
                id: completionID,
                created: created,
                model: verifiedModelID,
                hasGrammar: hasGrammar,
                splitThinking: splitThinking,
                includeReasoning: includeReasoning,
                startsInsideThinking: startsInsideThinking
            )
        } else {
            await bufferedResponse(
                stream: stream,
                lease: lease,
                releaseLease: releaseLease,
                releaseGate: releaseGate,
                connection: connection,
                id: completionID,
                created: created,
                model: verifiedModelID,
                hasGrammar: hasGrammar,
                splitThinking: splitThinking,
                includeReasoning: includeReasoning,
                startsInsideThinking: startsInsideThinking
            )
        }
        await releaseLease()
        await releaseGate()
    }

    private func streamResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        releaseLease: () async -> Void,
        releaseGate: () async -> Void,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        hasGrammar: Bool,
        splitThinking: Bool,
        includeReasoning: Bool,
        startsInsideThinking: Bool
    ) async {
        // Decouple native generation from per-piece socket writes using a coalescing buffer:
        // 1) Pre-first-token failures (e.g. native grammar-sampler initialization failure) still
        //    produce an honest HTTP 4xx/5xx JSON error instead of an already-committed HTTP 200 SSE.
        // 2) The exclusive inference lease and request gate are released the instant native
        //    generation completes, never held while draining buffered SSE frames to a slow reader.
        let sseBuffer = LocalSSEStreamBuffer()
        var writerTask: Task<Bool, Never>?
        var headersStarted = false

        func startWriterIfNeeded() {
            guard !headersStarted else { return }
            headersStarted = true
            var intro = LocalHTTPResponse.sseHeaders()
            intro.append(LocalAPICodec.encodeStreamChunk(id: id, created: created, model: model, role: "assistant"))
            sseBuffer.append(intro)
            // Register the peer-FIN probe AFTER headers are queued in `sseBuffer` and route it
            // through the same ordered buffer/writer so `:\n\n` can never precede `HTTP/1.1` or
            // race with an in-flight chunk write.
            connection.setStreamingProbeHook { [sseBuffer] in
                sseBuffer.enqueueProbe()
            }
            writerTask = Task { [connection, sseBuffer] in
                let sent = await sseBuffer.writeFrames { data, final in
                    await connection.send(data, final: final)
                }
                if !sent { connection.cancel() }
                return sent
            }
        }

        var splitter = ThinkingSplitter(startsInsideThinking: startsInsideThinking)
        do {
            for try await piece in stream {
                if Task.isCancelled || connection.isDisconnected || sseBuffer.isAborted {
                    lease.requestCancel()
                    await releaseLease()
                    await releaseGate()
                    sseBuffer.abort()
                    writerTask?.cancel()
                    return
                }
                startWriterIfNeeded()
                var frameData = Data()
                if splitThinking {
                    let delta = splitter.feed(piece)
                    if includeReasoning && !delta.thinking.isEmpty {
                        frameData.append(LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, reasoningContent: delta.thinking
                        ))
                    }
                    if !delta.answer.isEmpty {
                        frameData.append(LocalAPICodec.encodeStreamChunk(
                            id: id, created: created, model: model, content: delta.answer
                        ))
                    }
                } else if !piece.isEmpty {
                    frameData.append(LocalAPICodec.encodeStreamChunk(
                        id: id, created: created, model: model, content: piece
                    ))
                }
                if !frameData.isEmpty && !sseBuffer.append(frameData) {
                    lease.requestCancel()
                    await releaseLease()
                    await releaseGate()
                    writerTask?.cancel()
                    connection.cancel()
                    return
                }
            }

            if Task.isCancelled || connection.isDisconnected || sseBuffer.isAborted {
                lease.requestCancel()
                await releaseLease()
                await releaseGate()
                sseBuffer.abort()
                writerTask?.cancel()
                return
            }

            let finishReason = try LocalAPIFinishReason.completion(for: await lease.chatCapStatus())
            // Release the exclusive engine lease and API gate immediately now that native
            // generation has finished; slow socket draining below can never starve in-app chat.
            await releaseLease()
            await releaseGate()
            guard !Task.isCancelled, !connection.isDisconnected, !sseBuffer.isAborted else {
                sseBuffer.abort()
                writerTask?.cancel()
                connection.cancel()
                return
            }

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

            tailData.append(LocalAPICodec.encodeStreamChunk(
                id: id, created: created, model: model, finishReason: finishReason
            ))
            tailData.append(LocalAPICodec.streamDoneFrame)
            startWriterIfNeeded()
            sseBuffer.finish(finalData: tailData)
            if await writerTask?.value == true {
                requestsServed += 1
            }
            connection.cancel()
        } catch InferenceError.cancelled {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            sseBuffer.abort()
            writerTask?.cancel()
            connection.cancel()
        } catch InferenceError.generationFailed(let reason) where hasGrammar && reason.lowercased().contains("grammar") {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            sseBuffer.abort()
            writerTask?.cancel()
            if !headersStarted && !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.badRequest(reason, code: "unsupported_response_format")))
            } else {
                connection.cancel()
            }
        } catch {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            let apiError = error as? LocalAPIError ?? .internalError("Generation failed: \(error.localizedDescription)")
            if headersStarted && !connection.isDisconnected {
                sseBuffer.finish(finalData: LocalAPICodec.encodeStreamError(apiError))
                _ = await writerTask?.value
                connection.cancel()
            } else {
                sseBuffer.abort()
                writerTask?.cancel()
                if !connection.isDisconnected { connection.sendAndClose(LocalHTTPResponse.error(apiError)) }
            }
        }
    }

    private func bufferedResponse(
        stream: AsyncThrowingStream<String, Error>,
        lease: ExclusiveInferenceLease,
        releaseLease: () async -> Void,
        releaseGate: () async -> Void,
        connection: LocalAPIConnection,
        id: String,
        created: Int,
        model: String,
        hasGrammar: Bool,
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
                    await releaseGate()
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
                await releaseGate()
                return
            }
            let finishReason = try LocalAPIFinishReason.completion(for: await lease.chatCapStatus())
            // Release the exclusive engine lease and API gate before flushing the HTTP response.
            await releaseLease()
            await releaseGate()

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
            await releaseGate()
        } catch InferenceError.cancelled {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
        } catch InferenceError.generationFailed(let reason) where hasGrammar && reason.lowercased().contains("grammar") {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            if !connection.isDisconnected {
                connection.sendAndClose(LocalHTTPResponse.error(.badRequest(reason, code: "unsupported_response_format")))
            }
        } catch {
            lease.requestCancel()
            await releaseLease()
            await releaseGate()
            if !connection.isDisconnected {
                let apiError = error as? LocalAPIError ?? .internalError("Generation failed: \(error.localizedDescription)")
                connection.sendAndClose(LocalHTTPResponse.error(apiError))
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

    private func availableModels(activeID: String?) -> [LocalAPIModelInfo] {
        Self.installedModels(
            activeID: activeID,
            catalog: ModelCatalog.models,
            sideloaded: SideloadedModels.shared,
            storage: OnboardingModel.defaultModelStorage()
        )
    }

    static func installedModels(
        activeID: String?,
        catalog: [ModelEntry],
        sideloaded: SideloadedModels,
        storage: FileManagerModelStorage
    ) -> [LocalAPIModelInfo] {
        var seen: Set<String> = []
        var result: [LocalAPIModelInfo] = []

        if let activeID, !activeID.isEmpty {
            seen.insert(activeID)
            result.append(LocalAPIModelInfo(id: activeID))
        }

        let candidates = (catalog + sideloaded.all).compactMap { entry -> (id: String, size: Int64)? in
            guard seen.insert(entry.id).inserted, ModelRuntimeSupport.supports(entry),
                  let file = storage.candidateFile(for: entry),
                  let identity = ModelArtifactReceipts.Identity.read(file) else { return nil }
            let size = ModelArtifactSet.isMultipart(entry) ? entry.downloadBytes ?? identity.size : identity.size
            return (entry.id, size)
        }.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.id < $1.id
        }
        result.append(contentsOf: candidates.map { LocalAPIModelInfo(id: $0.id) })
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

    /// Loads an already-installed, integrity-checked model exclusively inside `lease`.
    /// Never calls `onboarding.install`, never deletes a corrupt file, never starts a download,
    /// and never calls `requestCancel()` outside the exclusive lease.
    private func ensureModelLoadedInsideLease(
        modelID: String,
        lease: ExclusiveInferenceLease,
        generation: UInt64,
        connection: LocalAPIConnection
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

        // Verify the installed file(s) before touching the currently loaded model
        // (SHA-256 digest when pinned, GGUF header otherwise).
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

        await lease.setContextLengthChoice(settings.contextLength)
        do {
            try await lease.loadForRequest(model: entry, at: fileURL) { @MainActor in
                // Model selection commits on the main actor before this request releases its lease.
                guard !Task.isCancelled, self.isListenerActive(generation: generation),
                      !connection.isDisconnected else { return false }
                self.onboarding?.syncExternallyLoadedModel(entry)
                return true
            }
        } catch is CancellationError {
            return nil
        } catch {
            return .serviceUnavailable("Could not load model '\(entry.id)': \(OnboardingModel.describe(error))")
        }
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
    private let validateHeaders: @Sendable (LocalHTTPRequest) -> LocalAPIError?
    private let lock = NSLock()
    private var buffer = Data()
    private var headersAccepted = false // connection queue only
    private var parsedRequest = false
    private var sendingFinal = false
    private var finished = false
    private var disconnected = false
    private var workTask: Task<Void, Never>?
    private var cancelInferenceHook: (@Sendable () -> Void)?
    private var streamingProbeHook: (@Sendable () -> Void)?
    private var readTimeoutItem: DispatchWorkItem?
    private var finalWriteTimeoutItem: DispatchWorkItem?
    private var pendingWrite: (continuation: CheckedContinuation<Bool, Never>, timeout: DispatchWorkItem)?

    var onHeadersAccepted: (@Sendable () -> Void)?
    var onRequest: (@Sendable (LocalHTTPRequest) -> Void)?
    var onFinished: (@Sendable () -> Void)?

    var isDisconnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnected
    }

    init(connection: NWConnection, queue: DispatchQueue, writeTimeoutSeconds: Double,
         validateHeaders: @escaping @Sendable (LocalHTTPRequest) -> LocalAPIError?) {
        self.connection = connection
        self.queue = queue
        self.writeTimeoutSeconds = writeTimeoutSeconds
        self.validateHeaders = validateHeaders
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

    func setStreamingProbeHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        streamingProbeHook = (disconnected || sendingFinal) ? nil : hook
        lock.unlock()
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

    func start(headerReadTimeoutSeconds: Double, rejecting response: Data? = nil) {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.markDisconnected()
            default:
                break
            }
        }
        if let response {
            connection.start(queue: queue)
            sendAndClose(response)
            return
        }
        scheduleReadTimeout(seconds: headerReadTimeoutSeconds, message: "Timed out waiting for HTTP headers.")
        connection.start(queue: queue)
        receiveNext()
    }

    private func scheduleReadTimeout(seconds: Double, message: String) {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyParsed = self.parsedRequest
            let alreadyClosed = self.disconnected
            self.lock.unlock()
            if !alreadyParsed && !alreadyClosed {
                self.sendAndClose(LocalHTTPResponse.error(.badRequest(message)))
            }
        }
        lock.lock()
        readTimeoutItem?.cancel()
        readTimeoutItem = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            let receiving = !self.disconnected && !self.sendingFinal
            self.lock.unlock()
            guard receiving else { return }
            if error != nil {
                self.markDisconnected()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            let parsed = LocalHTTPRequest.parse(self.buffer) { head in
                guard !self.headersAccepted else { return nil }
                if let rejection = self.validateHeaders(head) { return rejection }
                self.headersAccepted = true
                self.onHeadersAccepted?()
                self.scheduleReadTimeout(seconds: 30, message: "Timed out waiting for HTTP body.")
                return nil
            }
            switch parsed {
            case .complete(let request, _):
                self.cancelReadTimeout(markParsed: true)
                self.buffer.removeAll(keepingCapacity: false)
                self.onRequest?(request)
                // If the peer has not already half-closed its write side (`shutdown(SHUT_WR)`),
                // keep a pending receive open so transport errors/resets cancel generation promptly.
                if !isComplete {
                    self.monitorPeerDisconnect()
                }
            case .error(let parseErr):
                self.cancelReadTimeout(markParsed: true)
                self.sendAndClose(LocalHTTPResponse.error(.fromParseError(parseErr)))
            case .rejected(let error):
                self.cancelReadTimeout(markParsed: true)
                self.sendAndClose(LocalHTTPResponse.error(error))
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
                // TCP FIN (`isComplete == true`, `error == nil`) can be a valid write-half close
                // (`shutdown(SHUT_WR)`) from a client that is still reading the reply. Never cancel
                // a valid half-closed request on read EOF alone; stop re-arming `receive` and, once
                // streaming headers have been queued, route a harmless SSE comment probe through
                // the same ordered writer so a closed peer elicits TCP RST without ever preceding
                // the HTTP status line.
                self.lock.lock()
                let probe = (!self.sendingFinal && !self.disconnected) ? self.streamingProbeHook : nil
                self.lock.unlock()
                probe?()
                return
            }
            // Discard any pipelined trailing bytes (one request per connection) and keep watching.
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
    func send(_ data: Data, final: Bool) async -> Bool {
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
            if final {
                sendingFinal = true
                streamingProbeHook = nil
            }
            pendingWrite = (continuation, timeoutItem)
            lock.unlock()

            queue.asyncAfter(deadline: .now() + writeTimeoutSeconds, execute: timeoutItem)
            let context: NWConnection.ContentContext = final ? .finalMessage : .defaultMessage
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { @Sendable [weak self] error in
                guard let self else { return }
                guard let pending = self.takePendingWrite() else { return }
                pending.timeout.cancel()
                if error != nil {
                    self.markDisconnected()
                    pending.continuation.resume(returning: false)
                } else {
                    pending.continuation.resume(returning: !self.isDisconnected)
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
        streamingProbeHook = nil
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
        streamingProbeHook = nil
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
