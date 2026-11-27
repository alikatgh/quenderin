import XCTest
@testable import QuenderinKit

final class LocalAPIProtocolTests: XCTestCase {
    // MARK: - HTTP/1.1 Request Parsing

    func testParseSimpleGetRequestAndCaseInsensitiveHeaders() {
        let raw = Data("GET /v1/models?verbose=1 HTTP/1.1\r\nHoSt: 127.0.0.1:11435\r\nX-Custom: abc\r\n\r\n".utf8)
        let result = LocalHTTPRequest.parse(raw)
        guard case .complete(let req, let consumed) = result else {
            return XCTFail("Expected complete request, got \(result)")
        }
        XCTAssertEqual(consumed, raw.count)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/v1/models")
        XCTAssertEqual(req.rawTarget, "/v1/models?verbose=1")
        XCTAssertEqual(req.header("HOST"), "127.0.0.1:11435")
        XCTAssertEqual(req.header("x-custom"), "abc")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testParseSplitAcrossReads() {
        let body = #"{"messages":[{"role":"user","content":"hi"}]}"#
        let full = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1:11435\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "\r\n"
            + body
        let bytes = Array(full.utf8)

        var acc = Data()
        for idx in 0..<(bytes.count - 1) {
            acc.append(bytes[idx])
            XCTAssertEqual(LocalHTTPRequest.parse(acc), .needMore, "Should needMore at byte \(idx)")
        }
        acc.append(bytes[bytes.count - 1])
        guard case .complete(let req, let consumed) = LocalHTTPRequest.parse(acc) else {
            return XCTFail("Expected complete request on final byte")
        }
        XCTAssertEqual(consumed, bytes.count)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/chat/completions")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)
    }

    func testParseRejectsOversizeHeadersAndBody() {
        // Oversize header without terminator (> 16 KiB)
        let hugeHeader = Data(repeating: UInt8(ascii: "a"), count: LocalHTTPRequest.maxHeaderBytes + 1)
        XCTAssertEqual(LocalHTTPRequest.parse(hugeHeader), .error(.headersTooLarge))
        XCTAssertEqual(LocalHTTPRequest.ParseError.headersTooLarge.statusCode, 431)

        // Oversize header with terminator (> 16 KiB)
        let padding = String(repeating: "x", count: LocalHTTPRequest.maxHeaderBytes)
        let hugeTerminated = Data("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nX-Pad: \(padding)\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(hugeTerminated), .error(.headersTooLarge))

        // Oversize Content-Length (> 4 MiB) rejected immediately without needing full body
        let hugeCL = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: \(LocalHTTPRequest.maxBodyBytes + 1)\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(hugeCL), .error(.bodyTooLarge))
        XCTAssertEqual(LocalHTTPRequest.ParseError.bodyTooLarge.statusCode, 413)
    }

    func testParseRejectsBadContentLengthChunkedAndMalformed() {
        let negativeCL = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: -5\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(negativeCL), .error(.invalidContentLength))

        let nonNumericCL = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: 12abc\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(nonNumericCL), .error(.invalidContentLength))

        let conflictingCL = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: 2\r\nContent-Length: 4\r\n\r\nhi".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(conflictingCL), .error(.duplicateHeader("Content-Length")))

        let chunked = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(chunked), .error(.chunkedNotSupported))
        XCTAssertEqual(LocalHTTPRequest.ParseError.chunkedNotSupported.statusCode, 411)

        let mixedTECL = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(mixedTECL), .error(.malformedHeader))

        let badVersion = Data("GET /v1/models HTTP/2.0\r\nHost: 127.0.0.1:11435\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(badVersion), .error(.unsupportedHTTPVersion))

        let dupHost = Data("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nHost: evil.com\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(dupHost), .error(.duplicateHeader("Host")))
    }

    // MARK: - Security Guard

    func testGuardHostChecks() {
        let port: UInt16 = 11435
        XCTAssertNil(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435"]), port: port))
        XCTAssertNil(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "localhost:11435"]), port: port))
        XCTAssertNil(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "LOCALHOST:11435"]), port: port))

        // Missing Host -> 403
        XCTAssertEqual(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: [:]), port: port)?.statusCode, 403)
        // DNS-rebinding host -> 403
        XCTAssertEqual(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "evil.example:11435"]), port: port)?.statusCode, 403)
        // Wrong port -> 403
        XCTAssertEqual(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11434"]), port: port)?.statusCode, 403)
        // Missing port -> 403
        XCTAssertEqual(LocalAPIGuard.check(LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "localhost"]), port: port)?.statusCode, 403)
    }

    func testGuardOriginAlwaysBlockedAndNoCORSHeaders() {
        let port: UInt16 = 11435
        for origin in ["http://localhost:3000", "https://attacker.example", "null", ""] {
            let req = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435", "Origin": origin])
            XCTAssertEqual(LocalAPIGuard.check(req, port: port)?.statusCode, 403, "Origin '\(origin)' must be rejected")
        }

        // Verify no CORS headers are ever emitted on JSON, error, or SSE responses.
        let jsonWire = String(data: LocalHTTPResponse.json(statusCode: 200, body: Data("{}".utf8)), encoding: .utf8) ?? ""
        let errWire = String(data: LocalHTTPResponse.error(.forbidden("nope")), encoding: .utf8) ?? ""
        let sseWire = String(data: LocalHTTPResponse.sseHeaders(), encoding: .utf8) ?? ""
        for wire in [jsonWire, errWire, sseWire] {
            XCTAssertFalse(wire.lowercased().contains("access-control-allow"), "CORS headers must never be emitted")
        }
    }

    func testGuardContentTypeForPost() {
        let port: UInt16 = 11435
        let ok1 = LocalHTTPRequest(method: "POST", path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:11435", "Content-Type": "application/json"])
        let ok2 = LocalHTTPRequest(method: "POST", path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:11435", "Content-Type": "Application/JSON; charset=utf-8"])
        XCTAssertNil(LocalAPIGuard.check(ok1, port: port))
        XCTAssertNil(LocalAPIGuard.check(ok2, port: port))

        let missing = LocalHTTPRequest(method: "POST", path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:11435"])
        let plain = LocalHTTPRequest(method: "POST", path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:11435", "Content-Type": "text/plain"])
        let tricky = LocalHTTPRequest(method: "POST", path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:11435", "Content-Type": "application/jsonx"])
        XCTAssertEqual(LocalAPIGuard.check(missing, port: port)?.statusCode, 415)
        XCTAssertEqual(LocalAPIGuard.check(plain, port: port)?.statusCode, 415)
        XCTAssertEqual(LocalAPIGuard.check(tricky, port: port)?.statusCode, 415)
    }

    func testGuardBearerKeyOptionalAndConstantTime() {
        let port: UInt16 = 11435
        let noAuth = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435"])
        let dummyAuth = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435", "Authorization": "Bearer quenderin"])

        // When no key configured, any or no Authorization is accepted.
        XCTAssertNil(LocalAPIGuard.check(noAuth, port: port, requiredAPIKey: nil))
        XCTAssertNil(LocalAPIGuard.check(noAuth, port: port, requiredAPIKey: ""))
        XCTAssertNil(LocalAPIGuard.check(dummyAuth, port: port, requiredAPIKey: ""))

        // When key is configured, require exact Bearer match.
        let secret = "sk-local-secret-42"
        XCTAssertEqual(LocalAPIGuard.check(noAuth, port: port, requiredAPIKey: secret)?.statusCode, 401)
        XCTAssertEqual(LocalAPIGuard.check(dummyAuth, port: port, requiredAPIKey: secret)?.code, "invalid_api_key")

        let basicAuth = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435", "Authorization": "Basic \(secret)"])
        XCTAssertEqual(LocalAPIGuard.check(basicAuth, port: port, requiredAPIKey: secret)?.statusCode, 401)

        let validUpper = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435", "Authorization": "Bearer \(secret)"])
        let validLower = LocalHTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:11435", "Authorization": "bearer \(secret)"])
        XCTAssertNil(LocalAPIGuard.check(validUpper, port: port, requiredAPIKey: secret))
        XCTAssertNil(LocalAPIGuard.check(validLower, port: port, requiredAPIKey: secret))

        XCTAssertTrue(LocalAPIGuard.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(LocalAPIGuard.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LocalAPIGuard.constantTimeEquals("abc", "abcd"))
        XCTAssertEqual(LocalAPIGuard.clampPort(80), 1024)
        XCTAssertEqual(LocalAPIGuard.clampPort(11435), 11435)
        XCTAssertEqual(LocalAPIGuard.clampPort(99999), 65535)
    }

    // MARK: - OpenAI Chat Request Decoding

    func testDecodeAllFieldsClampingAndBothContentForms() throws {
        let json = #"""
        {
          "model": "qwen3-4b",
          "messages": [
            {"role": "system", "content": "Be brief."},
            {"role": "user", "content": [
              {"type": "text", "text": "Part one."},
              {"type": "text", "text": "Part two."}
            ]},
            {"role": "assistant", "content": "Noted."},
            {"role": "user", "content": "Continue."}
          ],
          "stream": true,
          "max_tokens": 99999,
          "temperature": 3.5,
          "top_p": -0.2,
          "stop": ["END", "STOP"],
          "response_format": {"type": "text"},
          "think": true
        }
        """#

        let res = LocalAPICodec.decodeChatRequest(
            Data(json.utf8),
            availableModelIDs: ["qwen3-4b", "llama3-8b"],
            activeModelID: "qwen3-4b"
        )
        let req = try res.get()
        XCTAssertEqual(req.model, "qwen3-4b")
        XCTAssertEqual(req.messages.count, 4)
        XCTAssertEqual(req.messages[1].content, "Part one.\nPart two.")
        XCTAssertTrue(req.stream)
        XCTAssertEqual(req.maxTokens, 4096)
        XCTAssertEqual(req.temperature, 2.0, accuracy: 1e-9)
        XCTAssertEqual(req.topP, 0.0, accuracy: 1e-9)
        XCTAssertEqual(req.stop, ["END", "STOP"])
        XCTAssertEqual(req.responseFormat, .text)
        XCTAssertTrue(req.think)
        XCTAssertEqual(req.effectiveThinkingMode, .show)

        let split = req.splitPrompt
        XCTAssertEqual(split.system, "Be brief.")
        XCTAssertEqual(split.turns.count, 3)
    }

    func testDecodeDefaultsMaxCompletionTokensAndSingleStop() throws {
        let json = #"""
        {
          "messages": [{"role": "user", "content": "hello"}],
          "max_tokens": 100,
          "max_completion_tokens": 256,
          "stop": "###"
        }
        """#
        let req = try LocalAPICodec.decodeChatRequest(
            Data(json.utf8),
            availableModelIDs: ["llama3-8b"],
            activeModelID: "llama3-8b"
        ).get()
        XCTAssertEqual(req.model, "llama3-8b")
        XCTAssertEqual(req.maxTokens, 256)
        XCTAssertEqual(req.temperature, 0.7, accuracy: 1e-9)
        XCTAssertEqual(req.topP, 0.95, accuracy: 1e-9)
        XCTAssertEqual(req.stop, ["###"])
        XCTAssertFalse(req.stream)
        XCTAssertFalse(req.think)
        XCTAssertEqual(req.effectiveThinkingMode, .off)

        // Default max_tokens = 512 when omitted
        let minimal = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let minReq = try LocalAPICodec.decodeChatRequest(minimal, availableModelIDs: ["m1"], activeModelID: "m1").get()
        XCTAssertEqual(minReq.maxTokens, 512)
    }

    func testDecodeRejectionsModelImagesAndTools() {
        // Unknown model -> 404 model_not_found
        let badModel = Data(#"{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(badModel, availableModelIDs: ["qwen3-4b"], activeModelID: "qwen3-4b") {
            XCTAssertEqual(err.statusCode, 404)
            XCTAssertEqual(err.code, "model_not_found")
        } else {
            XCTFail("Expected 404 model_not_found")
        }

        // Image content part -> 400
        let withImage = Data(#"""
        {
          "messages": [{
            "role": "user",
            "content": [
              {"type": "text", "text": "describe this"},
              {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAA"}}
            ]
          }]
        }
        """#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(withImage, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
            XCTAssertEqual(err.message, "images are not supported by this endpoint yet")
        } else {
            XCTFail("Expected 400 image rejection")
        }

        // tools present -> 400
        let withTools = Data(#"{"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"f"}}]}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(withTools, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
            XCTAssertEqual(err.message, "tools are not supported yet")
        } else {
            XCTFail("Expected 400 tools rejection")
        }

        // tool_choice present -> 400
        let withToolChoice = Data(#"{"messages":[{"role":"user","content":"hi"}],"tool_choice":"auto"}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(withToolChoice, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
            XCTAssertEqual(err.message, "tools are not supported yet")
        } else {
            XCTFail("Expected 400 tool_choice rejection")
        }

        // No model installed -> 503
        let minimal = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(minimal, availableModelIDs: [], activeModelID: nil) {
            XCTAssertEqual(err.statusCode, 503)
        } else {
            XCTFail("Expected 503 when no model installed")
        }

        // Strict bool vs number validation
        let numericStream = Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":1}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(numericStream, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
        } else {
            XCTFail("Expected 400 for numeric stream")
        }

        let boolMaxTokens = Data(#"{"messages":[{"role":"user","content":"hi"}],"max_tokens":true}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(boolMaxTokens, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
        } else {
            XCTFail("Expected 400 for boolean max_tokens")
        }

        // Explicit JSON null for tools / tool_choice must also be rejected.
        let withNullTools = Data(#"{"messages":[{"role":"user","content":"hi"}],"tools":null}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(withNullTools, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
            XCTAssertEqual(err.message, "tools are not supported yet")
        } else {
            XCTFail("Expected 400 for tools: null")
        }

        let withNullToolChoice = Data(#"{"messages":[{"role":"user","content":"hi"}],"tool_choice":null}"#.utf8)
        if case .failure(let err) = LocalAPICodec.decodeChatRequest(withNullToolChoice, availableModelIDs: ["m1"], activeModelID: "m1") {
            XCTAssertEqual(err.statusCode, 400)
            XCTAssertEqual(err.message, "tools are not supported yet")
        } else {
            XCTFail("Expected 400 for tool_choice: null")
        }
    }

    func testDecodeJSONSchemaPreservesCanonicallyEquivalentUnicodePropertyKeys() throws {
        let schemaJSON = #"""
        {
          "type": "object",
          "properties": {
            "\u00e9": {"type": "string"},
            "e\u0301": {"type": "integer"}
          },
          "required": ["\u00e9", "e\u0301"]
        }
        """#
        let reqJSON = #"""
        {
          "messages": [{"role": "user", "content": "accented keys"}],
          "response_format": {
            "type": "json_schema",
            "json_schema": {
              "name": "unicode_keys",
              "schema": \#(schemaJSON)
            }
          }
        }
        """#
        let req = try LocalAPICodec.decodeChatRequest(Data(reqJSON.utf8), availableModelIDs: ["m1"], activeModelID: "m1").get()
        let expectedGrammar = try JSONOutputGrammar.grammar(forSchemaJSON: schemaJSON).get()
        XCTAssertEqual(req.responseFormat, .jsonSchema(grammar: expectedGrammar, fellBackToGeneric: false))
        let grammar = try XCTUnwrap(req.responseFormat.gbnfGrammar)
        let nfcBytes = Array("\u{00e9}".utf8)
        let nfdBytes = Array("e\u{0301}".utf8)
        let grammarBytes = Array(grammar.utf8)
        func containsBytes(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
            guard !needle.isEmpty, haystack.count >= needle.count else { return false }
            for i in 0...(haystack.count - needle.count) {
                if Array(haystack[i..<(i + needle.count)]) == needle { return true }
            }
            return false
        }
        XCTAssertNotEqual(nfcBytes, nfdBytes)
        XCTAssertTrue(containsBytes(nfcBytes, in: grammarBytes))
        XCTAssertTrue(containsBytes(nfdBytes, in: grammarBytes))
        XCTAssertTrue(grammar.contains("string"))
        XCTAssertTrue(grammar.contains("integer"))
    }

    func testResponseFormatJSONObjectAndJSONSchemaMapping() throws {
        // json_object -> JSONOutputGrammar.anyJSONObject
        let objReqJSON = Data(#"""
        {
          "messages": [{"role": "user", "content": "return json"}],
          "response_format": {"type": "json_object"},
          "think": true
        }
        """#.utf8)
        let objReq = try LocalAPICodec.decodeChatRequest(objReqJSON, availableModelIDs: ["m1"], activeModelID: "m1").get()
        XCTAssertEqual(objReq.responseFormat, .jsonObject)
        XCTAssertEqual(objReq.responseFormat.gbnfGrammar, JSONOutputGrammar.anyJSONObject)
        XCTAssertEqual(objReq.effectiveThinkingMode, .off)

        // Supported json_schema -> compiles through JSONOutputGrammar.grammar(forSchema:)
        let schemaReqJSON = Data(#"""
        {
          "messages": [{"role": "user", "content": "classify"}],
          "response_format": {
            "type": "json_schema",
            "json_schema": {
              "name": "sentiment",
              "schema": {
                "type": "object",
                "properties": {
                  "label": {"type": "string", "enum": ["positive", "negative"]},
                  "score": {"type": "number"}
                },
                "required": ["label", "score"]
              }
            }
          }
        }
        """#.utf8)
        let schemaReq = try LocalAPICodec.decodeChatRequest(schemaReqJSON, availableModelIDs: ["m1"], activeModelID: "m1").get()
        let expectedGrammar = try JSONOutputGrammar.grammar(forSchema: [
            "type": "object",
            "properties": [
                "label": ["type": "string", "enum": ["positive", "negative"]],
                "score": ["type": "number"],
            ],
            "required": ["label", "score"],
        ]).get()
        XCTAssertEqual(schemaReq.responseFormat, .jsonSchema(grammar: expectedGrammar, fellBackToGeneric: false))
        XCTAssertEqual(schemaReq.responseFormat.gbnfGrammar, expectedGrammar)

        // Unsupported json_schema keyword (`anyOf`) -> falls back cleanly to anyJSONObject
        let fallbackReqJSON = Data(#"""
        {
          "messages": [{"role": "user", "content": "union"}],
          "response_format": {
            "type": "json_schema",
            "json_schema": {
              "name": "union",
              "schema": {
                "anyOf": [{"type": "string"}, {"type": "number"}]
              }
            }
          }
        }
        """#.utf8)
        let fallbackReq = try LocalAPICodec.decodeChatRequest(fallbackReqJSON, availableModelIDs: ["m1"], activeModelID: "m1").get()
        XCTAssertEqual(fallbackReq.responseFormat, .jsonSchema(grammar: JSONOutputGrammar.anyJSONObject, fellBackToGeneric: true))
    }

    // MARK: - OpenAI Response & SSE Encoding

    func testEncodeModelsListAndErrors() throws {
        let modelsData = LocalAPICodec.encodeModelsList([
            LocalAPIModelInfo(id: "qwen3-4b", created: 1_700_000_001),
            LocalAPIModelInfo(id: "llama3-8b", created: 1_700_000_002),
        ])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: modelsData) as? [String: Any])
        XCTAssertEqual(obj["object"] as? String, "list")
        let list = try XCTUnwrap(obj["data"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["id"] as? String, "qwen3-4b")
        XCTAssertEqual(list[0]["object"] as? String, "model")
        XCTAssertEqual(list[0]["owned_by"] as? String, "quenderin")
        XCTAssertEqual(list[0]["created"] as? Int, 1_700_000_001)

        let errData = LocalAPICodec.encodeError(.serverBusy())
        let errObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: errData) as? [String: Any])
        let inner = try XCTUnwrap(errObj["error"] as? [String: Any])
        XCTAssertEqual(inner["type"] as? String, "server_error")
        XCTAssertEqual(inner["code"] as? String, "server_busy")
        XCTAssertFalse((inner["message"] as? String ?? "").isEmpty)
    }

    func testEncodeNonStreamChatCompletionWithAndWithoutReasoningAndUsage() throws {
        let id = LocalAPICodec.makeCompletionID()
        XCTAssertTrue(id.hasPrefix("chatcmpl-"))

        // Without thinking and without usage
        let plainData = LocalAPICodec.encodeChatCompletion(
            id: id,
            created: 1_700_000_010,
            model: "qwen3-4b",
            content: "Hello!",
            reasoningContent: "hidden chain",
            includeReasoning: false,
            finishReason: .stop,
            usage: nil
        )
        let plainObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        XCTAssertEqual(plainObj["object"] as? String, "chat.completion")
        XCTAssertNil(plainObj["usage"])
        let plainChoices = try XCTUnwrap(plainObj["choices"] as? [[String: Any]])
        let plainMsg = try XCTUnwrap(plainChoices[0]["message"] as? [String: Any])
        XCTAssertEqual(plainMsg["role"] as? String, "assistant")
        XCTAssertEqual(plainMsg["content"] as? String, "Hello!")
        XCTAssertNil(plainMsg["reasoning_content"])
        XCTAssertEqual(plainChoices[0]["finish_reason"] as? String, "stop")

        // With thinking enabled + non-empty reasoning + usage + finish_reason length
        let thinkData = LocalAPICodec.encodeChatCompletion(
            id: id,
            created: 1_700_000_011,
            model: "qwen3-4b",
            content: "42",
            reasoningContent: "6 * 7 = 42",
            includeReasoning: true,
            finishReason: .length,
            usage: LocalAPIUsage(promptTokens: 12, completionTokens: 8)
        )
        let thinkObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: thinkData) as? [String: Any])
        let thinkChoices = try XCTUnwrap(thinkObj["choices"] as? [[String: Any]])
        let thinkMsg = try XCTUnwrap(thinkChoices[0]["message"] as? [String: Any])
        XCTAssertEqual(thinkMsg["reasoning_content"] as? String, "6 * 7 = 42")
        XCTAssertEqual(thinkChoices[0]["finish_reason"] as? String, "length")
        let usage = try XCTUnwrap(thinkObj["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 12)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 8)
        XCTAssertEqual(usage["total_tokens"] as? Int, 20)
    }

    func testStrictJSONSchemaRejectsUnsupportedConstraintsAndInvalidSchemas() throws {
        func decode(_ schema: String, strict: String) -> Result<LocalAPIChatRequest, LocalAPIError> {
            let body = Data(#"""
            {"messages":[{"role":"user","content":"hello"}],"response_format":{"type":"json_schema",
            "json_schema":{"strict":\#(strict),"schema":\#(schema)}}}
            """#.utf8)
            return LocalAPICodec.decodeChatRequest(body, availableModelIDs: ["m1"], activeModelID: "m1")
        }
        for schema in [
            #"{"type":"object","anyOf":[{"type":"object"}]}"#,
            #"{"type":"array","items":{"type":"string","pattern":"^a"}}"#,
            #"{"type":"object","additionalProperties":{"type":"integer"}}"#,
        ] {
            XCTAssertThrowsError(try decode(schema, strict: "true").get()) { error in
                XCTAssertEqual((error as? LocalAPIError)?.code, "unsupported_response_format")
            }
        }
        for schema in [
            #"{"type":"object","required":"field"}"#,
            #"{"type":"object","additionalProperties":0}"#,
            #"{"type":"string","properties":[]}"#,
            #"{"type":"object","properties":[],"anyOf":[{"type":"object"}]}"#,
            #"{"type":false}"#,
            #"{"type":"object","properties":{"name":{"type":"bogus"}}}"#,
        ] {
            for strict in ["true", "false"] {
                XCTAssertThrowsError(try decode(schema, strict: strict).get()) { error in
                    XCTAssertEqual((error as? LocalAPIError)?.code, "invalid_response_schema")
                }
            }
        }
        let closed = #"{"type":"object","additionalProperties":false}"#
        XCTAssertThrowsError(try decode(closed, strict: "1").get())
        let request = try decode(closed, strict: "true").get()
        XCTAssertEqual(request.responseFormat, .jsonSchema(
            grammar: try JSONOutputGrammar.grammar(forSchemaJSON: closed, strict: true).get(),
            fellBackToGeneric: false
        ))
    }

    func testNativeTerminationMapsToLengthOrProtocolError() throws {
        XCTAssertEqual(try LocalAPIFinishReason.completion(for: .hit), .length)
        XCTAssertEqual(try LocalAPIFinishReason.completion(for: .contextExhausted), .length)
        XCTAssertEqual(try LocalAPIFinishReason.completion(for: .notHit), .stop)
        XCTAssertThrowsError(try LocalAPIFinishReason.completion(for: .decodeFailed)) { error in
            guard let apiError = error as? LocalAPIError else { return XCTFail("Expected an API error") }
            XCTAssertEqual(apiError.statusCode, 500)
            XCTAssertEqual(apiError.code, "decode_failed")
            let frame = String(decoding: LocalAPICodec.encodeStreamError(apiError), as: UTF8.self)
            XCTAssertTrue(frame.hasPrefix("data: {\"error\":"))
            XCTAssertTrue(frame.hasSuffix("\n\n"))
            XCTAssertTrue(frame.contains("decode_failed"))
            XCTAssertFalse(frame.contains("finish_reason"))
            XCTAssertFalse(frame.contains("[DONE]"))
        }
    }

    func testEncodeStreamSSEFraming() throws {
        let id = "chatcmpl-test123"
        let roleFrame = LocalAPICodec.encodeStreamChunk(id: id, created: 100, model: "qwen3-4b", role: "assistant")
        let reasonFrame = LocalAPICodec.encodeStreamChunk(id: id, created: 100, model: "qwen3-4b", reasoningContent: "step 1")
        let contentFrame = LocalAPICodec.encodeStreamChunk(id: id, created: 100, model: "qwen3-4b", content: "Hi")
        let finalFrame = LocalAPICodec.encodeStreamChunk(id: id, created: 100, model: "qwen3-4b", finishReason: .stop)

        func decodeSSE(_ data: Data) throws -> [String: Any] {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(text.hasPrefix("data: "))
            XCTAssertTrue(text.hasSuffix("\n\n"))
            let jsonSlice = String(text.dropFirst(6).dropLast(2))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(jsonSlice.utf8)) as? [String: Any])
        }

        let rObj = try decodeSSE(roleFrame)
        XCTAssertEqual(rObj["object"] as? String, "chat.completion.chunk")
        let rDelta = try XCTUnwrap(((rObj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any])
        XCTAssertEqual(rDelta["role"] as? String, "assistant")
        XCTAssertTrue((((rObj["choices"] as? [[String: Any]])?.first)?["finish_reason"]) is NSNull)

        let tObj = try decodeSSE(reasonFrame)
        let tDelta = try XCTUnwrap(((tObj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any])
        XCTAssertEqual(tDelta["reasoning_content"] as? String, "step 1")

        let cObj = try decodeSSE(contentFrame)
        let cDelta = try XCTUnwrap(((cObj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any])
        XCTAssertEqual(cDelta["content"] as? String, "Hi")

        let fObj = try decodeSSE(finalFrame)
        let fChoice = try XCTUnwrap((fObj["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(fChoice["finish_reason"] as? String, "stop")

        XCTAssertEqual(String(data: LocalAPICodec.streamDoneFrame, encoding: .utf8), "data: [DONE]\n\n")
    }

    func testWideJSONObjectParsesLinearlyAndPreservesUnicodeKeyIdentity() throws {
        // 4,000 distinct keys in one object — O(N^2) scanning would stall; byte-keyed index stays fast
        // while keeping canonically equivalent Unicode keys ("\u00e9" vs "e\u0301") distinct.
        var parts: [String] = []
        parts.reserveCapacity(4010)
        parts.append("\"model\":\"qwen3-4b\"")
        parts.append("\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]")
        parts.append("\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"wide\",\"schema\":{\"type\":\"object\",\"properties\":{\"\\u00e9\":{\"type\":\"string\"},\"e\\u0301\":{\"type\":\"integer\"}},\"required\":[\"\\u00e9\",\"e\\u0301\"]}}}")
        for i in 0..<4000 {
            parts.append("\"k\(i)\":\(i)")
        }
        // Duplicate key overwrites previous value without error.
        parts.append("\"temperature\":0.2")
        parts.append("\"temperature\":0.9")
        let json = "{" + parts.joined(separator: ",") + "}"

        let start = Date()
        let decoded = try LocalAPICodec.decodeChatRequest(
            Data(json.utf8),
            availableModelIDs: ["qwen3-4b"],
            activeModelID: "qwen3-4b"
        ).get()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "Wide JSON object parsing should stay linear, not quadratic")
        XCTAssertEqual(decoded.temperature, 0.9, accuracy: 0.0001)
        guard case .jsonSchema(let gbnf, let fellBack) = decoded.responseFormat else {
            return XCTFail("Expected jsonSchema response format")
        }
        XCTAssertFalse(fellBack)
        let nfcBytes = Array("\u{00e9}".utf8)
        let nfdBytes = Array("e\u{0301}".utf8)
        let grammarBytes = Array(gbnf.utf8)
        func containsBytes(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
            guard !needle.isEmpty, haystack.count >= needle.count else { return false }
            for i in 0...(haystack.count - needle.count) {
                if Array(haystack[i..<(i + needle.count)]) == needle { return true }
            }
            return false
        }
        XCTAssertTrue(containsBytes(nfcBytes, in: grammarBytes))
        XCTAssertTrue(containsBytes(nfdBytes, in: grammarBytes))
    }

    func testLocalSSEStreamBufferCoalescesAndFinishesWithoutBlockingProducer() async {
        let buffer = LocalSSEStreamBuffer(maxBufferedBytes: 64 * 1024)
        // Producer enqueues many pieces and finishes BEFORE the slow reader calls nextBatch().
        for i in 0..<20 {
            XCTAssertTrue(buffer.append(Data("chunk-\(i)\n".utf8)))
        }
        buffer.finish(finalData: Data("DONE\n".utf8))

        let batch = await buffer.nextBatch()
        XCTAssertFalse(batch.isAborted)
        XCTAssertTrue(batch.isFinished)
        let combined = String(data: batch.data, encoding: .utf8) ?? ""
        XCTAssertTrue(combined.hasPrefix("chunk-0\n"))
        XCTAssertTrue(combined.hasSuffix("chunk-19\nDONE\n"))

        // Subsequent reads return empty finished batch.
        let after = await buffer.nextBatch()
        XCTAssertTrue(after.isFinished)
        XCTAssertTrue(after.data.isEmpty)
        XCTAssertFalse(buffer.append(Data("late".utf8)))
    }

    func testLocalSSEStreamBufferAbortAndByteCap() async {
        let abortBuf = LocalSSEStreamBuffer(maxBufferedBytes: 4096)
        let reader = Task { await abortBuf.nextBatch() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        abortBuf.abort()
        let aborted = await reader.value
        XCTAssertTrue(aborted.isAborted)
        XCTAssertTrue(aborted.isFinished)
        XCTAssertTrue(abortBuf.isAborted)
        XCTAssertFalse(abortBuf.append(Data("after-abort".utf8)))

        let cappedBuf = LocalSSEStreamBuffer(maxBufferedBytes: 1024)
        XCTAssertTrue(cappedBuf.append(Data(repeating: 0x41, count: 600)))
        XCTAssertFalse(cappedBuf.append(Data(repeating: 0x42, count: 600)))
        XCTAssertTrue(cappedBuf.isAborted)
        let overflowBatch = await cappedBuf.nextBatch()
        XCTAssertTrue(overflowBatch.isAborted)
    }

    func testLocalSSEStreamBufferOrderedProbeNeverPrecedesHeaders() async {
        let buf = LocalSSEStreamBuffer(maxBufferedBytes: 4096)

        // 1) A probe before HTTP headers are enqueued is rejected so `:\n\n` can never lead the wire.
        XCTAssertFalse(buf.enqueueProbe())

        // 2) Enqueue HTTP headers + initial SSE chunk; a probe while headers are still queued in
        //    `pending` is a no-op because the queued headers themselves are already due to write.
        let headers = LocalHTTPResponse.sseHeaders()
        XCTAssertTrue(buf.append(headers))
        XCTAssertFalse(buf.enqueueProbe())

        // First dequeued batch MUST begin with HTTP/1.1 headers, never with `:\n\n`.
        let firstBatch = await buf.nextBatch()
        XCTAssertFalse(firstBatch.isAborted)
        XCTAssertFalse(firstBatch.isFinished)
        let firstText = String(data: firstBatch.data, encoding: .utf8) ?? ""
        XCTAssertTrue(firstText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertFalse(firstText.contains(":\n\n"))

        // 3) While the writer is busy sending the first batch (no waiter yet, `pending` empty),
        //    a peer-FIN probe queues `:\n\n` strictly AFTER headers.
        XCTAssertTrue(buf.enqueueProbe())
        // A second redundant probe while `:\n\n` is already pending does not pile up.
        XCTAssertFalse(buf.enqueueProbe())
        let queuedProbeBatch = await buf.nextBatch()
        XCTAssertEqual(String(data: queuedProbeBatch.data, encoding: .utf8), ":\n\n")
        XCTAssertFalse(queuedProbeBatch.isFinished)
        XCTAssertFalse(queuedProbeBatch.isAborted)

        // 4) When the writer is parked idle awaiting the next token, `enqueueProbe()` wakes it
        //    immediately with `:\n\n`, and subsequent frames + finish still deliver in order.
        let waitingReader = Task { await buf.nextBatch() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(buf.enqueueProbe())
        let wokenProbe = await waitingReader.value
        XCTAssertEqual(String(data: wokenProbe.data, encoding: .utf8), ":\n\n")
        XCTAssertFalse(wokenProbe.isFinished)
        XCTAssertFalse(wokenProbe.isAborted)

        buf.finish(finalData: LocalAPICodec.streamDoneFrame)
        XCTAssertFalse(buf.enqueueProbe())
        let finalBatch = await buf.nextBatch()
        XCTAssertTrue(finalBatch.isFinished)
        XCTAssertFalse(finalBatch.isAborted)
        XCTAssertEqual(finalBatch.data, LocalAPICodec.streamDoneFrame)
    }
}
