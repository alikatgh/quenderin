import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DeepSeekFailure: String, Error, Sendable, LocalizedError {
    case invalidCredential, credentialStorage, unavailable, unauthorized, quota, rateLimited, contextLimit
    case rejected, malformed, limit, timeout, connection, busy, persistence, interrupted, historyLimit
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Enter a valid DeepSeek API key without spaces."
        case .credentialStorage: return "The API key could not be accessed securely. Unlock this device and reconnect."
        case .unavailable: return "The selected DeepSeek model is unavailable. Check your account or choose another supported model."
        case .unauthorized: return "DeepSeek did not accept this API key. Reconnect with a valid key."
        case .quota: return "Your DeepSeek balance or quota is exhausted. Check your DeepSeek account."
        case .rateLimited: return "DeepSeek is rate limiting requests. Wait before sending again."
        case .contextLimit: return "This conversation exceeds DeepSeek’s context limit. Start a new DeepSeek chat."
        case .rejected: return "DeepSeek could not complete this request. Review the prompt before sending again."
        case .malformed: return "DeepSeek returned an incomplete or invalid response. The partial answer was kept, but will not be sent again."
        case .limit: return "This request reached Quenderin’s safety limit. Start a shorter conversation."
        case .timeout: return "The 120-second request limit was reached. The partial answer was kept."
        case .connection: return "The connection ended. A charge may have occurred. Nothing will retry automatically."
        case .busy: return "A DeepSeek request is already running. Stop it before starting another."
        case .persistence: return "DeepSeek history could not be saved. Resolve device storage access before sending."
        case .interrupted: return "This turn was interrupted. It will not be included in another request. Start a new chat to continue."
        case .historyLimit: return "This device has 50 saved DeepSeek chats. Existing history is preserved; no new chat was created."
        }
    }
}

public enum DeepSeekContract {
    public static let catalogVersion = "2026-10-23"
    public static let origin = "https://api.deepseek.com"
    public static let models = ["deepseek-flash", "deepseek-v4-pro"]
    public static let maxBytes = 8 * 1_024 * 1_024
    public static let maxEventBytes = 1_024 * 1_024
    public static let maxEvents = 65_536
    public static let maxTokens: Int64 = 4_096
    public static let seconds: TimeInterval = 120
    public static let capabilities = ProviderCapabilities(reasoning: true, toolCalls: true, documents: false, cancellation: true, usage: true)

    public static func body(_ request: ProviderRequest) throws -> Data {
        guard request.binding.kind == .deepseek, request.binding.origin == origin,
              request.selection.providerID == "deepseek", models.contains(request.selection.modelID),
              (1...maxTokens).contains(request.limits.maxOutputTokens),
              request.messages.allSatisfy({ $0.documents.isEmpty }),
              request.tools.count <= request.limits.maxToolCalls else { throw DeepSeekFailure.limit }
        let messages: [[String: Any]] = request.messages.map { message in
            var result: [String: Any] = ["role": message.role.rawValue, "content": message.content]
            if let reasoning = message.reasoningContent { result["reasoning_content"] = reasoning }
            if let id = message.toolCallID { result["tool_call_id"] = id }
            if !message.toolCalls.isEmpty {
                result["tool_calls"] = message.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSON]] as [String: Any] }
            }
            return result
        }
        var value: [String: Any] = ["model": request.selection.modelID, "messages": messages,
                                    "stream": true, "stream_options": ["include_usage": true],
                                    "max_tokens": request.limits.maxOutputTokens,
                                    "thinking": ["type": request.selection.reasoningEffort == .off ? "disabled" : "enabled"]]
        if request.selection.reasoningEffort != .off { value["reasoning_effort"] = request.selection.reasoningEffort.rawValue }
        if !request.tools.isEmpty {
            value["tools"] = try request.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.toolDescription,
                 "parameters": try JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))]] as [String: Any]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maxBytes else { throw DeepSeekFailure.limit }
        return data
    }

    public static func modelIDs(_ data: Data, selected: String) throws -> [String] {
        try NativeStrictJSON.validate(data, integerNumbersOnly: false)
        guard data.count <= maxEventBytes, models.contains(selected),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]], rows.count <= 1_024,
              rows.allSatisfy({ $0["id"] is String }) else { throw DeepSeekFailure.malformed }
        let ids = models.filter { candidate in rows.contains { $0["id"] as? String == candidate } }
        guard ids.contains(selected) else { throw DeepSeekFailure.unavailable }
        return ids
    }

    static func httpFailure(_ status: Int) -> DeepSeekFailure {
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .quota
        case 413, 422: return .contextLimit
        case 429: return .rateLimited
        case 500...599: return .unavailable
        default: return .rejected
        }
    }
}

public struct DeepSeekHTTPCall: Sendable, NativeConnectionPrivateValue {
    let id: UUID
    let path: String
    let body: Data?
    let key: DeepSeekAPIKey
    let timeout: TimeInterval
    init(id: UUID = UUID(), path: String, body: Data?, key: DeepSeekAPIKey, timeout: TimeInterval) {
        self.id = id; self.path = path; self.body = body; self.key = key; self.timeout = timeout
    }
}
public enum DeepSeekHTTPEvent: Sendable, NativeConnectionPrivateValue {
    case response(status: Int, url: URL, contentType: String)
    case bytes(Data)
}
public protocol DeepSeekHTTPTransport: Sendable {
    func open(_ call: DeepSeekHTTPCall) async throws -> AsyncThrowingStream<DeepSeekHTTPEvent, Error>
    func cancel(callID: UUID) async
}

/// Dedicated foreground session. No redirect, cookie, cache, credential storage, or retry loop.
public actor DeepSeekURLSessionTransport: DeepSeekHTTPTransport {
    private var session: URLSession?
    private var callID: UUID?
    public init() {}
    public func open(_ call: DeepSeekHTTPCall) async throws -> AsyncThrowingStream<DeepSeekHTTPEvent, Error> {
        try Task.checkCancellation()
        guard session == nil else { throw DeepSeekFailure.busy }
        guard ["/models", "/chat/completions"].contains(call.path), (0...DeepSeekContract.seconds).contains(call.timeout), call.timeout > 0,
              let url = URL(string: DeepSeekContract.origin + call.path) else { throw DeepSeekFailure.rejected }
        let config = Self.secureConfiguration(timeout: call.timeout)
        let pair = AsyncThrowingStream<DeepSeekHTTPEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let delegate = DeepSeekSessionDelegate(url: url, continuation: pair.continuation)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let newSession = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        session = newSession
        callID = call.id
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: call.timeout)
        request.httpMethod = call.body == nil ? "GET" : "POST"
        request.setValue("Bearer " + call.key.value, forHTTPHeaderField: "Authorization")
        request.setValue(call.body == nil ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
        if let body = call.body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        let task = newSession.dataTask(with: request)
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
        // URLSessionDataTask cancellation is thread-safe and synchronous. Installing this
        // handler before the final admission check closes cancellation between check/resume;
        // resuming a task already cancelled by the handler cannot dispatch the request.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            return pair.stream
        } onCancel: { task.cancel() }
    }
    nonisolated static func secureConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 1
        return config
    }
    public func cancel(callID: UUID) {
        guard self.callID == callID else { return }
        session?.invalidateAndCancel(); session = nil; self.callID = nil
    }
}

/// Delegate state is accessed on the single serial URLSession delegate queue only.
final class DeepSeekSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let continuation: AsyncThrowingStream<DeepSeekHTTPEvent, Error>.Continuation
    private var count = 0
    init(url: URL, continuation: AsyncThrowingStream<DeepSeekHTTPEvent, Error>.Continuation) { self.url = url; self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        continuation.finish(throwing: DeepSeekFailure.rejected)
        task.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= Int64(DeepSeekContract.maxBytes) else {
            continuation.finish(throwing: DeepSeekFailure.malformed); completionHandler(.cancel); return
        }
        yield(.response(status: response.statusCode, url: url, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? ""), task: dataTask)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count += data.count
        guard count <= DeepSeekContract.maxBytes else { continuation.finish(throwing: DeepSeekFailure.limit); dataTask.cancel(); return }
        yield(.bytes(data), task: dataTask)
    }
    private func yield(_ event: DeepSeekHTTPEvent, task: URLSessionTask) {
        if case .dropped = continuation.yield(event) { continuation.finish(throwing: DeepSeekFailure.limit); task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as NSError).code
            continuation.finish(throwing: code == NSURLErrorCancelled ? CancellationError() : code == NSURLErrorTimedOut ? DeepSeekFailure.timeout : DeepSeekFailure.connection)
        } else { continuation.finish() }
    }
}

/// Byte framing precedes UTF-8 decoding so split code points, CRLF, and arbitrary network
/// boundaries are lossless. EOF never invents a final blank line or a completion marker.
public struct DeepSeekSSEDecoder: Sendable {
    private var line = Data()
    private var lines: [String] = []
    private var eventBytes = 0
    private var aggregateBytes = 0
    private var sawCR = false
    private var events = 0
    public init() {}
    public mutating func append(_ data: Data) throws -> [String] {
        aggregateBytes += data.count
        guard aggregateBytes <= DeepSeekContract.maxBytes else { throw DeepSeekFailure.limit }
        var result: [String] = []
        for byte in data {
            if sawCR { sawCR = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                if let event = try finishLine() { result.append(event) }
                sawCR = byte == 13
            } else {
                line.append(byte)
                guard line.count <= DeepSeekContract.maxEventBytes else { throw DeepSeekFailure.limit }
            }
        }
        return result
    }
    private mutating func finishLine() throws -> String? {
        guard let text = String(data: line, encoding: .utf8) else { throw DeepSeekFailure.malformed }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            if eventBytes > 0 || !lines.isEmpty { events += 1 }
            guard events <= DeepSeekContract.maxEvents else { throw DeepSeekFailure.limit }
            guard !lines.isEmpty else { eventBytes = 0; return nil }
            let result = lines.joined(separator: "\n"); lines.removeAll(keepingCapacity: true); eventBytes = 0
            return result
        }
        eventBytes += text.utf8.count + 1
        guard eventBytes <= DeepSeekContract.maxEventBytes else { throw DeepSeekFailure.limit }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts[0] == "data" {
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            lines.append(value)
        }
        return nil
    }
    public func finish() throws {
        guard line.isEmpty, lines.isEmpty else { throw DeepSeekFailure.malformed }
    }
}

public struct DeepSeekStreamAccumulator: Sendable, NativeConnectionPrivateValue {
    public private(set) var text = ""
    public private(set) var reasoning = ""
    public private(set) var toolCalls: [ProviderToolCall] = []
    public private(set) var usage: ProviderUsage?
    public private(set) var finishReason: ProviderCompletionReason?
    public private(set) var done = false
    private struct Call: Sendable { var id = ""; var name = ""; var arguments = "" }
    private var calls: [Int: Call] = [:]
    private let maxToolCalls: Int
    private let outputLimit: Int64
    private var chunkID: String?
    public init(maxToolCalls: Int = 0, maxOutputTokens: Int64 = DeepSeekContract.maxTokens) {
        self.maxToolCalls = maxToolCalls; self.outputLimit = maxOutputTokens
    }
    public mutating func accept(_ data: String, messageID: String) throws -> [ProviderEvent] {
        guard !done else { throw DeepSeekFailure.malformed }
        if data == "[DONE]" {
            guard let finishReason else { throw DeepSeekFailure.malformed }
            toolCalls = try calls.keys.sorted().map { index in
                guard let call = calls[index], !call.id.isEmpty, !call.name.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)), object is [String: Any]
                else { throw DeepSeekFailure.malformed }
                return try ProviderToolCall(id: call.id, name: call.name, argumentsJSON: call.arguments)
            }
            for call in toolCalls { try NativeStrictJSON.validate(Data(call.argumentsJSON.utf8), integerNumbersOnly: false) }
            guard Set(toolCalls.map(\.id)).count == toolCalls.count,
                  calls.keys.sorted() == Array(0..<calls.count),
                  (finishReason == .toolCalls) == !toolCalls.isEmpty else { throw DeepSeekFailure.malformed }
            done = true
            return [.completion(finishReason)]
        }
        let bytes = Data(data.utf8)
        try NativeStrictJSON.validate(bytes, integerNumbersOnly: false)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["error"] == nil, let choices = object["choices"] as? [[String: Any]], choices.count <= 1 else { throw DeepSeekFailure.malformed }
        if let raw = object["id"], !(raw is String) { throw DeepSeekFailure.malformed }
        if let raw = object["object"], raw as? String != "chat.completion.chunk" { throw DeepSeekFailure.malformed }
        if let id = object["id"] as? String {
            if let chunkID, id != chunkID { throw DeepSeekFailure.malformed }; chunkID = id
        }
        var result: [ProviderEvent] = []
        if let raw = object["usage"], !(raw is NSNull) {
            guard let raw = raw as? [String: Any], let input = Self.counter(raw["prompt_tokens"]), let output = Self.counter(raw["completion_tokens"]), output <= outputLimit else { throw DeepSeekFailure.limit }
            let value = try ProviderUsage(inputTokens: input, outputTokens: output)
            usage = value; result.append(.usage(value))
        }
        if choices.isEmpty { guard usage != nil, finishReason != nil else { throw DeepSeekFailure.malformed }; return result }
        guard finishReason == nil, let choice = choices.first, let index = Self.counter(choice["index"]), index == 0,
              let delta = choice["delta"] as? [String: Any] else { throw DeepSeekFailure.malformed }
        if let role = delta["role"], role as? String != "assistant" { throw DeepSeekFailure.malformed }
        for (field, reasoningField) in [("content", false), ("reasoning_content", true)] {
            if let raw = delta[field], !(raw is NSNull) {
                guard let fragment = raw as? String else { throw DeepSeekFailure.malformed }
                if reasoningField { reasoning += fragment } else { text += fragment }
                guard text.utf8.count <= DeepSeekContract.maxEventBytes, reasoning.utf8.count <= DeepSeekContract.maxEventBytes else { throw DeepSeekFailure.limit }
                let value = try ProviderTextDelta(messageID: messageID, delta: fragment)
                result.append(reasoningField ? .reasoning(value) : .text(value))
            }
        }
        if let raw = delta["tool_calls"], !(raw is NSNull) {
            guard let fragments = raw as? [[String: Any]], fragments.count <= maxToolCalls else { throw DeepSeekFailure.limit }
            for fragment in fragments {
                guard let rawIndex = Self.counter(fragment["index"]), rawIndex < Int64(maxToolCalls) else { throw DeepSeekFailure.limit }
                let index = Int(rawIndex)
                var call = calls[index] ?? Call()
                if let type = fragment["type"], type as? String != "function" { throw DeepSeekFailure.malformed }
                if let raw = fragment["id"], !(raw is String) { throw DeepSeekFailure.malformed }
                let id = fragment["id"] as? String
                if let id { guard call.id.isEmpty || call.id == id else { throw DeepSeekFailure.malformed }; call.id = id }
                if let raw = fragment["function"], !(raw is [String: Any]) { throw DeepSeekFailure.malformed }
                let function = fragment["function"] as? [String: Any] ?? [:]
                if let raw = function["name"], !(raw is String) { throw DeepSeekFailure.malformed }
                if let raw = function["arguments"], !(raw is String) { throw DeepSeekFailure.malformed }
                let name = function["name"] as? String
                if let name { guard call.name.isEmpty || call.name == name else { throw DeepSeekFailure.malformed }; call.name = name }
                let arguments = function["arguments"] as? String ?? ""
                call.arguments += arguments
                guard call.arguments.utf8.count <= DeepSeekContract.maxEventBytes else { throw DeepSeekFailure.limit }
                calls[index] = call
                result.append(.toolCallFragment(try ProviderToolCallFragment(messageID: messageID, callID: id, name: name, index: index, argumentsDelta: arguments)))
            }
        }
        if let raw = choice["finish_reason"], !(raw is NSNull) {
            guard let value = raw as? String else { throw DeepSeekFailure.malformed }
            switch value {
            case "stop": finishReason = .end
            case "length": finishReason = .outputLimit
            case "tool_calls": guard maxToolCalls > 0 else { throw DeepSeekFailure.limit }; finishReason = .toolCalls
            case "content_filter", "insufficient_system_resource", "aborted": throw DeepSeekFailure.rejected
            default: throw DeepSeekFailure.malformed
            }
        }
        return result
    }
    static func counter(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991, number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.int64Value
    }
    public func finish() throws { guard done, finishReason != nil else { throw DeepSeekFailure.malformed } }
}

/// Deadline and transport cancellation can race to finish the child task. Retain the
/// deadline receipt so that race cannot turn a timeout into apparent user cancellation.
private final class DeepSeekDeadlineReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func expire() { lock.withLock { value = true } }
    var expired: Bool { lock.withLock { value } }
}

public actor DeepSeekClient {
    private let transport: any DeepSeekHTTPTransport
    private var active: UUID?
    public init(transport: any DeepSeekHTTPTransport = DeepSeekURLSessionTransport()) { self.transport = transport }
    public func cancel(callID: UUID) async {
        guard active == callID else { return }
        await transport.cancel(callID: callID)
    }
    public func validate(key: DeepSeekAPIKey, selectedModel: String, callID: UUID = UUID()) async throws -> [String] {
        guard active == nil else { throw DeepSeekFailure.busy }; active = callID
        do {
            let result = try await withDeadline(seconds: 30, callID: callID) { [transport] in
                try Task.checkCancellation()
                let stream = try await transport.open(DeepSeekHTTPCall(id: callID, path: "/models", body: nil, key: key, timeout: 30))
                var data = Data(); var response = false
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case let .response(status, url, _):
                        guard !response, url.absoluteString == DeepSeekContract.origin + "/models" else { throw DeepSeekFailure.rejected }
                        guard status == 200 else { throw DeepSeekContract.httpFailure(status) }; response = true
                    case .bytes(let bytes):
                        guard response else { throw DeepSeekFailure.malformed }; data.append(bytes)
                        guard data.count <= DeepSeekContract.maxEventBytes else { throw DeepSeekFailure.limit }
                    }
                }
                try Task.checkCancellation()
                guard response else { throw DeepSeekFailure.malformed }
                return try DeepSeekContract.modelIDs(data, selected: selectedModel)
            }
            await transport.cancel(callID: callID); active = nil; return result
        } catch { await transport.cancel(callID: callID); active = nil; throw Self.safe(error) }
    }
    public func run(_ request: ProviderRequest, key: DeepSeekAPIKey, callID: UUID = UUID(), onEvent: @Sendable @escaping (ProviderEvent) async -> Void) async throws -> DeepSeekStreamAccumulator {
        guard active == nil else { throw DeepSeekFailure.busy }
        let body = try DeepSeekContract.body(request)
        let remaining = min(DeepSeekContract.seconds, Double(request.limits.deadlineEpochMs) / 1_000 - Date().timeIntervalSince1970)
        guard remaining > 0 else { throw DeepSeekFailure.timeout }; active = callID
        do {
            let result = try await withDeadline(seconds: remaining, callID: callID) { [transport] in
                try Task.checkCancellation()
                let stream = try await transport.open(DeepSeekHTTPCall(id: callID, path: "/chat/completions", body: body, key: key, timeout: remaining))
                var decoder = DeepSeekSSEDecoder()
                var accumulator = DeepSeekStreamAccumulator(maxToolCalls: request.limits.maxToolCalls, maxOutputTokens: request.limits.maxOutputTokens)
                var response = false
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case let .response(status, url, contentType):
                        guard !response, url.absoluteString == DeepSeekContract.origin + "/chat/completions" else { throw DeepSeekFailure.rejected }
                        guard status == 200 else { throw DeepSeekContract.httpFailure(status) }
                        guard contentType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/event-stream" else { throw DeepSeekFailure.malformed }; response = true
                    case .bytes(let bytes):
                        guard response else { throw DeepSeekFailure.malformed }
                        for data in try decoder.append(bytes) {
                            for value in try accumulator.accept(data, messageID: request.requestID) { await onEvent(value) }
                        }
                    }
                }
                try Task.checkCancellation(); try decoder.finish(); try accumulator.finish()
                return accumulator
            }
            await transport.cancel(callID: callID); active = nil; return result
        } catch { await transport.cancel(callID: callID); active = nil; throw Self.safe(error) }
    }
    private func withDeadline<T: Sendable>(seconds: TimeInterval, callID: UUID, work: @Sendable @escaping () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let receipt = DeepSeekDeadlineReceipt()
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try Task.checkCancellation(); return try await work() }
                    group.addTask { [transport] in
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        receipt.expire()
                        await transport.cancel(callID: callID); throw DeepSeekFailure.timeout
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw DeepSeekFailure.connection }
                    return result
                }
            } onCancel: { [transport] in
                Task { await transport.cancel(callID: callID) }
            }
        } catch {
            if receipt.expired { throw DeepSeekFailure.timeout }
            throw error
        }
    }
    private static func safe(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? NativeConnectionError { return error == .limitExceeded ? DeepSeekFailure.limit : DeepSeekFailure.malformed }
        return (error as? DeepSeekFailure) ?? DeepSeekFailure.connection
    }
}
