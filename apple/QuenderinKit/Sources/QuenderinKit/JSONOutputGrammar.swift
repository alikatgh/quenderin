import Foundation

/// GBNF grammars for structured JSON output (Ollama `format` / OpenAI `response_format`).
///
/// Built as joined lines so the Kotlin twin (`JSONOutputGrammar.kt`) holds a byte-identical
/// `anyJSONObject` constant and emits byte-identical schema grammars. Both platforms pin the
/// same SHA-256 of `anyJSONObject` in their tests.
/// Pure Foundation + deterministic → testable on Linux.
public enum JSONOutputGrammar {
    /// Failure returned when a JSON Schema uses unsupported keywords or invalid structure.
    /// Callers can fall back to `anyJSONObject` while surfacing `reason` for diagnostics.
    public enum SchemaError: Error, Equatable, Sendable {
        case unsupported(String)
        case invalid(String)

        public var reason: String {
            switch self {
            case .unsupported(let msg), .invalid(let msg):
                return msg
            }
        }
    }

    /// Explicit ordered key-value list for Swift callers that want deterministic property order
    /// without going through JSON text (since Swift `Dictionary` iteration order is randomized).
    public struct OrderedObject {
        public let entries: [(String, Any)]
        public init(_ entries: [(String, Any)]) {
            self.entries = entries
        }
    }

    /// GBNF grammar (`root ::= object`) accepting any RFC-8259 JSON object with bounded whitespace
    /// so degenerate models cannot loop forever on spaces or newlines.
    /// Byte-identical twin of Kotlin `JSONOutputGrammar.ANY_JSON_OBJECT`.
    public static let anyJSONObject: String = [
        #"root ::= object"#,
        #"value ::= object | array | string | number | boolean | null"#,
        #"object ::= "{" ws ( pair ( "," ws pair )* )? "}" ws"#,
        #"pair ::= string ":" ws value"#,
        #"array ::= "[" ws ( value ( "," ws value )* )? "]" ws"#,
        #"string ::= "\"" char* "\"" ws"#,
        #"char ::= [^"\\\x00-\x1F] | "\\" escape"#,
        #"escape ::= ["\\/bfnrt] | "u" hex hex hex hex"#,
        #"hex ::= [0-9a-fA-F]"#,
        #"number ::= "-"? int frac? exp? ws"#,
        #"int ::= "0" | [1-9] [0-9]*"#,
        #"frac ::= "." [0-9]+"#,
        #"exp ::= [eE] [+-]? [0-9]+"#,
        #"boolean ::= ("true" | "false") ws"#,
        #"null ::= "null" ws"#,
        #"ws ::= ([ \t\n\r] ([ \t\n\r] ([ \t\n\r] [ \t\n\r]?)?)?)?"#,
    ].joined(separator: "\n")

    /// Converts a JSON Schema subset into a deterministic GBNF grammar.
    ///
    /// Supported subset:
    /// - `object` (`properties`, `required` emitted first in declared order, optional properties
    ///   allowed after in declared order; strict mode enforces a closed empty object too)
    /// - `string` (with optional `enum` of strings)
    /// - `number`, `integer`, `boolean`, `null`
    /// - `array` (with optional `items` schema object)
    /// - nested objects and arrays
    ///
    /// Property order determinism (parity with Kotlin `JSONOutputGrammar.grammar(schema:)`):
    /// - Native `[String: Any]` dictionaries ALWAYS sort keys by unsigned UTF-8 bytes on BOTH Swift
    ///   and Kotlin so map/dictionary schema APIs produce byte-identical grammars across platforms.
    /// - Pass `"properties"` as `OrderedObject`, non-empty `[(String, Any)]`, or
    ///   `[(String, [String: Any])]`, OR use `grammar(forSchemaJSON:)`, to preserve exact declared
    ///   property order.
    public static func grammar(forSchema schema: Any, strict: Bool = false) -> Result<String, SchemaError> {
        switch toNode(schema) {
        case .failure(let err):
            return .failure(err)
        case .success(let node):
            return compileRoot(node, strict: strict)
        }
    }

    /// Parses a JSON Schema string preserving exact declared property order and compiles it to GBNF.
    /// Byte-identical to Kotlin `JSONOutputGrammar.grammarFromJson(json)`.
    public static func grammar(forSchemaJSON json: String, strict: Bool = false) -> Result<String, SchemaError> {
        var parser = MiniJSONParser(json, allowLoneSurrogates: false)
        guard let value = parser.parseDocument(), case .object = value else {
            return .failure(.invalid("Schema JSON must be a valid JSON object"))
        }
        return compileRoot(value, strict: strict)
    }

    /// Minimal RFC-8259 validator: returns `true` iff `json` parses cleanly as a top-level JSON object
    /// with no trailing non-whitespace characters (including syntactically valid lone `\uD800`–`\uDFFF`
    /// escapes per RFC 8259). Twin of Kotlin `JSONOutputGrammar.validate(json)`.
    public static func validate(json: String) -> Bool {
        var parser = MiniJSONParser(json, allowLoneSurrogates: true)
        guard let value = parser.parseDocument() else { return false }
        if case .object = value {
            return true
        }
        return false
    }

    // MARK: - Internal ordered JSON AST

    fileprivate enum JSONValue {
        case object([(String, JSONValue)])
        case array([JSONValue])
        case string(String)
        case number
        case bool(Bool)
        case null
    }

    private static func toNode(_ any: Any) -> Result<JSONValue, SchemaError> {
        if let ordered = any as? OrderedObject {
            var out: [(String, JSONValue)] = []
            out.reserveCapacity(ordered.entries.count)
            for (k, v) in ordered.entries {
                switch toNode(v) {
                case .failure(let e): return .failure(e)
                case .success(let node): out.append((k, node))
                }
            }
            return .success(.object(out))
        }
        // Guard `!pairs.isEmpty`: in Swift an empty array (e.g. `[String]()`) bridges to any `[T]`,
        // including `[(String, Any)]`. Empty arrays must fall through to `.array([])` below.
        if let pairs = any as? [(String, Any)], !pairs.isEmpty {
            var out: [(String, JSONValue)] = []
            out.reserveCapacity(pairs.count)
            for (k, v) in pairs {
                switch toNode(v) {
                case .failure(let e): return .failure(e)
                case .success(let node): out.append((k, node))
                }
            }
            return .success(.object(out))
        }
        if let pairs = any as? [(String, [String: Any])], !pairs.isEmpty {
            var out: [(String, JSONValue)] = []
            out.reserveCapacity(pairs.count)
            for (k, v) in pairs {
                switch toNode(v) {
                case .failure(let e): return .failure(e)
                case .success(let node): out.append((k, node))
                }
            }
            return .success(.object(out))
        }
        if let dict = any as? [String: Any] {
            let keys = dict.count > 1
                ? dict.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                : Array(dict.keys)
            var out: [(String, JSONValue)] = []
            out.reserveCapacity(keys.count)
            for k in keys {
                guard let v = dict[k] else { continue }
                switch toNode(v) {
                case .failure(let e): return .failure(e)
                case .success(let node): out.append((k, node))
                }
            }
            return .success(.object(out))
        }
        if let arr = any as? [Any] {
            var out: [JSONValue] = []
            out.reserveCapacity(arr.count)
            for item in arr {
                switch toNode(item) {
                case .failure(let e): return .failure(e)
                case .success(let node): out.append(node)
                }
            }
            return .success(.array(out))
        }
        if let s = any as? String {
            return .success(.string(s))
        }
        if let b = any as? Bool {
            return .success(.bool(b))
        }
        if any is Int || any is Double || any is Float || any is NSNumber {
            return .success(.number)
        }
        if any is NSNull {
            return .success(.null)
        }
        return .failure(.invalid("Unsupported value type in schema"))
    }

    // MARK: - GBNF Schema Compiler

    private static let allowedKeywords: Set<String> = [
        "type",
        "properties",
        "required",
        "items",
        "enum",
        "additionalProperties",
        "title",
        "description",
        "$schema",
    ]

    private struct Compiler {
        let strict: Bool
        var extraRules: [(name: String, body: String)] = []
        var nextNodeId: Int = 1

        var needValue = false
        var needObject = false
        var needArray = false
        var needString = false
        var needNumber = false
        var needInteger = false
        var needBoolean = false
        var needNull = false

        mutating func markValue() {
            needValue = true
            needObject = true
            needArray = true
            needString = true
            needNumber = true
            needBoolean = true
            needNull = true
        }

        mutating func allocRule(body: String) -> String {
            let name = "node-\(nextNodeId)"
            nextNodeId += 1
            extraRules.append((name, body))
            return name
        }

        mutating func compileExpr(_ value: JSONValue, isRoot: Bool) -> Result<String, SchemaError> {
            guard case .object(let entries) = value else {
                return .failure(.invalid("Schema node must be a JSON object"))
            }

            // Reject any unsupported schema keyword (anyOf, oneOf, $ref, pattern, minimum, …).
            var map: [String: JSONValue] = [:]
            for (k, v) in entries {
                if map.updateValue(v, forKey: k) != nil {
                    return .failure(.invalid("Duplicate schema keyword: \(k)"))
                }
                // Keyword value shapes apply even if the instance type makes the constraint inert.
                switch (k, v) {
                case ("title", .string), ("description", .string), ("$schema", .string),
                     ("properties", .object), ("required", .array), ("enum", .array),
                     ("items", .object), ("items", .array), ("items", .bool),
                     ("additionalProperties", .object), ("additionalProperties", .bool):
                    break
                case ("title", _), ("description", _), ("$schema", _), ("properties", _),
                     ("required", _), ("enum", _), ("items", _), ("additionalProperties", _):
                    return .failure(.invalid("Invalid value for JSON Schema keyword '\(k)'"))
                default:
                    break
                }
            }
            let unsupportedKeyword = entries.first { !JSONOutputGrammar.allowedKeywords.contains($0.0) }

            guard let typeVal = map["type"] else {
                if let unsupportedKeyword { return .failure(.unsupported("Unsupported JSON Schema keyword: \(unsupportedKeyword.0)")) }
                return .failure(.invalid("Missing required 'type' in schema"))
            }
            guard case .string(let typeName) = typeVal else {
                if case .array(let types) = typeVal, !types.isEmpty, types.allSatisfy({
                    guard case .string(let name) = $0 else { return false }
                    return JSONOutputGrammar.schemaTypes.contains(name)
                }) {
                    return .failure(.unsupported("Unsupported 'type': expected a single type string"))
                }
                return .failure(.invalid("'type' must be a valid JSON Schema type or a non-empty array of types"))
            }
            guard JSONOutputGrammar.schemaTypes.contains(typeName) else {
                return .failure(.invalid("Unknown JSON Schema type: \(typeName)"))
            }
            let compiled = compileTypedExpr(map: map, typeName: typeName, isRoot: isRoot)
            if case .failure(.invalid) = compiled { return compiled }
            if let unsupportedKeyword {
                return .failure(.unsupported("Unsupported JSON Schema keyword: \(unsupportedKeyword.0)"))
            }
            if strict, map["$schema"] != nil {
                return .failure(.unsupported("Declaring a schema dialect with '$schema' is unsupported in strict mode"))
            }
            return compiled
        }

        private mutating func compileTypedExpr(map: [String: JSONValue], typeName: String, isRoot: Bool) -> Result<String, SchemaError> {
            if map["enum"] != nil && typeName != "string" {
                return .failure(.unsupported("Unsupported 'enum' on non-string type: \(typeName)"))
            }

            switch typeName {
            case "string":
                if let enumVal = map["enum"] {
                    return compileStringEnum(enumVal, isRoot: isRoot)
                }
                needString = true
                return .success("string")

            case "number":
                needNumber = true
                return .success("number")

            case "integer":
                needInteger = true
                return .success("integer")

            case "boolean":
                needBoolean = true
                return .success("boolean")

            case "null":
                needNull = true
                return .success("null")

            case "array":
                return compileArray(map: map, isRoot: isRoot)

            case "object":
                return compileObject(map: map, isRoot: isRoot)

            default:
                return .failure(.unsupported("Unsupported JSON Schema type: \(typeName)"))
            }
        }

        private mutating func compileStringEnum(_ enumVal: JSONValue, isRoot: Bool) -> Result<String, SchemaError> {
            guard case .array(let items) = enumVal, !items.isEmpty else {
                return .failure(.invalid("'enum' must be a non-empty array of strings"))
            }
            var literals: [String] = []
            literals.reserveCapacity(items.count)
            for item in items {
                guard case .string(let s) = item else {
                    return .failure(.unsupported("Unsupported non-string value in 'enum'"))
                }
                literals.append(JSONOutputGrammar.gbnfQuotedJSONString(s))
            }
            let body: String
            if literals.count == 1 {
                body = "\(literals[0]) ws"
            } else {
                body = "( \(literals.joined(separator: " | ")) ) ws"
            }
            return .success(isRoot ? body : allocRule(body: body))
        }

        private mutating func compileArray(map: [String: JSONValue], isRoot: Bool) -> Result<String, SchemaError> {
            guard let itemsVal = map["items"] else {
                markValue()
                return .success("array")
            }
            if case .bool = itemsVal {
                return .failure(.unsupported("Unsupported 'items' schema: expected object"))
            }
            if case .array = itemsVal {
                return .failure(.unsupported("Unsupported tuple validation in 'items'"))
            }
            switch compileExpr(itemsVal, isRoot: false) {
            case .failure(let e):
                return .failure(e)
            case .success(let itemRef):
                let body = #""[" ws ( \#(itemRef) ( "," ws \#(itemRef) )* )? "]" ws"#
                return .success(isRoot ? body : allocRule(body: body))
            }
        }

        private mutating func compileObject(map: [String: JSONValue], isRoot: Bool) -> Result<String, SchemaError> {
            var closed = false
            if let additional = map["additionalProperties"] {
                switch additional {
                case .bool(let allowed): closed = !allowed
                case .object:
                    return .failure(.unsupported("Schema-valued 'additionalProperties' is unsupported"))
                default:
                    return .failure(.invalid("'additionalProperties' must be a boolean or schema object"))
                }
            }
            guard case .object(let propEntries) = map["properties"] ?? .object([]) else {
                return .failure(.invalid("'properties' must be an object"))
            }

            var requiredByUTF8: Set<[UInt8]> = []
            var requiredEntries: [([UInt8], String)] = []
            if let reqVal = map["required"] {
                guard case .array(let reqItems) = reqVal else {
                    return .failure(.invalid("'required' must be an array of property names"))
                }
                for item in reqItems {
                    guard case .string(let name) = item else {
                        return .failure(.invalid("'required' entries must be strings"))
                    }
                    let keyBytes = Array(name.utf8)
                    if requiredByUTF8.insert(keyBytes).inserted {
                        requiredEntries.append((keyBytes, name))
                    }
                }
            }

            let declaredUTF8 = Set(propEntries.map { Array($0.0.utf8) })
            guard declaredUTF8.count == propEntries.count else {
                return .failure(.invalid("Duplicate property name in schema"))
            }
            let sortedRequired = requiredEntries.sorted { $0.0.lexicographicallyPrecedes($1.0) }
            for (reqBytes, reqName) in sortedRequired where !declaredUTF8.contains(reqBytes) {
                return .failure(.invalid("Required property '\(reqName)' not found in properties"))
            }
            if map["properties"] == nil && !(strict && closed) {
                markValue()
                return .success("object")
            }

            let optionalCount = propEntries.reduce(0) { count, entry in
                count + (requiredByUTF8.contains(Array(entry.0.utf8)) ? 0 : 1)
            }
            if optionalCount > JSONOutputGrammar.maxOptionalProperties {
                return .failure(.unsupported("too many optional properties"))
            }

            // Emit required props in declared order, then optional props in declared order.
            var reqKV: [String] = []
            var optKV: [String] = []
            for (propName, propSchema) in propEntries {
                switch compileExpr(propSchema, isRoot: false) {
                case .failure(let e):
                    return .failure(e)
                case .success(let propRef):
                    let keyLit = JSONOutputGrammar.gbnfQuotedJSONString(propName)
                    let kv = "\(keyLit) ws \":\" ws \(propRef)"
                    if requiredByUTF8.contains(Array(propName.utf8)) {
                        reqKV.append(kv)
                    } else {
                        optKV.append(kv)
                    }
                }
            }

            let body: String
            if reqKV.isEmpty && optKV.isEmpty {
                body = #""{" ws "}" ws"#
            } else if !reqKV.isEmpty {
                var parts: [String] = [#"{"#.gbnfLit, "ws", reqKV[0]]
                for kv in reqKV.dropFirst() {
                    parts.append(#""," ws \#(kv)"#)
                }
                for kv in optKV {
                    parts.append(#"( "," ws \#(kv) )?"#)
                }
                parts.append(#""}" ws"#)
                body = parts.joined(separator: " ")
            } else {
                // All properties are optional: build right-nested valid comma chain.
                var branches: [String] = []
                for i in 0..<optKV.count {
                    var branchParts = [optKV[i]]
                    for j in (i + 1)..<optKV.count {
                        branchParts.append(#"( "," ws \#(optKV[j]) )?"#)
                    }
                    branches.append(branchParts.joined(separator: " "))
                }
                body = #""{" ws ( \#(branches.joined(separator: " | ")) )? "}" ws"#
            }

            return .success(isRoot ? body : allocRule(body: body))
        }

        func finish(rootBody: String) -> String {
            var lines: [String] = ["root ::= \(rootBody)"]
            for rule in extraRules {
                lines.append("\(rule.name) ::= \(rule.body)")
            }
            if needValue {
                lines.append(#"value ::= object | array | string | number | boolean | null"#)
            }
            if needObject {
                lines.append(#"object ::= "{" ws ( pair ( "," ws pair )* )? "}" ws"#)
                lines.append(#"pair ::= string ":" ws value"#)
            }
            if needArray {
                lines.append(#"array ::= "[" ws ( value ( "," ws value )* )? "]" ws"#)
            }
            if needString {
                lines.append(#"string ::= "\"" char* "\"" ws"#)
                lines.append(#"char ::= [^"\\\x00-\x1F] | "\\" escape"#)
                lines.append(#"escape ::= ["\\/bfnrt] | "u" hex hex hex hex"#)
                lines.append(#"hex ::= [0-9a-fA-F]"#)
            }
            if needNumber {
                lines.append(#"number ::= "-"? int frac? exp? ws"#)
            }
            if needInteger {
                lines.append(#"integer ::= "-"? int ws"#)
            }
            if needNumber || needInteger {
                lines.append(#"int ::= "0" | [1-9] [0-9]*"#)
            }
            if needNumber {
                lines.append(#"frac ::= "." [0-9]+"#)
                lines.append(#"exp ::= [eE] [+-]? [0-9]+"#)
            }
            if needBoolean {
                lines.append(#"boolean ::= ("true" | "false") ws"#)
            }
            if needNull {
                lines.append(#"null ::= "null" ws"#)
            }
            lines.append(#"ws ::= ([ \t\n\r] ([ \t\n\r] ([ \t\n\r] [ \t\n\r]?)?)?)?"#)
            return lines.joined(separator: "\n")
        }
    }

    private static let schemaTypes: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]

    private static func compileRoot(_ node: JSONValue, strict: Bool) -> Result<String, SchemaError> {
        var compiler = Compiler(strict: strict)
        switch compiler.compileExpr(node, isRoot: true) {
        case .failure(let err):
            return .failure(err)
        case .success(let rootBody):
            return .success(compiler.finish(rootBody: rootBody))
        }
    }

    private static let maxOptionalProperties = 16

    /// Encodes a string as a GBNF double-quoted literal matching that JSON-encoded string.
    /// Iterates `unicodeScalars` (never `Character`) so a quote or backslash followed by a
    /// combining mark such as U+0301 is still escaped identically to Kotlin.
    private static func gbnfQuotedJSONString(_ value: String) -> String {
        var jsonEscaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: jsonEscaped += "\\\""
            case 0x5C: jsonEscaped += "\\\\"
            case 0x08: jsonEscaped += "\\b"
            case 0x0C: jsonEscaped += "\\f"
            case 0x0A: jsonEscaped += "\\n"
            case 0x0D: jsonEscaped += "\\r"
            case 0x09: jsonEscaped += "\\t"
            case 0x00..<0x20:
                jsonEscaped += String(format: "\\u%04x", scalar.value)
            default:
                jsonEscaped.unicodeScalars.append(scalar)
            }
        }
        let jsonLiteral = "\"\(jsonEscaped)\""
        var gbnfEscaped = ""
        for scalar in jsonLiteral.unicodeScalars {
            if scalar.value == 0x5C {
                gbnfEscaped += "\\\\"
            } else if scalar.value == 0x22 {
                gbnfEscaped += "\\\""
            } else {
                gbnfEscaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(gbnfEscaped)\""
    }

    // MARK: - Minimal RFC-8259 recursive-descent JSON parser (zero external deps, order-preserving)

    private struct MiniJSONParser {
        private let bytes: [UInt8]
        private let allowLoneSurrogates: Bool
        private var pos: Int = 0
        private static let maxDepth = 128

        init(_ s: String, allowLoneSurrogates: Bool = false) {
            self.bytes = Array(s.utf8)
            self.allowLoneSurrogates = allowLoneSurrogates
        }

        mutating func parseDocument() -> JSONValue? {
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

        private mutating func parseValue(depth: Int) -> JSONValue? {
            guard depth <= Self.maxDepth, pos < bytes.count else { return nil }
            switch bytes[pos] {
            case 0x7B: return parseObject(depth: depth + 1) // '{'
            case 0x5B: return parseArray(depth: depth + 1)  // '['
            case 0x22:
                guard let s = parseString() else { return nil }
                return .string(s)
            case 0x74: return parseLiteral("true") ? .bool(true) : nil
            case 0x66: return parseLiteral("false") ? .bool(false) : nil
            case 0x6E: return parseLiteral("null") ? .null : nil
            case 0x2D, 0x30...0x39: return parseNumber() ? .number : nil
            default: return nil
            }
        }

        private mutating func parseObject(depth: Int) -> JSONValue? {
            pos += 1 // '{'
            skipWS()
            var entries: [(String, JSONValue)] = []
            if pos < bytes.count && bytes[pos] == 0x7D { // '}'
                pos += 1
                return .object(entries)
            }
            while true {
                guard pos < bytes.count && bytes[pos] == 0x22,
                      let key = parseString() else { return nil }
                skipWS()
                guard pos < bytes.count && bytes[pos] == 0x3A else { return nil } // ':'
                pos += 1
                skipWS()
                guard let val = parseValue(depth: depth) else { return nil }
                entries.append((key, val))
                skipWS()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == 0x7D { // '}'
                    pos += 1
                    return .object(entries)
                }
                guard bytes[pos] == 0x2C else { return nil } // ','
                pos += 1
                skipWS()
            }
        }

        private mutating func parseArray(depth: Int) -> JSONValue? {
            pos += 1 // '['
            skipWS()
            var items: [JSONValue] = []
            if pos < bytes.count && bytes[pos] == 0x5D { // ']'
                pos += 1
                return .array(items)
            }
            while true {
                guard let val = parseValue(depth: depth) else { return nil }
                items.append(val)
                skipWS()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == 0x5D { // ']'
                    pos += 1
                    return .array(items)
                }
                guard bytes[pos] == 0x2C else { return nil } // ','
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
                if b == 0x22 { // '"'
                    pos += 1
                    return String(bytes: out, encoding: .utf8)
                }
                if b < 0x20 {
                    return nil // unescaped control char
                }
                if b == 0x5C { // '\'
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
                            let savedPos = pos
                            if pos + 1 < bytes.count,
                               bytes[pos] == 0x5C,
                               bytes[pos + 1] == 0x75 {
                                pos += 2
                                if let u2 = parseHex4(), (0xDC00...0xDFFF).contains(u2) {
                                    scalarValue = 0x10000 + ((u1 - 0xD800) << 10) + (u2 - 0xDC00)
                                } else if allowLoneSurrogates {
                                    pos = savedPos
                                    scalarValue = 0xFFFD
                                } else {
                                    return nil
                                }
                            } else if allowLoneSurrogates {
                                scalarValue = 0xFFFD
                            } else {
                                return nil
                            }
                        } else if (0xDC00...0xDFFF).contains(u1) {
                            if allowLoneSurrogates {
                                scalarValue = 0xFFFD
                            } else {
                                return nil
                            }
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

        private mutating func parseNumber() -> Bool {
            if pos < bytes.count && bytes[pos] == 0x2D { pos += 1 } // '-'
            guard pos < bytes.count else { return false }
            if bytes[pos] == 0x30 { // '0'
                pos += 1
            } else if (0x31...0x39).contains(bytes[pos]) {
                pos += 1
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            } else {
                return false
            }
            if pos < bytes.count && bytes[pos] == 0x2E { // '.'
                pos += 1
                guard pos < bytes.count && (0x30...0x39).contains(bytes[pos]) else { return false }
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            }
            if pos < bytes.count && (bytes[pos] == 0x65 || bytes[pos] == 0x45) { // 'e' | 'E'
                pos += 1
                if pos < bytes.count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) { pos += 1 }
                guard pos < bytes.count && (0x30...0x39).contains(bytes[pos]) else { return false }
                while pos < bytes.count && (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            }
            return true
        }
    }
}

private extension String {
    var gbnfLit: String { "\"\(self)\"" }
}
