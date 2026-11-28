import Foundation

// MARK: - Bounded HTTP/1.1 Request Parser

/// Parsed HTTP/1.1 request produced by `LocalHTTPRequest.parse(_:)`.
/// Pure Foundation + deterministic → testable on Linux.
public struct LocalHTTPRequest: Sendable, Equatable {
    public static let maxHeaderBytes: Int = 16 * 1024       // 16 KiB
    public static let maxBodyBytes: Int = 4 * 1024 * 1024   // 4 MiB

    public let method: String
    /// Request path without query string (e.g. `"/v1/chat/completions"`).
    public let path: String
    /// Raw request target as sent on the request line (e.g. `"/v1/models?foo=1"`).
    public let rawTarget: String
    public let httpVersion: String
    /// Header names normalized to ASCII lowercase.
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        rawTarget: String? = nil,
        httpVersion: String = "HTTP/1.1",
        headers: [String: String],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.rawTarget = rawTarget ?? path
        self.httpVersion = httpVersion
        var lowered: [String: String] = [:]
        lowered.reserveCapacity(headers.count)
        for (k, v) in headers {
            lowered[k.lowercased()] = v
        }
        self.headers = lowered
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public enum ParseError: Error, Sendable, Equatable {
        case headersTooLarge
        case bodyTooLarge
        case chunkedNotSupported
        case malformedRequestLine
        case unsupportedHTTPVersion
        case malformedHeader
        case invalidContentLength
        case duplicateHeader(String)

        public var statusCode: Int {
            switch self {
            case .headersTooLarge: return 431
            case .bodyTooLarge: return 413
            case .chunkedNotSupported: return 411
            case .unsupportedHTTPVersion: return 505
            case .malformedRequestLine, .malformedHeader, .invalidContentLength, .duplicateHeader:
                return 400
            }
        }

        public var message: String {
            switch self {
            case .headersTooLarge:
                return "HTTP request headers exceed the 16 KiB limit."
            case .bodyTooLarge:
                return "HTTP request body exceeds the 4 MiB limit."
            case .chunkedNotSupported:
                return "Chunked transfer encoding is not supported; send a Content-Length header."
            case .malformedRequestLine:
                return "Malformed HTTP request line."
            case .unsupportedHTTPVersion:
                return "Unsupported HTTP version; expected HTTP/1.0 or HTTP/1.1."
            case .malformedHeader:
                return "Malformed HTTP header."
            case .invalidContentLength:
                return "Invalid Content-Length header."
            case .duplicateHeader(let name):
                return "Duplicate \(name) header is not allowed."
            }
        }

        public var errorCode: String {
            switch self {
            case .headersTooLarge: return "request_header_fields_too_large"
            case .bodyTooLarge: return "payload_too_large"
            case .chunkedNotSupported: return "length_required"
            case .unsupportedHTTPVersion: return "http_version_not_supported"
            case .malformedRequestLine, .malformedHeader, .invalidContentLength, .duplicateHeader:
                return "bad_request"
            }
        }
    }

    public enum ParseResult: Sendable, Equatable {
        case complete(LocalHTTPRequest, consumedBytes: Int)
        case needMore
        case error(ParseError)
        case rejected(LocalAPIError)
    }

    /// Incrementally parses a single HTTP/1.1 request from raw bytes.
    /// Rejects headers > 16 KiB, bodies > 4 MiB, and Transfer-Encoding (chunked) bodies.
    public static func parse(_ buffer: Data) -> ParseResult {
        parse(buffer, validateHeaders: { _ in nil })
    }

    /// Runs the security gate once headers are available, even if the body is incomplete.
    static func parse(_ buffer: Data, validateHeaders: (LocalHTTPRequest) -> LocalAPIError?) -> ParseResult {
        guard !buffer.isEmpty else { return .needMore }

        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes {
                return .error(.headersTooLarge)
            }
            return .needMore
        }

        let headerBlockEnd = sepRange.upperBound
        let headerByteCount = headerBlockEnd - buffer.startIndex
        if headerByteCount > maxHeaderBytes {
            return .error(.headersTooLarge)
        }

        let headerData = buffer[buffer.startIndex..<sepRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) else {
            return .error(.malformedHeader)
        }

        // Split strictly on CRLF; reject bare CR or LF inside header block.
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .error(.malformedRequestLine)
        }
        for line in lines {
            if line.contains("\r") || line.contains("\n") {
                return .error(.malformedHeader)
            }
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return .error(.malformedRequestLine)
        }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let version = String(parts[2])

        guard !method.isEmpty,
              method.unicodeScalars.allSatisfy({ $0.value >= 0x41 && $0.value <= 0x5A }),
              !rawTarget.isEmpty,
              rawTarget.hasPrefix("/") else {
            return .error(.malformedRequestLine)
        }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .error(.unsupportedHTTPVersion)
        }

        var headers: [String: String] = [:]
        var hasTransferEncoding = false
        var parsedContentLength: Int?

        for rawLine in lines.dropFirst() {
            guard let colonIdx = rawLine.firstIndex(of: ":") else {
                return .error(.malformedHeader)
            }
            let rawName = String(rawLine[..<colonIdx])
            guard !rawName.isEmpty, isValidHeaderName(rawName) else {
                return .error(.malformedHeader)
            }
            let lowerName = rawName.lowercased()
            let rawValue = String(rawLine[rawLine.index(after: colonIdx)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

            if lowerName == "transfer-encoding" {
                hasTransferEncoding = true
                headers[lowerName] = rawValue
                continue
            }

            if lowerName == "content-length" {
                guard let len = parseNonNegativeInt(rawValue) else {
                    return .error(.invalidContentLength)
                }
                if let existing = parsedContentLength, existing != len {
                    return .error(.duplicateHeader("Content-Length"))
                }
                parsedContentLength = len
                headers[lowerName] = rawValue
                continue
            }

            if lowerName == "host" || lowerName == "authorization" || lowerName == "origin" || lowerName == "content-type" {
                if headers[lowerName] != nil {
                    return .error(.duplicateHeader(rawName))
                }
                headers[lowerName] = rawValue
                continue
            }

            if let existing = headers[lowerName] {
                headers[lowerName] = existing + ", " + rawValue
            } else {
                headers[lowerName] = rawValue
            }
        }

        if hasTransferEncoding {
            // Never accept chunked or mixed Transfer-Encoding + Content-Length.
            if parsedContentLength != nil {
                return .error(.malformedHeader)
            }
            return .error(.chunkedNotSupported)
        }

        let contentLength = parsedContentLength ?? 0
        if contentLength > maxBodyBytes {
            return .error(.bodyTooLarge)
        }

        let path: String
        if let qIdx = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qIdx])
        } else {
            path = rawTarget
        }

        let head = LocalHTTPRequest(method: method, path: path, rawTarget: rawTarget,
                                    httpVersion: version, headers: headers)
        if let rejection = validateHeaders(head) { return .rejected(rejection) }
        let bodyStart = headerBlockEnd
        guard buffer.endIndex - bodyStart >= contentLength else { return .needMore }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = contentLength == 0 ? Data() : Data(buffer[bodyStart..<bodyEnd])
        let request = LocalHTTPRequest(
            method: method,
            path: path,
            rawTarget: rawTarget,
            httpVersion: version,
            headers: headers,
            body: body
        )
        return .complete(request, consumedBytes: headerByteCount + contentLength)
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        for scalar in name.unicodeScalars {
            let v = scalar.value
            // RFC 9110 tchar
            let ok = (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x21 || v == 0x23 || v == 0x24 || v == 0x25 || v == 0x26
                || v == 0x27 || v == 0x2A || v == 0x2B || v == 0x2D || v == 0x2E
                || v == 0x5E || v == 0x5F || v == 0x60 || v == 0x7C || v == 0x7E
            if !ok { return false }
        }
        return true
    }

    private static func parseNonNegativeInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 12 else { return nil }
        var value = 0
        for scalar in text.unicodeScalars {
            guard scalar.value >= 0x30 && scalar.value <= 0x39 else { return nil }
            let digit = Int(scalar.value - 0x30)
            let (mul, o1) = value.multipliedReportingOverflow(by: 10)
            if o1 { return nil }
            let (add, o2) = mul.addingReportingOverflow(digit)
            if o2 { return nil }
            value = add
        }
        return value
    }
}

// MARK: - OpenAI Error Shape & Security Gate

/// Rejection or API error returned as an OpenAI-shaped JSON body.
public struct LocalAPIError: Error, Sendable, Equatable {
    public let statusCode: Int
    public let message: String
    public let type: String
    public let code: String?

    public init(statusCode: Int, message: String, type: String, code: String? = nil) {
        self.statusCode = statusCode
        self.message = message
        self.type = type
        self.code = code
    }

    public static func badRequest(_ message: String, code: String? = "invalid_request") -> LocalAPIError {
        LocalAPIError(statusCode: 400, message: message, type: "invalid_request_error", code: code)
    }

    public static func unauthorized(_ message: String = "Invalid API key.") -> LocalAPIError {
        LocalAPIError(statusCode: 401, message: message, type: "authentication_error", code: "invalid_api_key")
    }

    public static func forbidden(_ message: String) -> LocalAPIError {
        LocalAPIError(statusCode: 403, message: message, type: "permission_error", code: "forbidden")
    }

    public static func notFound(_ message: String, code: String? = "not_found") -> LocalAPIError {
        LocalAPIError(statusCode: 404, message: message, type: "not_found_error", code: code)
    }

    public static func methodNotAllowed(_ message: String = "Method not allowed.") -> LocalAPIError {
        LocalAPIError(statusCode: 405, message: message, type: "invalid_request_error", code: "method_not_allowed")
    }

    public static func unsupportedMediaType(_ message: String = "Content-Type must be application/json.") -> LocalAPIError {
        LocalAPIError(statusCode: 415, message: message, type: "invalid_request_error", code: "unsupported_media_type")
    }

    public static func serverBusy(_ message: String = "Quenderin is busy with another request. Try again shortly.") -> LocalAPIError {
        LocalAPIError(statusCode: 503, message: message, type: "server_error", code: "server_busy")
    }

    static func connectionLimit() -> LocalAPIError {
        serviceUnavailable("Too many Local API connections. Try again shortly.", code: "connection_limit")
    }

    public static func serviceUnavailable(_ message: String, code: String? = "model_unavailable") -> LocalAPIError {
        LocalAPIError(statusCode: 503, message: message, type: "server_error", code: code)
    }

    public static func internalError(_ message: String) -> LocalAPIError {
        LocalAPIError(statusCode: 500, message: message, type: "server_error", code: "internal_error")
    }

    public static func fromParseError(_ error: LocalHTTPRequest.ParseError) -> LocalAPIError {
        LocalAPIError(
            statusCode: error.statusCode,
            message: error.message,
            type: "invalid_request_error",
            code: error.errorCode
        )
    }
}

/// Security gate evaluated on every incoming loopback HTTP request before routing.
public enum LocalAPIGuard {
    public static let defaultPort: UInt16 = 11435
    public static let minPort: UInt16 = 1024
    public static let maxPort: UInt16 = 65535

    /// Clamps a user-entered port into the valid unprivileged range `1024...65535`.
    public static func clampPort(_ port: Int) -> UInt16 {
        if port < Int(minPort) { return minPort }
        if port > Int(maxPort) { return maxPort }
        return UInt16(port)
    }

    /// Returns a `LocalAPIError` rejection if the request violates any loopback security invariant,
    /// or `nil` when allowed.
    ///
    /// Enforced checks:
    /// 1. `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (DNS-rebinding defence) -> 403.
    /// 2. Any `Origin` header present -> 403 (blocks browser pages; no CORS headers are ever sent).
    /// 3. Optional bearer key: when `requiredAPIKey` is non-empty, requires `Authorization: Bearer <key>`
    ///    using constant-time byte comparison -> 401. When empty/nil, any/no Authorization is accepted.
    /// 4. `POST` requests require `Content-Type: application/json` with valid optional parameters -> 415.
    public static func check(
        _ request: LocalHTTPRequest,
        port: UInt16,
        requiredAPIKey: String? = nil
    ) -> LocalAPIError? {
        // 1. Host check (DNS-rebinding defence)
        guard let hostRaw = request.header("host") else {
            return .forbidden("Missing Host header. Only 127.0.0.1:\(port) and localhost:\(port) are allowed.")
        }
        let host = hostRaw.lowercased()
        let allowedIP = "127.0.0.1:\(port)"
        let allowedLocalhost = "localhost:\(port)"
        if host != allowedIP && host != allowedLocalhost {
            return .forbidden("Disallowed Host header. Only 127.0.0.1:\(port) and localhost:\(port) are allowed.")
        }

        // 2. Origin check (block browser cross-origin and same-origin scripts)
        if request.header("origin") != nil {
            return .forbidden("Browser Origin requests are not allowed on the local API.")
        }

        // 3. Optional bearer API key check (constant-time compare)
        if let expectedKey = requiredAPIKey, !expectedKey.isEmpty {
            guard let authHeader = request.header("authorization"),
                  let token = extractBearerToken(authHeader),
                  constantTimeEquals(token, expectedKey) else {
                return .unauthorized("Missing or invalid Bearer API key.")
            }
        }

        // 4. POST requires Content-Type: application/json
        if request.method == "POST" {
            guard let contentType = request.header("content-type"),
                  isJSONContentType(contentType) else {
                return .unsupportedMediaType("POST requests require Content-Type: application/json.")
            }
        }

        return nil
    }

    /// Constant-time UTF-8 string equality check to avoid timing side-channels on bearer keys.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        let maxCount = max(lhs.count, rhs.count)
        var diff: UInt8 = lhs.count == rhs.count ? 0 : 1
        for i in 0..<maxCount {
            let x: UInt8 = i < lhs.count ? lhs[i] : 0
            let y: UInt8 = i < rhs.count ? rhs[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    private static func extractBearerToken(_ headerValue: String) -> String? {
        let trimmed = headerValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        let prefix = "bearer "
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).lowercased() == prefix else {
            return nil
        }
        let token = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return token.isEmpty ? nil : token
    }

    private static let jsonContentType = {
        // HTTP parameter = token "=" ( token / quoted-string ). Commas are valid inside quotes.
        let token = #"[!#$%&'*+\-.^_\x60|~0-9A-Za-z]+"#
        let quoted = #""(?:[\t\x20\x21\x23-\x5B\x5D-\x7E\x{80}-\x{10FFFF}]|\\[\t\x20-\x7E\x{80}-\x{10FFFF}])*""#
        return try! NSRegularExpression(
            pattern: #"\A[ \t]*(?i:application/json)(?:[ \t]*;[ \t]*\#(token)=(?:\#(token)|\#(quoted)))*[ \t]*\z"#
        )
    }()

    private static func isJSONContentType(_ raw: String) -> Bool {
        jsonContentType.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }
}

// MARK: - OpenAI Chat Completions Models & Codec

public struct LocalAPIModelInfo: Sendable, Equatable {
    public let id: String
    public let created: Int

    public init(id: String, created: Int = 1_700_000_000) {
        self.id = id
        self.created = created
    }
}

public struct LocalAPIMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LocalAPIResponseFormat: Sendable, Equatable {
    case text
    case jsonObject
    /// Holds the compiled GBNF grammar (or `JSONOutputGrammar.anyJSONObject` when the schema
    /// uses unsupported keywords and falls back).
    case jsonSchema(grammar: String, fellBackToGeneric: Bool)

    public var gbnfGrammar: String? {
        switch self {
        case .text:
            return nil
        case .jsonObject:
            return JSONOutputGrammar.anyJSONObject
        case .jsonSchema(let grammar, _):
            return grammar
        }
    }
}

public struct LocalAPIChatRequest: Sendable, Equatable {
    public static let defaultMaxTokens: Int = 512
    public static let maxAllowedTokens: Int = 4096
    public static let defaultTemperature: Double = 0.7
    public static let defaultTopP: Double = 0.95

    public let model: String
    public let messages: [LocalAPIMessage]
    public let stream: Bool
    public let maxTokens: Int
    public let temperature: Double
    public let topP: Double
    public let stop: [String]
    public let responseFormat: LocalAPIResponseFormat
    public let think: Bool

    public init(
        model: String,
        messages: [LocalAPIMessage],
        stream: Bool = false,
        maxTokens: Int = defaultMaxTokens,
        temperature: Double = defaultTemperature,
        topP: Double = defaultTopP,
        stop: [String] = [],
        responseFormat: LocalAPIResponseFormat = .text,
        think: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.responseFormat = responseFormat
        self.think = think
    }

    /// Thinking semantics: `think: true` maps to `.show` (reasoning returned separately),
    /// unless a JSON GBNF grammar is active (grammars require direct JSON output).
    public var effectiveThinkingMode: ThinkingMode {
        if responseFormat.gbnfGrammar != nil { return .off }
        return think ? .show : .off
    }

    /// Splits messages into a single system prompt (joining multiple system messages with `\n\n`)
    /// and the ordered user/assistant conversation turns.
    public var splitPrompt: (system: String, turns: [LocalAPIMessage]) {
        var systemParts: [String] = []
        var turns: [LocalAPIMessage] = []
        for msg in messages {
            if msg.role == .system {
                if !msg.content.isEmpty {
                    systemParts.append(msg.content)
                }
            } else {
                turns.append(msg)
            }
        }
        return (systemParts.joined(separator: "\n\n"), turns)
    }
}

public struct LocalAPIUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum LocalAPIFinishReason: String, Sendable, Equatable {
    case stop = "stop"
    case length = "length"

    static func completion(for status: ChatCapStatus) throws -> Self {
        switch status {
        case .hit, .contextExhausted: return .length
        case .notHit, .unknown: return .stop
        case .decodeFailed:
            throw LocalAPIError(statusCode: 500, message: "Native decoding failed after generating partial output.",
                                type: "server_error", code: "decode_failed")
        }
    }
}

/// Pure OpenAI-compatible JSON + SSE codec for `/v1/models` and `/v1/chat/completions`.
public enum LocalAPICodec {
    static let maxStopSequences = 4
    static let maxStopSequenceBytes = 256

    /// Generates an OpenAI-style completion ID (`chatcmpl-<hex>`).
    public static func makeCompletionID() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "chatcmpl-\(hex.prefix(24))"
    }

    /// Encodes `GET /v1/models`.
    public static func encodeModelsList(_ models: [LocalAPIModelInfo]) -> Data {
        let items: [[String: Any]] = models.map { m in
            [
                "id": m.id,
                "object": "model",
                "created": m.created,
                "owned_by": "quenderin",
            ]
        }
        let payload: [String: Any] = [
            "object": "list",
            "data": items,
        ]
        return encodeJSONObject(payload)
    }

    /// Decodes and validates a `POST /v1/chat/completions` JSON body.
    /// - Parameters:
    ///   - data: Raw UTF-8 JSON request body.
    ///   - availableModelIDs: Installed/loadable model IDs (must include `activeModelID` if non-nil).
    ///   - activeModelID: The currently loaded/active model ID (used when `model` is omitted).
    public static func decodeChatRequest(
        _ data: Data,
        availableModelIDs: [String],
        activeModelID: String?
    ) -> Result<LocalAPIChatRequest, LocalAPIError> {
        guard !data.isEmpty else {
            return .failure(.badRequest("Request body must be a JSON object."))
        }
        guard let decodedRoot = StrictWireJSONParser.parse(data) else {
            return .failure(.badRequest("Malformed JSON in request body."))
        }
        guard case .object(let root) = decodedRoot else {
            return .failure(.badRequest("Request body must be a JSON object."))
        }

        // Reject tools / tool_choice whenever present (including explicit JSON null; never silently ignore).
        if root.hasExactKey("tools") {
            return .failure(.badRequest("tools are not supported yet", code: "unsupported_parameter"))
        }
        if root.hasExactKey("tool_choice") {
            return .failure(.badRequest("tools are not supported yet", code: "unsupported_parameter"))
        }

        // Resolve and validate model.
        var allowed = Set(availableModelIDs)
        if let active = activeModelID, !active.isEmpty {
            allowed.insert(active)
        }
        let resolvedModel: String
        if let rawModel = root.exactValue(forKey: "model"), !rawModel.isNull {
            guard case .string(let modelName) = rawModel, !modelName.isEmpty else {
                return .failure(.badRequest("'model' must be a non-empty string."))
            }
            guard allowed.contains(modelName) else {
                return .failure(.notFound("The model '\(modelName)' is not installed on this Mac.", code: "model_not_found"))
            }
            resolvedModel = modelName
        } else if let active = activeModelID, !active.isEmpty {
            resolvedModel = active
        } else if let first = availableModelIDs.first, !first.isEmpty {
            resolvedModel = first
        } else {
            return .failure(.serviceUnavailable("No model is installed in Quenderin yet. Download a model in the app first."))
        }

        // Parse messages.
        guard case .array(let rawMessages) = root.exactValue(forKey: "messages"), !rawMessages.isEmpty else {
            return .failure(.badRequest("'messages' must be a non-empty array."))
        }
        var messages: [LocalAPIMessage] = []
        messages.reserveCapacity(rawMessages.count)
        for item in rawMessages {
            guard case .object(let obj) = item else {
                return .failure(.badRequest("Each item in 'messages' must be an object."))
            }
            guard case .string(let roleStr) = obj.exactValue(forKey: "role"),
                  let role = LocalAPIMessage.Role(rawValue: roleStr) else {
                return .failure(.badRequest("Message 'role' must be one of: system, user, assistant."))
            }
            guard let rawContent = obj.exactValue(forKey: "content"), !rawContent.isNull else {
                return .failure(.badRequest("Message 'content' is required."))
            }
            let contentText: String
            switch rawContent {
            case .string(let str):
                contentText = str
            case .array(let parts):
                var textPieces: [String] = []
                for partVal in parts {
                    guard case .object(let part) = partVal,
                          case .string(let partType) = part.exactValue(forKey: "type") else {
                        return .failure(.badRequest("Each content part must be an object with a string 'type'."))
                    }
                    if partType == "image_url" || partType == "image" || partType == "input_image" {
                        return .failure(.badRequest("images are not supported by this endpoint yet", code: "unsupported_content_type"))
                    }
                    guard partType == "text" else {
                        return .failure(.badRequest("Unsupported content part type '\(partType)'. Only 'text' is supported."))
                    }
                    guard case .string(let text) = part.exactValue(forKey: "text") else {
                        return .failure(.badRequest("Content part with type 'text' must include a string 'text' field."))
                    }
                    textPieces.append(text)
                }
                contentText = textPieces.joined(separator: "\n")
            default:
                return .failure(.badRequest("Message 'content' must be a string or an array of content parts."))
            }
            messages.append(LocalAPIMessage(role: role, content: contentText))
        }

        // stream
        let stream: Bool
        if let rawStream = root.exactValue(forKey: "stream"), !rawStream.isNull {
            guard case .bool(let b) = rawStream else {
                return .failure(.badRequest("'stream' must be a boolean."))
            }
            stream = b
        } else {
            stream = false
        }

        // think (Quenderin/Ollama extension)
        let think: Bool
        if let rawThink = root.exactValue(forKey: "think"), !rawThink.isNull {
            guard case .bool(let b) = rawThink else {
                return .failure(.badRequest("'think' must be a boolean."))
            }
            think = b
        } else {
            think = false
        }

        // max_completion_tokens / max_tokens (clamp 1...4096, default 512)
        let maxTokens: Int
        if let rawMaxComp = root.exactValue(forKey: "max_completion_tokens"), !rawMaxComp.isNull {
            guard case .int(let n) = rawMaxComp else {
                return .failure(.badRequest("'max_completion_tokens' must be an integer."))
            }
            maxTokens = min(max(n, 1), LocalAPIChatRequest.maxAllowedTokens)
        } else if let rawMax = root.exactValue(forKey: "max_tokens"), !rawMax.isNull {
            guard case .int(let n) = rawMax else {
                return .failure(.badRequest("'max_tokens' must be an integer."))
            }
            maxTokens = min(max(n, 1), LocalAPIChatRequest.maxAllowedTokens)
        } else {
            maxTokens = LocalAPIChatRequest.defaultMaxTokens
        }

        // temperature (clamp 0...2)
        let temperature: Double
        if let rawTemp = root.exactValue(forKey: "temperature"), !rawTemp.isNull {
            guard let d = rawTemp.asDouble, d.isFinite else {
                return .failure(.badRequest("'temperature' must be a number."))
            }
            temperature = min(max(d, 0.0), 2.0)
        } else {
            temperature = LocalAPIChatRequest.defaultTemperature
        }

        // top_p (clamp 0...1)
        let topP: Double
        if let rawTopP = root.exactValue(forKey: "top_p"), !rawTopP.isNull {
            guard let d = rawTopP.asDouble, d.isFinite else {
                return .failure(.badRequest("'top_p' must be a number."))
            }
            topP = min(max(d, 0.0), 1.0)
        } else {
            topP = LocalAPIChatRequest.defaultTopP
        }

        // stop (string or array of strings)
        var stop: [String] = []
        if let rawStop = root.exactValue(forKey: "stop"), !rawStop.isNull {
            let entries: [WireJSONValue]
            switch rawStop {
            case .string: entries = [rawStop]
            case .array(let arr): entries = arr
            default:
                return .failure(.badRequest("'stop' must be a string or an array of strings."))
            }
            var seen = Set<Data>()
            for item in entries {
                guard case .string(let sequence) = item else {
                    return .failure(.badRequest("'stop' array entries must be strings."))
                }
                guard !sequence.isEmpty else { continue }
                guard sequence.utf8.count <= maxStopSequenceBytes else {
                    return .failure(.badRequest("Each 'stop' sequence may contain up to \(maxStopSequenceBytes) UTF-8 bytes."))
                }
                if seen.insert(Data(sequence.utf8)).inserted {
                    guard stop.count < maxStopSequences else {
                        return .failure(.badRequest("'stop' accepts up to \(maxStopSequences) distinct nonempty sequences."))
                    }
                    stop.append(sequence)
                }
            }
        }

        // response_format
        let responseFormat: LocalAPIResponseFormat
        if let rawRF = root.exactValue(forKey: "response_format"), !rawRF.isNull {
            guard case .object(let rfObj) = rawRF,
                  case .string(let rfType) = rfObj.exactValue(forKey: "type") else {
                return .failure(.badRequest("'response_format' must be an object with a string 'type'."))
            }
            switch rfType {
            case "text":
                responseFormat = .text
            case "json_object":
                responseFormat = .jsonObject
            case "json_schema":
                guard case .object(let jsObj) = rfObj.exactValue(forKey: "json_schema"),
                      let schemaVal = jsObj.exactValue(forKey: "schema"), !schemaVal.isNull else {
                    return .failure(.badRequest("'response_format.json_schema.schema' is required for type 'json_schema'."))
                }
                let strict: Bool
                if let value = jsObj.exactValue(forKey: "strict"), !value.isNull {
                    guard case .bool(let enabled) = value else {
                        return .failure(.badRequest("'response_format.json_schema.strict' must be a boolean."))
                    }
                    strict = enabled
                } else {
                    strict = false
                }
                switch JSONOutputGrammar.grammar(forSchema: schemaVal.toOrderedFoundationAny(), strict: strict) {
                case .success(let grammar):
                    responseFormat = .jsonSchema(grammar: grammar, fellBackToGeneric: false)
                case .failure(.invalid(let reason)):
                    return .failure(.badRequest(reason, code: "invalid_response_schema"))
                case .failure(.unsupported(let reason)) where strict:
                    return .failure(.badRequest(reason, code: "unsupported_response_format"))
                case .failure(.unsupported):
                    responseFormat = .jsonSchema(grammar: JSONOutputGrammar.anyJSONObject, fellBackToGeneric: true)
                }
            default:
                return .failure(.badRequest("Unsupported response_format type '\(rfType)'. Expected 'text', 'json_object', or 'json_schema'."))
            }
        } else {
            responseFormat = .text
        }

        if !stop.isEmpty, responseFormat.gbnfGrammar != nil {
            return .failure(.badRequest("Nonempty 'stop' sequences cannot be used with JSON response formats.",
                                        code: "unsupported_response_format"))
        }

        return .success(LocalAPIChatRequest(
            model: resolvedModel,
            messages: messages,
            stream: stream,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stop: stop,
            responseFormat: responseFormat,
            think: think
        ))
    }

    /// Encodes a non-streaming OpenAI `chat.completion` response.
    public static func encodeChatCompletion(
        id: String,
        created: Int,
        model: String,
        content: String,
        reasoningContent: String? = nil,
        includeReasoning: Bool = false,
        finishReason: LocalAPIFinishReason,
        usage: LocalAPIUsage? = nil
    ) -> Data {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        if includeReasoning, let reasoning = reasoningContent, !reasoning.isEmpty {
            message["reasoning_content"] = reasoning
        }
        var payload: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": message,
                    "finish_reason": finishReason.rawValue,
                ] as [String: Any]
            ],
        ]
        if let usage {
            payload["usage"] = [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.totalTokens,
            ]
        }
        return encodeJSONObject(payload)
    }

    /// Encodes one SSE `data: {chat.completion.chunk}\n\n` frame.
    public static func encodeStreamChunk(
        id: String,
        created: Int,
        model: String,
        role: String? = nil,
        content: String? = nil,
        reasoningContent: String? = nil,
        finishReason: LocalAPIFinishReason? = nil
    ) -> Data {
        var delta: [String: Any] = [:]
        if let role { delta["role"] = role }
        if let content { delta["content"] = content }
        if let reasoningContent { delta["reasoning_content"] = reasoningContent }

        let choice: [String: Any] = [
            "index": 0,
            "delta": delta,
            "finish_reason": finishReason?.rawValue ?? NSNull(),
        ]
        let payload: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [choice],
        ]
        var frame = Data("data: ".utf8)
        frame.append(encodeJSONObject(payload))
        frame.append(Data("\n\n".utf8))
        return frame
    }

    /// Encodes the terminal SSE sentinel `data: [DONE]\n\n`.
    public static let streamDoneFrame: Data = Data("data: [DONE]\n\n".utf8)

    /// Terminates a failed stream whose HTTP headers have already been sent.
    static func encodeStreamError(_ error: LocalAPIError) -> Data {
        var frame = Data("data: ".utf8)
        frame.append(encodeError(error))
        frame.append(Data("\n\n".utf8))
        return frame
    }

    /// Encodes an OpenAI-shaped error object `{"error":{"message":...,"type":...,"code":...}}`.
    public static func encodeError(_ error: LocalAPIError) -> Data {
        let errObj: [String: Any] = [
            "message": error.message,
            "type": error.type,
            "code": error.code ?? NSNull(),
        ]
        return encodeJSONObject(["error": errObj])
    }

    // MARK: - Helpers

    private static func encodeJSONObject(_ dict: [String: Any]) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        #if canImport(Darwin) || os(Linux)
        options.insert(.withoutEscapingSlashes)
        #endif
        return (try? JSONSerialization.data(withJSONObject: dict, options: options)) ?? Data("{}".utf8)
    }

    /// Strict, platform-independent JSON value that preserves object key order and distinguishes
    /// keys by exact UTF-8 bytes (never collapsing canonically equivalent Unicode spellings like
    /// `"\u{00e9}"` and `"e\u{0301}"` in a Swift `[String: ...]` dictionary) while keeping `Bool`
    /// distinct from numeric `0`/`1` across Darwin and Linux.
    /// Maintains a `[UInt8]: Int` byte-keyed index alongside ordered entries so wide JSON objects
    /// parse and look up keys in O(1) amortized time instead of quadratic scans.
    private struct WireJSONObject {
        let entries: [(key: String, utf8Key: [UInt8], value: WireJSONValue)]
        let indexByUTF8Key: [[UInt8]: Int]

        func hasExactKey(_ key: String) -> Bool {
            indexByUTF8Key[Array(key.utf8)] != nil
        }

        func exactValue(forKey key: String) -> WireJSONValue? {
            guard let idx = indexByUTF8Key[Array(key.utf8)] else { return nil }
            return entries[idx].value
        }
    }

    private enum WireJSONValue {
        case object(WireJSONObject)
        case array([WireJSONValue])
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        var isNull: Bool {
            if case .null = self { return true }
            return false
        }

        var asDouble: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }

        /// Converts into Foundation values using `JSONOutputGrammar.OrderedObject` for every JSON
        /// object so `JSONOutputGrammar.grammar(forSchema:)` never collapses canonically equivalent
        /// Unicode property names and preserves exact declared key order.
        func toOrderedFoundationAny() -> Any {
            switch self {
            case .object(let obj):
                return JSONOutputGrammar.OrderedObject(
                    obj.entries.map { ($0.key, $0.value.toOrderedFoundationAny()) }
                )
            case .array(let arr):
                return arr.map { $0.toOrderedFoundationAny() }
            case .string(let s):
                return s
            case .int(let i):
                return i
            case .double(let d):
                return d
            case .bool(let b):
                return b
            case .null:
                return NSNull()
            }
        }
    }

    /// Minimal RFC-8259 recursive-descent JSON parser preserving exact UTF-8 keys and order.
    private struct StrictWireJSONParser {
        private let bytes: [UInt8]
        private var pos: Int = 0
        private static let maxDepth = 128

        static func parse(_ data: Data) -> WireJSONValue? {
            var parser = StrictWireJSONParser(bytes: Array(data))
            return parser.parseDocument()
        }

        private mutating func parseDocument() -> WireJSONValue? {
            skipWS()
            guard let val = parseValue(depth: 0) else { return nil }
            skipWS()
            guard pos == bytes.count else { return nil }
            return val
        }

        private mutating func skipWS() {
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    pos += 1
                } else {
                    break
                }
            }
        }

        private mutating func parseValue(depth: Int) -> WireJSONValue? {
            guard depth <= Self.maxDepth, pos < bytes.count else { return nil }
            switch bytes[pos] {
            case 0x7B: return parseObject(depth: depth + 1)
            case 0x5B: return parseArray(depth: depth + 1)
            case 0x22:
                guard let s = parseString() else { return nil }
                return .string(s)
            case 0x74: return parseLiteral("true") ? .bool(true) : nil
            case 0x66: return parseLiteral("false") ? .bool(false) : nil
            case 0x6E: return parseLiteral("null") ? .null : nil
            case 0x2D, 0x30...0x39: return parseNumber()
            default: return nil
            }
        }

        private mutating func parseObject(depth: Int) -> WireJSONValue? {
            pos += 1 // '{'
            skipWS()
            var entries: [(key: String, utf8Key: [UInt8], value: WireJSONValue)] = []
            var indexByUTF8Key: [[UInt8]: Int] = [:]
            if pos < bytes.count && bytes[pos] == 0x7D {
                pos += 1
                return .object(WireJSONObject(entries: entries, indexByUTF8Key: indexByUTF8Key))
            }
            while true {
                guard pos < bytes.count && bytes[pos] == 0x22,
                      let key = parseString() else { return nil }
                skipWS()
                guard pos < bytes.count && bytes[pos] == 0x3A else { return nil }
                pos += 1
                skipWS()
                guard let val = parseValue(depth: depth) else { return nil }
                let utf8Key = Array(key.utf8)
                if let existingIdx = indexByUTF8Key[utf8Key] {
                    entries[existingIdx] = (key, utf8Key, val)
                } else {
                    indexByUTF8Key[utf8Key] = entries.count
                    entries.append((key, utf8Key, val))
                }
                skipWS()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == 0x7D {
                    pos += 1
                    return .object(WireJSONObject(entries: entries, indexByUTF8Key: indexByUTF8Key))
                }
                guard bytes[pos] == 0x2C else { return nil }
                pos += 1
                skipWS()
            }
        }

        private mutating func parseArray(depth: Int) -> WireJSONValue? {
            pos += 1 // '['
            skipWS()
            var items: [WireJSONValue] = []
            if pos < bytes.count && bytes[pos] == 0x5D {
                pos += 1
                return .array(items)
            }
            while true {
                guard let val = parseValue(depth: depth) else { return nil }
                items.append(val)
                skipWS()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == 0x5D {
                    pos += 1
                    return .array(items)
                }
                guard bytes[pos] == 0x2C else { return nil }
                pos += 1
                skipWS()
            }
        }

        private mutating func parseString() -> String? {
            guard pos < bytes.count && bytes[pos] == 0x22 else { return nil }
            pos += 1
            var out: [UInt8] = []
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 0x22 {
                    pos += 1
                    return String(bytes: out, encoding: .utf8)
                }
                if b < 0x20 { return nil }
                if b == 0x5C {
                    pos += 1
                    guard pos < bytes.count else { return nil }
                    let esc = bytes[pos]
                    pos += 1
                    switch esc {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75:
                        guard let u1 = parseHex4() else { return nil }
                        let scalarValue: UInt32
                        if (0xD800...0xDBFF).contains(u1) {
                            guard pos + 1 < bytes.count,
                                  bytes[pos] == 0x5C,
                                  bytes[pos + 1] == 0x75 else { return nil }
                            pos += 2
                            guard let u2 = parseHex4(), (0xDC00...0xDFFF).contains(u2) else { return nil }
                            scalarValue = 0x10000 + ((u1 - 0xD800) << 10) + (u2 - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(u1) {
                            return nil
                        } else {
                            scalarValue = u1
                        }
                        guard let scalar = UnicodeScalar(scalarValue) else { return nil }
                        out.append(contentsOf: String(scalar).utf8)
                    default:
                        return nil
                    }
                } else {
                    out.append(b)
                    pos += 1
                }
            }
            return nil
        }

        private mutating func parseHex4() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            var val: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[pos]
                pos += 1
                let digit: UInt32
                switch b {
                case 0x30...0x39: digit = UInt32(b - 0x30)
                case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
                default: return nil
                }
                val = (val << 4) | digit
            }
            return val
        }

        private mutating func parseLiteral(_ literal: String) -> Bool {
            let expected = Array(literal.utf8)
            guard pos + expected.count <= bytes.count else { return false }
            for i in 0..<expected.count {
                if bytes[pos + i] != expected[i] { return false }
            }
            pos += expected.count
            return true
        }

        private mutating func parseNumber() -> WireJSONValue? {
            let start = pos
            var isFloat = false
            if pos < bytes.count && bytes[pos] == 0x2D { pos += 1 }
            guard pos < bytes.count else { return nil }
            if bytes[pos] == 0x30 {
                pos += 1
            } else if (0x31...0x39).contains(bytes[pos]) {
                pos += 1
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            } else {
                return nil
            }
            if pos < bytes.count && bytes[pos] == 0x2E {
                isFloat = true
                pos += 1
                guard pos < bytes.count && (0x30...0x39).contains(bytes[pos]) else { return nil }
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            }
            if pos < bytes.count && (bytes[pos] == 0x65 || bytes[pos] == 0x45) {
                isFloat = true
                pos += 1
                if pos < bytes.count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) { pos += 1 }
                guard pos < bytes.count && (0x30...0x39).contains(bytes[pos]) else { return nil }
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            }
            guard let text = String(bytes: bytes[start..<pos], encoding: .utf8) else { return nil }
            if !isFloat, let intVal = Int(text) {
                return .int(intVal)
            }
            guard let dblVal = Double(text), dblVal.isFinite else { return nil }
            return .double(dblVal)
        }
    }
}

// MARK: - HTTP/1.1 Response Wire Framing (no CORS headers ever emitted)

public enum LocalHTTPResponse {
    public static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Error"
        }
    }

    /// Builds a complete HTTP/1.1 JSON response. Never emits CORS headers.
    public static func json(statusCode: Int, body: Data) -> Data {
        json(statusCode: statusCode, body: body, retryAfterSeconds: nil)
    }

    private static func json(statusCode: Int, body: Data, retryAfterSeconds: Int?) -> Data {
        let retryAfter = retryAfterSeconds.map { "Retry-After: \($0)\r\n" } ?? ""
        let header = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + retryAfter
            + "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    /// Builds a complete HTTP/1.1 OpenAI-shaped error response. Never emits CORS headers.
    public static func error(_ apiError: LocalAPIError) -> Data {
        json(statusCode: apiError.statusCode, body: LocalAPICodec.encodeError(apiError))
    }

    static func connectionLimit() -> Data {
        let error = LocalAPIError.connectionLimit()
        return json(statusCode: error.statusCode, body: LocalAPICodec.encodeError(error), retryAfterSeconds: 5)
    }

    /// Builds HTTP/1.1 response headers for `text/event-stream` SSE streaming. Never emits CORS headers.
    public static func sseHeaders() -> Data {
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream; charset=utf-8\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "X-Accel-Buffering: no\r\n"
            + "\r\n"
        return Data(header.utf8)
    }
}

/// Coalescing byte queue that decouples native token generation from socket SSE writes so a slow
/// reader never retains the exclusive inference lease after native generation completes.
/// Pure Foundation + deterministic -> unit-testable on Linux.
public final class LocalSSEStreamBuffer: @unchecked Sendable {
    public struct Batch: Sendable, Equatable {
        public let data: Data
        public let isFinished: Bool
        public let isAborted: Bool

        public init(data: Data, isFinished: Bool, isAborted: Bool) {
            self.data = data
            self.isFinished = isFinished
            self.isAborted = isAborted
        }
    }

    private static let sseProbeBytes = Data(":\n\n".utf8)

    private let lock = NSLock()
    private let maxBufferedBytes: Int
    private var pending = Data()
    private var hasEnqueuedData = false
    private var finished = false
    private var aborted = false
    private var waiter: CheckedContinuation<Batch, Never>?

    public init(maxBufferedBytes: Int = 8 * 1024 * 1024) {
        self.maxBufferedBytes = max(1024, maxBufferedBytes)
    }

    public var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    /// Enqueues encoded SSE bytes without blocking on socket I/O. Returns `false` if already
    /// aborted, already finished, or if `maxBufferedBytes` would be exceeded.
    @discardableResult
    public func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return !isAborted }
        var resumeWaiter: CheckedContinuation<Batch, Never>?
        var batchToResume: Batch?
        lock.lock()
        if aborted || finished {
            lock.unlock()
            return false
        }
        if pending.count + data.count > maxBufferedBytes {
            aborted = true
            pending.removeAll(keepingCapacity: false)
            resumeWaiter = waiter
            waiter = nil
            batchToResume = Batch(data: Data(), isFinished: true, isAborted: true)
            lock.unlock()
            resumeWaiter?.resume(returning: batchToResume!)
            return false
        }
        pending.append(data)
        hasEnqueuedData = true
        if let w = waiter {
            waiter = nil
            let out = pending
            pending = Data()
            resumeWaiter = w
            batchToResume = Batch(data: out, isFinished: false, isAborted: false)
        }
        lock.unlock()
        if let w = resumeWaiter, let batch = batchToResume {
            w.resume(returning: batch)
        }
        return true
    }

    /// Enqueues a harmless SSE comment probe (`:\n\n`) through the same ordered stream buffer as
    /// HTTP headers and SSE frames so a peer FIN can never write bytes ahead of the HTTP status
    /// line or race with an in-flight chunk write.
    ///
    /// Returns `true` when a probe frame was enqueued or delivered to an idle waiting writer.
    /// Returns `false` if headers/initial data have not been enqueued yet, if non-empty bytes are
    /// already queued for immediate delivery, if the stream is finished/aborted, or if the buffer
    /// cap would be exceeded.
    @discardableResult
    public func enqueueProbe() -> Bool {
        var resumeWaiter: CheckedContinuation<Batch, Never>?
        var batchToResume: Batch?
        lock.lock()
        guard !aborted, !finished, hasEnqueuedData, pending.isEmpty else {
            lock.unlock()
            return false
        }
        let probe = Self.sseProbeBytes
        guard pending.count + probe.count <= maxBufferedBytes else {
            lock.unlock()
            return false
        }
        if let w = waiter {
            waiter = nil
            resumeWaiter = w
            batchToResume = Batch(data: probe, isFinished: false, isAborted: false)
        } else {
            pending.append(probe)
        }
        lock.unlock()
        if let w = resumeWaiter, let batch = batchToResume {
            w.resume(returning: batch)
        }
        return true
    }

    /// Appends terminal SSE bytes and signals that native generation has completed.
    public func finish(finalData: Data = Data()) {
        var resumeWaiter: CheckedContinuation<Batch, Never>?
        var batchToResume: Batch?
        lock.lock()
        if !aborted && !finished {
            if !finalData.isEmpty {
                pending.append(finalData)
            }
            finished = true
            if let w = waiter {
                waiter = nil
                let out = pending
                pending = Data()
                resumeWaiter = w
                batchToResume = Batch(data: out, isFinished: true, isAborted: false)
            }
        }
        lock.unlock()
        if let w = resumeWaiter, let batch = batchToResume {
            w.resume(returning: batch)
        }
    }

    /// Aborts pending delivery (e.g. client disconnect or write timeout) and wakes any waiting reader.
    public func abort() {
        var resumeWaiter: CheckedContinuation<Batch, Never>?
        lock.lock()
        aborted = true
        pending.removeAll(keepingCapacity: false)
        resumeWaiter = waiter
        waiter = nil
        lock.unlock()
        resumeWaiter?.resume(returning: Batch(data: Data(), isFinished: true, isAborted: true))
    }

    /// Drains ordered batches and reports whether the transport accepted the terminal bytes.
    func writeFrames(send: @Sendable (Data, Bool) async -> Bool) async -> Bool {
        while true {
            let batch = await nextBatch()
            guard !Task.isCancelled, !batch.isAborted, !batch.data.isEmpty else { return false }
            guard await send(batch.data, batch.isFinished) else {
                abort()
                return false
            }
            if batch.isFinished { return true }
        }
    }

    /// Awaits the next coalesced batch of bytes for the socket writer.
    public func nextBatch() async -> Batch {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if aborted {
                    lock.unlock()
                    continuation.resume(returning: Batch(data: Data(), isFinished: true, isAborted: true))
                    return
                }
                if !pending.isEmpty {
                    let out = pending
                    pending = Data()
                    let done = finished
                    lock.unlock()
                    continuation.resume(returning: Batch(data: out, isFinished: done, isAborted: false))
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(returning: Batch(data: Data(), isFinished: true, isAborted: false))
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            self.abort()
        }
    }
}
