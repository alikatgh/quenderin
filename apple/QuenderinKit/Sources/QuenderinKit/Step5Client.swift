import Foundation

public struct Step5Message: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public struct Step5Answer: Codable, Sendable, Equatable { public let text: String; public let truncated: Bool }
public enum Step5Error: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public enum Step5Contract {
    public static let modelRevision = "364b3b03fed2477aa0953fe855a2c4c8c48ee3cc"
    public static let backendRevision = "e177c621f2b8ae1be06190bc34eef84646e54f11"
    public static func endpoint(_ input: String) throws -> URL {
        guard input.utf8.count <= 2048, let components = URLComponents(string: input), let url = components.url,
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, ["", "/"].contains(components.percentEncodedPath),
              components.port == nil || (1...65535).contains(components.port!),
              components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw Step5Error.invalid("Use an HTTPS origin or http://127.0.0.1:18000. Credentials, paths and query strings are unavailable.")
        }
        return url
    }
    public static func messages(_ messages: [Step5Message]) throws {
        guard (1...16).contains(messages.count), messages.last?.role == "user" else { throw Step5Error.invalid("Use 1–16 alternating messages ending with a user message.") }
        var bytes = 0
        for (index, message) in messages.enumerated() {
            let count = message.content.utf8.count; bytes += count
            guard message.role == (index.isMultiple(of: 2) ? "user" : "assistant"), !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !message.content.contains("\0"), count <= 8192 else { throw Step5Error.invalid("Each Step 5 message must contain 1–8,192 UTF-8 bytes and alternate user/assistant roles.") }
        }
        guard bytes <= 32768 else { throw Step5Error.invalid("This conversation exceeds 32 KiB. Clear it explicitly to begin another conversation.") }
    }
    private struct Handshake: Decodable { let `protocol`: Int; let modelRevision: String; let backendRevision: String; let artifactsVerified: Bool; let ready: Bool; let maxOutputTokens: Int; let maxConcurrentRequests: Int }
    public static func handshake(_ data: Data) throws {
        let value: Handshake = try decode(data, keys: ["protocol", "modelRevision", "backendRevision", "artifactsVerified", "ready", "maxOutputTokens", "maxConcurrentRequests"])
        guard value.protocol == 1, value.modelRevision == modelRevision, value.backendRevision == backendRevision, value.artifactsVerified, value.ready,
              value.maxOutputTokens == 1024, value.maxConcurrentRequests == 1 else { throw Step5Error.invalid("The gateway is not ready with the pinned Step 5 backend and complete verified artifacts. Start scripts/run_step5_backend.py on your CUDA host.") }
    }
    public static func answer(_ data: Data) throws -> Step5Answer {
        let value: Step5Answer = try decode(data, keys: ["text", "truncated"])
        guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.text.contains("\0"), value.text.utf8.count <= 256 * 1024,
              value.text.range(of: #"</?(?:think|tool_call)|<\|(?:im_start|im_end|channel)|<｜"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw Step5Error.invalid("The gateway did not return a complete final answer. Private reasoning and tool output cannot be displayed.")
        }
        return value
    }
    /// Reject nesting, duplicate keys and trailing/partial JSON before the system decoder.
    private static func decode<T: Decodable>(_ data: Data, keys: Set<String>) throws -> T {
        let invalid = Step5Error.invalid("The Step 5 gateway returned invalid or incomplete protocol JSON.")
        guard data.count <= 300 * 1024 else { throw invalid }
        let bytes = Array(data); var offset = 0, seen: Set<String> = []
        func space() { while offset < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[offset]) { offset += 1 } }
        func take(_ byte: UInt8) throws { space(); guard offset < bytes.count, bytes[offset] == byte else { throw invalid }; offset += 1 }
        func string() throws -> Range<Int> {
            space(); let start = offset; try take(34)
            while offset < bytes.count { let byte = bytes[offset]; offset += 1; if byte == 92 { offset += 1; continue }; if byte == 34 { return start..<offset } }; throw invalid
        }
        do {
            try take(123)
            while true {
                let range = try string(); guard range.count <= 128 else { throw invalid }
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
                guard keys.contains(key), seen.insert(key).inserted else { throw invalid }; try take(58); space()
                guard offset < bytes.count else { throw invalid }
                if bytes[offset] == 34 { _ = try string() }
                else { let start = offset; while offset < bytes.count && ![UInt8(32), 9, 10, 13, 44, 125].contains(bytes[offset]) { offset += 1 }
                    let value = String(decoding: bytes[start..<offset], as: UTF8.self)
                    guard ["true", "false"].contains(value) || (value.count <= 20 && value.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil) else { throw invalid }
                }
                space(); if offset >= bytes.count || bytes[offset] != 44 { break }; offset += 1
            }
            try take(125); space(); guard offset == bytes.count, seen == keys else { throw invalid }
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw invalid }
    }
}

private final class Step5SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// A foreground connection to a user-owned CUDA host, separate from all local inference engines.
public actor Step5Client {
    private var activeSession: URLSession?
    private let sourceConfiguration: URLSessionConfiguration?
    public init(configuration: URLSessionConfiguration? = nil) { sourceConfiguration = configuration }
    public func cancel() { activeSession?.invalidateAndCancel() }
    private func run<T>(_ endpoint: String, work: (URL, URLSession, TimeInterval) async throws -> T) async throws -> T {
        guard activeSession == nil else { throw Step5Error.invalid("A Step 5 request is already running.") }
        let url = try Step5Contract.endpoint(endpoint)
        let configuration = (sourceConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 180; configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: Step5SessionDelegate(), delegateQueue: nil)
        activeSession = session
        defer { session.invalidateAndCancel(); activeSession = nil }
        return try await withTaskCancellationHandler(operation: { try await work(url, session, ProcessInfo.processInfo.systemUptime + 180) }, onCancel: { session.invalidateAndCancel() })
    }
    private func json(_ url: URL, session: URLSession, deadline: TimeInterval, body: Data? = nil, maximum: Int) async throws -> Data {
        try Task.checkCancellation(); let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Step5Error.invalid("The Step 5 request timed out.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(180, remaining))
        request.httpShouldHandleCookies = false
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= Int64(maximum) else { throw Step5Error.invalid("The Step 5 gateway rejected the request or exceeded its response limit.") }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximum, ProcessInfo.processInfo.systemUptime < deadline else { throw Step5Error.invalid("The Step 5 gateway exceeded its response or time limit.") }; data.append(byte)
        }
        return data
    }
    public func check(_ endpoint: String) async throws {
        try await run(endpoint) { url, session, deadline in try Step5Contract.handshake(await json(url.appendingPathComponent("quenderin/step5"), session: session, deadline: deadline, maximum: 8192)) }
    }
    public func answer(_ endpoint: String, messages: [Step5Message]) async throws -> Step5Answer {
        try Step5Contract.messages(messages)
        let body = try JSONEncoder().encode(["messages": messages])
        return try await run(endpoint) { url, session, deadline in
            try Step5Contract.handshake(await json(url.appendingPathComponent("quenderin/step5"), session: session, deadline: deadline, maximum: 8192))
            return try Step5Contract.answer(await json(url.appendingPathComponent("quenderin/step5/answer"), session: session, deadline: deadline, body: body, maximum: 300 * 1024))
        }
    }
}
