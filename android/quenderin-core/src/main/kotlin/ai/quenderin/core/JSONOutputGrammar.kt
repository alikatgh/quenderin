package ai.quenderin.core

/**
 * GBNF grammars for structured JSON output (Ollama `format` / OpenAI `response_format`).
 *
 * Byte-identical twin of Swift `JSONOutputGrammar.swift` — both platforms pin the same SHA-256
 * of [ANY_JSON_OBJECT] in their checks and produce identical GBNF for any supported JSON Schema.
 * Zero external dependencies (hand-rolled RFC-8259 recursive-descent JSON parser/validator).
 */
object JSONOutputGrammar {
    sealed class GrammarResult {
        data class Success(val gbnf: String) : GrammarResult()
        data class Failure(val reason: String) : GrammarResult()

        val gbnfOrNull: String?
            get() = (this as? Success)?.gbnf
    }

    /**
     * GBNF grammar (`root ::= object`) accepting any RFC-8259 JSON object with bounded whitespace
     * so degenerate models cannot loop forever on spaces or newlines.
     * Byte-identical twin of Swift `JSONOutputGrammar.anyJSONObject`.
     */
    val ANY_JSON_OBJECT: String = listOf(
        "root ::= object",
        "value ::= object | array | string | number | boolean | null",
        "object ::= \"{\" ws ( pair ( \",\" ws pair )* )? \"}\" ws",
        "pair ::= string \":\" ws value",
        "array ::= \"[\" ws ( value ( \",\" ws value )* )? \"]\" ws",
        "string ::= \"\\\"\" char* \"\\\"\" ws",
        "char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" escape",
        "escape ::= [\"\\\\/bfnrt] | \"u\" hex hex hex hex",
        "hex ::= [0-9a-fA-F]",
        "number ::= \"-\"? int frac? exp? ws",
        "int ::= \"0\" | [1-9] [0-9]*",
        "frac ::= \".\" [0-9]+",
        "exp ::= [eE] [+-]? [0-9]+",
        "boolean ::= (\"true\" | \"false\") ws",
        "null ::= \"null\" ws",
        "ws ::= ([ \\t\\n\\r] ([ \\t\\n\\r] ([ \\t\\n\\r] [ \\t\\n\\r]?)?)?)?",
    ).joinToString("\n")

    /**
     * Converts a JSON Schema subset into a deterministic GBNF grammar.
     * Preserves exact declared property order from Kotlin `LinkedHashMap` (`mapOf` / `linkedMapOf`)
     * or `List<Pair<String, Any?>>`. Never sorts properties implicitly.
     */
    fun grammar(schema: Map<String, Any?>): GrammarResult {
        val node = toNode(schema) ?: return GrammarResult.Failure("Unsupported value type in schema")
        return compileRoot(node)
    }

    /**
     * Parses a JSON Schema string preserving exact declared property order and compiles it to GBNF.
     * Byte-identical to Swift `JSONOutputGrammar.grammar(forSchemaJSON:)`.
     */
    fun grammarFromJson(json: String): GrammarResult {
        val value = MiniJsonParser(json).parseDocument()
            ?: return GrammarResult.Failure("Schema JSON must be a valid JSON object")
        if (value !is JsonValue.Obj) {
            return GrammarResult.Failure("Schema JSON must be a valid JSON object")
        }
        return compileRoot(value)
    }

    /**
     * Minimal RFC-8259 validator: returns `true` iff [json] parses cleanly as a top-level JSON object
     * with no trailing non-whitespace characters. Twin of Swift `JSONOutputGrammar.validate(json:)`.
     */
    fun validate(json: String): Boolean {
        val value = MiniJsonParser(json).parseDocument() ?: return false
        return value is JsonValue.Obj
    }

    // --- Internal ordered JSON AST ---

    private sealed class JsonValue {
        data class Obj(val entries: List<Pair<String, JsonValue>>) : JsonValue()
        data class Arr(val items: List<JsonValue>) : JsonValue()
        data class Str(val value: String) : JsonValue()
        data object Num : JsonValue()
        data class Bool(val value: Boolean) : JsonValue()
        data object Null : JsonValue()
    }

    private fun toNode(any: Any?): JsonValue? = when (any) {
        null -> JsonValue.Null
        is String -> JsonValue.Str(any)
        is Boolean -> JsonValue.Bool(any)
        is Number -> JsonValue.Num
        is Map<*, *> -> {
            val entries = ArrayList<Pair<String, JsonValue>>(any.size)
            for ((k, v) in any) {
                val key = k as? String ?: return null
                val node = toNode(v) ?: return null
                entries.add(key to node)
            }
            JsonValue.Obj(entries)
        }
        is List<*> -> {
            // Also accept List<Pair<String, Any?>> for explicit ordered property lists.
            if (any.isNotEmpty() && any.all { it is Pair<*, *> && it.first is String }) {
                val entries = ArrayList<Pair<String, JsonValue>>(any.size)
                for (item in any) {
                    val p = item as Pair<*, *>
                    val key = p.first as String
                    val node = toNode(p.second) ?: return null
                    entries.add(key to node)
                }
                JsonValue.Obj(entries)
            } else {
                val items = ArrayList<JsonValue>(any.size)
                for (item in any) {
                    val node = toNode(item) ?: return null
                    items.add(node)
                }
                JsonValue.Arr(items)
            }
        }
        else -> null
    }

    // --- GBNF Schema Compiler ---

    private val allowedKeywords: Set<String> = setOf(
        "type",
        "properties",
        "required",
        "items",
        "enum",
        "additionalProperties",
        "title",
        "description",
        "\$schema",
    )

    private class Compiler {
        val extraRules = mutableListOf<Pair<String, String>>()
        var nextNodeId = 1

        var needValue = false
        var needObject = false
        var needArray = false
        var needString = false
        var needNumber = false
        var needInteger = false
        var needBoolean = false
        var needNull = false

        fun markValue() {
            needValue = true
            needObject = true
            needArray = true
            needString = true
            needNumber = true
            needBoolean = true
            needNull = true
        }

        fun allocRule(body: String): String {
            val name = "node-$nextNodeId"
            nextNodeId++
            extraRules.add(name to body)
            return name
        }

        fun compileExpr(value: JsonValue, isRoot: Boolean): GrammarResult {
            if (value !is JsonValue.Obj) {
                return GrammarResult.Failure("Schema node must be a JSON object")
            }

            val map = LinkedHashMap<String, JsonValue>()
            for ((k, v) in value.entries) {
                if (k !in allowedKeywords) {
                    return GrammarResult.Failure("Unsupported JSON Schema keyword: $k")
                }
                map[k] = v
            }

            val typeVal = map["type"]
                ?: return GrammarResult.Failure("Missing required 'type' in schema")
            if (typeVal !is JsonValue.Str) {
                return GrammarResult.Failure("Unsupported 'type': expected a single type string")
            }
            val typeName = typeVal.value

            if (map.containsKey("enum") && typeName != "string") {
                return GrammarResult.Failure("Unsupported 'enum' on non-string type: $typeName")
            }

            return when (typeName) {
                "string" -> {
                    val enumVal = map["enum"]
                    if (enumVal != null) {
                        compileStringEnum(enumVal, isRoot)
                    } else {
                        needString = true
                        GrammarResult.Success("string")
                    }
                }
                "number" -> {
                    needNumber = true
                    GrammarResult.Success("number")
                }
                "integer" -> {
                    needInteger = true
                    GrammarResult.Success("integer")
                }
                "boolean" -> {
                    needBoolean = true
                    GrammarResult.Success("boolean")
                }
                "null" -> {
                    needNull = true
                    GrammarResult.Success("null")
                }
                "array" -> compileArray(map, isRoot)
                "object" -> compileObject(map, isRoot)
                else -> GrammarResult.Failure("Unsupported JSON Schema type: $typeName")
            }
        }

        private fun compileStringEnum(enumVal: JsonValue, isRoot: Boolean): GrammarResult {
            if (enumVal !is JsonValue.Arr || enumVal.items.isEmpty()) {
                return GrammarResult.Failure("'enum' must be a non-empty array of strings")
            }
            val literals = ArrayList<String>(enumVal.items.size)
            for (item in enumVal.items) {
                if (item !is JsonValue.Str) {
                    return GrammarResult.Failure("Unsupported non-string value in 'enum'")
                }
                literals.add(gbnfQuotedJsonString(item.value))
            }
            val body = if (literals.size == 1) {
                "${literals[0]} ws"
            } else {
                "( ${literals.joinToString(" | ")} ) ws"
            }
            return GrammarResult.Success(if (isRoot) body else allocRule(body))
        }

        private fun compileArray(map: Map<String, JsonValue>, isRoot: Boolean): GrammarResult {
            val itemsVal = map["items"] ?: run {
                markValue()
                return GrammarResult.Success("array")
            }
            if (itemsVal !is JsonValue.Obj) {
                return GrammarResult.Failure("Unsupported 'items' schema: expected object")
            }
            return when (val compiled = compileExpr(itemsVal, isRoot = false)) {
                is GrammarResult.Failure -> compiled
                is GrammarResult.Success -> {
                    val itemRef = compiled.gbnf
                    val body = "\"[\" ws ( $itemRef ( \",\" ws $itemRef )* )? \"]\" ws"
                    GrammarResult.Success(if (isRoot) body else allocRule(body))
                }
            }
        }

        private fun compileObject(map: Map<String, JsonValue>, isRoot: Boolean): GrammarResult {
            val propsVal = map["properties"]
            if (propsVal == null) {
                val reqVal = map["required"]
                if (reqVal is JsonValue.Arr && reqVal.items.isNotEmpty()) {
                    return GrammarResult.Failure("'required' specifies properties but 'properties' is missing")
                }
                markValue()
                return GrammarResult.Success("object")
            }
            if (propsVal !is JsonValue.Obj) {
                return GrammarResult.Failure("'properties' must be an object")
            }

            val requiredSet = LinkedHashSet<String>()
            val reqVal = map["required"]
            if (reqVal != null) {
                if (reqVal !is JsonValue.Arr) {
                    return GrammarResult.Failure("'required' must be an array of property names")
                }
                for (item in reqVal.items) {
                    if (item !is JsonValue.Str) {
                        return GrammarResult.Failure("'required' entries must be strings")
                    }
                    requiredSet.add(item.value)
                }
            }

            val declaredNames = propsVal.entries.map { it.first }.toSet()
            for (reqName in requiredSet.sorted()) {
                if (reqName !in declaredNames) {
                    return GrammarResult.Failure("Required property '$reqName' not found in properties")
                }
            }

            val reqKv = mutableListOf<String>()
            val optKv = mutableListOf<String>()
            for ((propName, propSchema) in propsVal.entries) {
                when (val compiled = compileExpr(propSchema, isRoot = false)) {
                    is GrammarResult.Failure -> return compiled
                    is GrammarResult.Success -> {
                        val keyLit = gbnfQuotedJsonString(propName)
                        val kv = "$keyLit ws \":\" ws ${compiled.gbnf}"
                        if (propName in requiredSet) {
                            reqKv.add(kv)
                        } else {
                            optKv.add(kv)
                        }
                    }
                }
            }

            val body = if (reqKv.isEmpty() && optKv.isEmpty()) {
                "\"{\" ws \"}\" ws"
            } else if (reqKv.isNotEmpty()) {
                val parts = mutableListOf("\"{", "ws", reqKv[0])
                parts[0] = "\"{\""
                for (i in 1 until reqKv.size) {
                    parts.add("\",\" ws ${reqKv[i]}")
                }
                for (kv in optKv) {
                    parts.add("( \",\" ws $kv )?")
                }
                parts.add("\"}\" ws")
                parts.joinToString(" ")
            } else {
                val branches = mutableListOf<String>()
                for (i in optKv.indices) {
                    val branchParts = mutableListOf(optKv[i])
                    for (j in (i + 1) until optKv.size) {
                        branchParts.add("( \",\" ws ${optKv[j]} )?")
                    }
                    branches.add(branchParts.joinToString(" "))
                }
                "\"{\" ws ( ${branches.joinToString(" | ")} )? \"}\" ws"
            }

            return GrammarResult.Success(if (isRoot) body else allocRule(body))
        }

        fun finish(rootBody: String): String {
            val lines = mutableListOf("root ::= $rootBody")
            for ((name, body) in extraRules) {
                lines.add("$name ::= $body")
            }
            if (needValue) {
                lines.add("value ::= object | array | string | number | boolean | null")
            }
            if (needObject) {
                lines.add("object ::= \"{\" ws ( pair ( \",\" ws pair )* )? \"}\" ws")
                lines.add("pair ::= string \":\" ws value")
            }
            if (needArray) {
                lines.add("array ::= \"[\" ws ( value ( \",\" ws value )* )? \"]\" ws")
            }
            if (needString) {
                lines.add("string ::= \"\\\"\" char* \"\\\"\" ws")
                lines.add("char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" escape")
                lines.add("escape ::= [\"\\\\/bfnrt] | \"u\" hex hex hex hex")
                lines.add("hex ::= [0-9a-fA-F]")
            }
            if (needNumber) {
                lines.add("number ::= \"-\"? int frac? exp? ws")
            }
            if (needInteger) {
                lines.add("integer ::= \"-\"? int ws")
            }
            if (needNumber || needInteger) {
                lines.add("int ::= \"0\" | [1-9] [0-9]*")
            }
            if (needNumber) {
                lines.add("frac ::= \".\" [0-9]+")
                lines.add("exp ::= [eE] [+-]? [0-9]+")
            }
            if (needBoolean) {
                lines.add("boolean ::= (\"true\" | \"false\") ws")
            }
            if (needNull) {
                lines.add("null ::= \"null\" ws")
            }
            lines.add("ws ::= ([ \\t\\n\\r] ([ \\t\\n\\r] ([ \\t\\n\\r] [ \\t\\n\\r]?)?)?)?")
            return lines.joinToString("\n")
        }
    }

    private fun compileRoot(node: JsonValue): GrammarResult {
        val compiler = Compiler()
        return when (val root = compiler.compileExpr(node, isRoot = true)) {
            is GrammarResult.Failure -> root
            is GrammarResult.Success -> GrammarResult.Success(compiler.finish(root.gbnf))
        }
    }

    private fun gbnfQuotedJsonString(value: String): String {
        val jsonEscaped = StringBuilder()
        var i = 0
        while (i < value.length) {
            val cp = value.codePointAt(i)
            val charCount = Character.charCount(cp)
            when {
                cp == 0x22 -> jsonEscaped.append("\\\"")
                cp == 0x5C -> jsonEscaped.append("\\\\")
                cp == 0x08 -> jsonEscaped.append("\\b")
                cp == 0x0C -> jsonEscaped.append("\\f")
                cp == 0x0A -> jsonEscaped.append("\\n")
                cp == 0x0D -> jsonEscaped.append("\\r")
                cp == 0x09 -> jsonEscaped.append("\\t")
                cp < 0x20 -> jsonEscaped.append(String.format("\\u%04x", cp))
                else -> jsonEscaped.appendCodePoint(cp)
            }
            i += charCount
        }
        val jsonLiteral = "\"$jsonEscaped\""
        val gbnfEscaped = StringBuilder()
        for (ch in jsonLiteral) {
            when (ch) {
                '\\' -> gbnfEscaped.append("\\\\")
                '"' -> gbnfEscaped.append("\\\"")
                else -> gbnfEscaped.append(ch)
            }
        }
        return "\"$gbnfEscaped\""
    }

    // --- Minimal RFC-8259 recursive-descent JSON parser (zero external deps, order-preserving) ---

    private class MiniJsonParser(s: String) {
        private val bytes: ByteArray = s.toByteArray(Charsets.UTF_8)
        private var pos: Int = 0

        fun parseDocument(): JsonValue? {
            skipWs()
            val value = parseValue(0) ?: return null
            skipWs()
            return if (pos == bytes.size) value else null
        }

        private fun skipWs() {
            while (pos < bytes.size) {
                val b = bytes[pos].toInt() and 0xFF
                if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
                    pos++
                } else {
                    break
                }
            }
        }

        private fun parseValue(depth: Int): JsonValue? {
            if (depth > MAX_DEPTH || pos >= bytes.size) return null
            return when (bytes[pos].toInt() and 0xFF) {
                0x7B -> parseObject(depth + 1) // '{'
                0x5B -> parseArray(depth + 1)  // '['
                0x22 -> parseString()?.let { JsonValue.Str(it) }
                0x74 -> if (parseLiteral("true")) JsonValue.Bool(true) else null
                0x66 -> if (parseLiteral("false")) JsonValue.Bool(false) else null
                0x6E -> if (parseLiteral("null")) JsonValue.Null else null
                0x2D, in 0x30..0x39 -> if (parseNumber()) JsonValue.Num else null
                else -> null
            }
        }

        private fun parseObject(depth: Int): JsonValue? {
            pos++ // '{'
            skipWs()
            val entries = mutableListOf<Pair<String, JsonValue>>()
            if (pos < bytes.size && (bytes[pos].toInt() and 0xFF) == 0x7D) { // '}'
                pos++
                return JsonValue.Obj(entries)
            }
            while (true) {
                if (pos >= bytes.size || (bytes[pos].toInt() and 0xFF) != 0x22) return null
                val key = parseString() ?: return null
                skipWs()
                if (pos >= bytes.size || (bytes[pos].toInt() and 0xFF) != 0x3A) return null // ':'
                pos++
                skipWs()
                val value = parseValue(depth) ?: return null
                entries.add(key to value)
                skipWs()
                if (pos >= bytes.size) return null
                val next = bytes[pos].toInt() and 0xFF
                if (next == 0x7D) { // '}'
                    pos++
                    return JsonValue.Obj(entries)
                }
                if (next != 0x2C) return null // ','
                pos++
                skipWs()
            }
        }

        private fun parseArray(depth: Int): JsonValue? {
            pos++ // '['
            skipWs()
            val items = mutableListOf<JsonValue>()
            if (pos < bytes.size && (bytes[pos].toInt() and 0xFF) == 0x5D) { // ']'
                pos++
                return JsonValue.Arr(items)
            }
            while (true) {
                val value = parseValue(depth) ?: return null
                items.add(value)
                skipWs()
                if (pos >= bytes.size) return null
                val next = bytes[pos].toInt() and 0xFF
                if (next == 0x5D) { // ']'
                    pos++
                    return JsonValue.Arr(items)
                }
                if (next != 0x2C) return null // ','
                pos++
                skipWs()
            }
        }

        private fun parseString(): String? {
            if (pos >= bytes.size || (bytes[pos].toInt() and 0xFF) != 0x22) return null
            pos++
            val out = java.io.ByteArrayOutputStream()
            while (pos < bytes.size) {
                val b = bytes[pos].toInt() and 0xFF
                if (b == 0x22) { // '"'
                    pos++
                    return String(out.toByteArray(), Charsets.UTF_8)
                }
                if (b < 0x20) return null
                if (b == 0x5C) { // '\'
                    pos++
                    if (pos >= bytes.size) return null
                    val esc = bytes[pos].toInt() and 0xFF
                    pos++
                    when (esc) {
                        0x22 -> out.write(0x22)
                        0x5C -> out.write(0x5C)
                        0x2F -> out.write(0x2F)
                        0x62 -> out.write(0x08)
                        0x66 -> out.write(0x0C)
                        0x6E -> out.write(0x0A)
                        0x72 -> out.write(0x0D)
                        0x74 -> out.write(0x09)
                        0x75 -> {
                            val u1 = parseHex4() ?: return null
                            val cp = if (u1 in 0xD800..0xDBFF) {
                                if (pos + 1 >= bytes.size ||
                                    (bytes[pos].toInt() and 0xFF) != 0x5C ||
                                    (bytes[pos + 1].toInt() and 0xFF) != 0x75
                                ) return null
                                pos += 2
                                val u2 = parseHex4() ?: return null
                                if (u2 !in 0xDC00..0xDFFF) return null
                                0x10000 + ((u1 - 0xD800) shl 10) + (u2 - 0xDC00)
                            } else if (u1 in 0xDC00..0xDFFF) {
                                return null
                            } else {
                                u1
                            }
                            out.write(String(Character.toChars(cp)).toByteArray(Charsets.UTF_8))
                        }
                        else -> return null
                    }
                } else {
                    out.write(b)
                    pos++
                }
            }
            return null
        }

        private fun parseHex4(): Int? {
            if (pos + 4 > bytes.size) return null
            var value = 0
            for (i in 0 until 4) {
                val b = bytes[pos++].toInt() and 0xFF
                val digit = when (b) {
                    in 0x30..0x39 -> b - 0x30
                    in 0x41..0x46 -> b - 0x41 + 10
                    in 0x61..0x66 -> b - 0x61 + 10
                    else -> return null
                }
                value = (value shl 4) or digit
            }
            return value
        }

        private fun parseLiteral(literal: String): Boolean {
            val expected = literal.toByteArray(Charsets.UTF_8)
            if (pos + expected.size > bytes.size) return false
            for (i in expected.indices) {
                if (bytes[pos + i] != expected[i]) return false
            }
            pos += expected.size
            return true
        }

        private fun parseNumber(): Boolean {
            if (pos < bytes.size && (bytes[pos].toInt() and 0xFF) == 0x2D) pos++ // '-'
            if (pos >= bytes.size) return false
            val first = bytes[pos].toInt() and 0xFF
            if (first == 0x30) { // '0'
                pos++
            } else if (first in 0x31..0x39) {
                pos++
                while (pos < bytes.size && (bytes[pos].toInt() and 0xFF) in 0x30..0x39) pos++
            } else {
                return false
            }
            if (pos < bytes.size && (bytes[pos].toInt() and 0xFF) == 0x2E) { // '.'
                pos++
                if (pos >= bytes.size || (bytes[pos].toInt() and 0xFF) !in 0x30..0x39) return false
                while (pos < bytes.size && (bytes[pos].toInt() and 0xFF) in 0x30..0x39) pos++
            }
            if (pos < bytes.size && ((bytes[pos].toInt() and 0xFF) == 0x65 || (bytes[pos].toInt() and 0xFF) == 0x45)) {
                pos++
                if (pos < bytes.size && ((bytes[pos].toInt() and 0xFF) == 0x2B || (bytes[pos].toInt() and 0xFF) == 0x2D)) pos++
                if (pos >= bytes.size || (bytes[pos].toInt() and 0xFF) !in 0x30..0x39) return false
                while (pos < bytes.size && (bytes[pos].toInt() and 0xFF) in 0x30..0x39) pos++
            }
            return true
        }

        companion object {
            private const val MAX_DEPTH = 128
        }
    }
}
