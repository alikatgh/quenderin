import XCTest
@testable import QuenderinKit

final class JSONOutputGrammarTests: XCTestCase {
    /// Shared cross-platform SHA-256 pin — must equal CoreVerify's `ANY_JSON_OBJECT_SHA256`.
    static let expectedAnyJSONObjectSHA256 = "a69e04400de6b8bb61a14d093bddfd43e3efb1940c5e6d8603afbedfd887047c"

    func testAnyJSONObjectHashMatchesCrossPlatformPin() {
        let hex = Self.sha256Hex(Array(JSONOutputGrammar.anyJSONObject.utf8))
        XCTAssertEqual(
            hex,
            Self.expectedAnyJSONObjectSHA256,
            "anyJSONObject grammar drifted — update BOTH twins and BOTH pins together"
        )
        XCTAssertTrue(JSONOutputGrammar.anyJSONObject.hasPrefix("root ::= object\n"))
        for rule in ["value ::=", "object ::=", "array ::=", "string ::=", "number ::=", "boolean ::=", "null ::=", "ws ::="] {
            XCTAssertTrue(JSONOutputGrammar.anyJSONObject.contains(rule), "missing rule: \(rule)")
        }
    }

    func testThreePropertySchemaPinnedExactGrammarAndDeclaredOrder() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                ("title", ["type": "string"]),
                ("count", ["type": "integer"]),
                ("verified", ["type": "boolean"]),
            ] as [(String, Any)],
            "required": ["title", "count"],
            "additionalProperties": false,
        ]
        let expected = [
            #"root ::= "{" ws "\"title\"" ws ":" ws string "," ws "\"count\"" ws ":" ws integer ( "," ws "\"verified\"" ws ":" ws boolean )? "}" ws"#,
            #"string ::= "\"" char* "\"" ws"#,
            #"char ::= [^"\\\x00-\x1F] | "\\" escape"#,
            #"escape ::= ["\\/bfnrt] | "u" hex hex hex hex"#,
            #"hex ::= [0-9a-fA-F]"#,
            #"integer ::= "-"? int ws"#,
            #"int ::= "0" | [1-9] [0-9]*"#,
            #"boolean ::= ("true" | "false") ws"#,
            #"ws ::= ([ \t\n\r] ([ \t\n\r] ([ \t\n\r] [ \t\n\r]?)?)?)?"#,
        ].joined(separator: "\n")

        let g1 = try JSONOutputGrammar.grammar(forSchema: schema).get()
        XCTAssertEqual(g1, expected)

        let jsonSchema = """
        {
          "type": "object",
          "properties": {
            "title": { "type": "string" },
            "count": { "type": "integer" },
            "verified": { "type": "boolean" }
          },
          "required": ["title", "count"],
          "additionalProperties": false
        }
        """
        let g2 = try JSONOutputGrammar.grammar(forSchemaJSON: jsonSchema).get()
        XCTAssertEqual(g2, expected)
    }

    func testEnumArrayAndNestedObjectSchema() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                ("status", ["type": "string", "enum": ["open", "closed"]]),
                ("tags", ["type": "array", "items": ["type": "string"]]),
                ("meta", [
                    "type": "object",
                    "properties": [
                        ("score", ["type": "number"]),
                        ("empty", ["type": "null"]),
                    ] as [(String, Any)],
                    "required": ["score"],
                ]),
            ] as [(String, Any)],
            "required": ["status", "tags"],
        ]
        let g = try JSONOutputGrammar.grammar(forSchema: schema).get()
        XCTAssertTrue(g.hasPrefix(#"root ::= "{" ws "\"status\"" ws ":" ws node-1 "," ws "\"tags\"" ws ":" ws node-2 ( "," ws "\"meta\"" ws ":" ws node-3 )? "}" ws"#))
        XCTAssertTrue(g.contains(#"node-1 ::= ( "\"open\"" | "\"closed\"" ) ws"#))
        XCTAssertTrue(g.contains(#"node-2 ::= "[" ws ( string ( "," ws string )* )? "]" ws"#))
        XCTAssertTrue(g.contains(#"node-3 ::= "{" ws "\"score\"" ws ":" ws number ( "," ws "\"empty\"" ws ":" ws null )? "}" ws"#))
        XCTAssertTrue(g.contains("number ::=") && g.contains("null ::="))
    }

    func testAllOptionalPropertiesProduceValidCommaChain() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                ("z", ["type": "string"]),
                ("a", ["type": "integer"]),
            ] as [(String, Any)],
        ]
        let g = try JSONOutputGrammar.grammar(forSchema: schema).get()
        XCTAssertTrue(g.hasPrefix(#"root ::= "{" ws ( "\"z\"" ws ":" ws string ( "," ws "\"a\"" ws ":" ws integer )? | "\"a\"" ws ":" ws integer )? "}" ws"#))
    }

    func testUnsupportedKeywordsReturnClearFailureForFallback() {
        let cases: [(String, [String: Any])] = [
            ("anyOf", ["type": "object", "anyOf": [["type": "string"]]]),
            ("oneOf", ["oneOf": [["type": "string"], ["type": "integer"]]]),
            ("$ref", ["type": "object", "$ref": "#/$defs/Item"]),
            ("pattern", ["type": "string", "pattern": "^[a-z]+$"]),
            ("minimum", ["type": "integer", "minimum": 0]),
        ]
        for (keyword, schema) in cases {
            let result = JSONOutputGrammar.grammar(forSchema: schema)
            switch result {
            case .success:
                XCTFail("Expected unsupported failure for keyword \(keyword)")
            case .failure(let err):
                XCTAssertTrue(err.reason.contains(keyword), "Expected reason to mention \(keyword), got: \(err.reason)")
            }
        }
    }

    func testValidateJSONTrueAndFalseCases() {
        XCTAssertTrue(JSONOutputGrammar.validate(json: "{}"))
        XCTAssertTrue(JSONOutputGrammar.validate(json: #" { "a": 1, "b": -3.14e+2, "c": [true, false, null, "hi\n\"\\u00e9"] } "#))
        XCTAssertTrue(JSONOutputGrammar.validate(json: #"{"emoji":"\uD83D\uDE00","nested":{"ok":true}}"#))

        XCTAssertFalse(JSONOutputGrammar.validate(json: ""))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "[1, 2, 3]"))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "\"just a string\""))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "42"))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "true"))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "null"))
        XCTAssertFalse(JSONOutputGrammar.validate(json: #"{"a": 1,}"#))
        XCTAssertFalse(JSONOutputGrammar.validate(json: #"{"a": 1} extra"#))
        XCTAssertFalse(JSONOutputGrammar.validate(json: #"{"a": 01}"#))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "{unquoted: 1}"))
        XCTAssertFalse(JSONOutputGrammar.validate(json: "{\"bad\":\"\n\"}"))
    }

    // Minimal pure-Swift FIPS 180-4 SHA-256 helper so the exact same test runs on both Linux and macOS.
    private static func sha256Hex(_ message: [UInt8]) -> String {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var data = message
        let bitLen = UInt64(data.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLen >> UInt64(shift)) & 0xff))
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let b = chunkStart + i * 4
                w[i] = (UInt32(data[b]) << 24) | (UInt32(data[b + 1]) << 16) | (UInt32(data[b + 2]) << 8) | UInt32(data[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
