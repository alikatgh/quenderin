#if canImport(SwiftUI)
import SwiftUI

/// A dependency-free Markdown renderer for chat replies — the SwiftUI twin of Android's `MarkdownText`.
/// Models emit Markdown (headings, **bold**, lists, `code`, fenced blocks); rendering it raw litters the
/// bubble with `*`, `#`, and backtick markers. This block-parses the common LLM subset — ATX headings,
/// fenced code, bullet/numbered lists, blockquotes, rules — and renders inline formatting (**bold**,
/// *italic*, `code`, [text](url)) via SwiftUI's native inline-markdown AttributedString. Not full
/// CommonMark (no tables/nested lists), but it covers assistant output and degrades gracefully.
///
/// PERFORMANCE: parsing (the block split + one `AttributedString(markdown:)` per run) is the
/// expensive half, and it used to happen inside `body` — so every body evaluation re-parsed the
/// whole message. A `LazyVStack` transcript re-creates recycled rows WHILE YOU SCROLL, which meant
/// a long reply was re-parsed dozens of times per second and scrolling crawled. Messages are
/// immutable once finished, so the parse is memoized per unique text (streaming intermediates just
/// age out of the cache).
struct MarkdownText: View {
    let text: String
    let color: Color

    var body: some View {
        let blocks = cachedBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.indices, id: \.self) { i in
                blocks[i].view(color: color)
            }
        }
    }
}

// ── Parse memoization ─────────────────────────────────────────────────────────

private final class ParsedBlocks {
    let blocks: [MdBlock]
    init(_ blocks: [MdBlock]) { self.blocks = blocks }
}

@MainActor
private let mdCache: NSCache<NSString, ParsedBlocks> = {
    let cache = NSCache<NSString, ParsedBlocks>()
    // Finished messages hit forever; a streaming bubble's per-token intermediates get evicted.
    cache.countLimit = 128
    return cache
}()

// Rendering (View.body) is main-actor, so the cache never needs to be touched off-main.
@MainActor
private func cachedBlocks(_ text: String) -> [MdBlock] {
    let key = text as NSString
    if let hit = mdCache.object(forKey: key) { return hit.blocks }
    let parsed = parseMarkdownBlocks(text)
    mdCache.setObject(ParsedBlocks(parsed), forKey: key)
    return parsed
}

// ── Blocks (inline runs pre-parsed to AttributedString at PARSE time, not render time) ──────────

private enum MdBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(raw: String, segments: [CodeSeg])
    case list(items: [AttributedString], ordered: Bool, start: Int)
    case quote(AttributedString)
    case rule

    @ViewBuilder func view(color: Color) -> some View {
        switch self {
        case let .heading(level, text):
            Text(text).font(headingFont(level)).fontWeight(.bold).foregroundStyle(color)
        case let .paragraph(t):
            Text(t).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        case let .code(raw, segments):
            CodeBlockView(raw: raw, segments: segments, plain: color)
        case let .list(items, ordered, start):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + i)." : "•").foregroundStyle(color)
                        Text(item).foregroundStyle(color)
                    }
                }
            }
        case let .quote(t):
            Text(t).italic().foregroundStyle(color.opacity(0.85)).padding(.leading, 10)
        case .rule:
            Divider().overlay(color.opacity(0.2))
        }
    }
}

private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title2
    case 2: return .title3
    default: return .headline
    }
}

/// Inline markdown → AttributedString via SwiftUI's native inline-only parser, falling back to the
/// plain string if it can't be parsed. Runs ONCE per block at parse time.
private func inline(_ s: String) -> AttributedString {
    let parsed = (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(s)
    return sanitizeLinks(parsed)
}

/// Q-326 (twin of the UI's Q-273): chat markdown is UNTRUSTED LLM output. A link like
/// `[click](javascript:…)` or `[click](https://evil/?leak=…)` renders tappable. Neutralize any link
/// whose scheme isn't http(s)/mailto — it becomes plain text, so no dangerous scheme is one tap away.
func sanitizeLinks(_ attr: AttributedString) -> AttributedString {
    var result = attr
    var unsafe: [Range<AttributedString.Index>] = []
    for run in result.runs where run.link != nil {
        let scheme = run.link?.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "mailto" { unsafe.append(run.range) }
    }
    for range in unsafe { result[range].link = nil }
    return result
}

// ── Block parsing (line-oriented; a blank line separates blocks) ──────────────
private func parseMarkdownBlocks(_ text: String) -> [MdBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [MdBlock] = []
    var i = 0
    var para = ""
    func flush() {
        let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { blocks.append(.paragraph(inline(t))) }
        para = ""
    }
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flush()
            // The fence's info string ("```python") names the language — feed the highlighter.
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            i += 1
            var buf: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                buf.append(lines[i]); i += 1
            }
            i += 1 // consume closing fence (or EOF)
            let raw = buf.joined(separator: "\n")
            blocks.append(.code(raw: raw, segments: tokenizeCode(raw, language: lang.isEmpty ? nil : lang)))
        } else if trimmed.isEmpty {
            flush(); i += 1
        } else if let h = matchHeading(line) {
            flush(); blocks.append(.heading(level: h.0, text: inline(h.1))); i += 1
        } else if isRule(trimmed) {
            flush(); blocks.append(.rule); i += 1
        } else if let b = matchBullet(line) {
            flush(); var items = [b]; i += 1
            while i < lines.count, let bb = matchBullet(lines[i]) { items.append(bb); i += 1 }
            blocks.append(.list(items: items.map(inline), ordered: false, start: 1))
        } else if let o = matchOrdered(line) {
            flush(); let start = o.0; var items = [o.1]; i += 1
            while i < lines.count, let oo = matchOrdered(lines[i]) { items.append(oo.1); i += 1 }
            blocks.append(.list(items: items.map(inline), ordered: true, start: start))
        } else if let q = matchQuote(line) {
            flush(); var buf = q; i += 1
            while i < lines.count, let qq = matchQuote(lines[i]) { buf += " " + qq; i += 1 }
            blocks.append(.quote(inline(buf.trimmingCharacters(in: .whitespaces))))
        } else {
            if !para.isEmpty { para += " " }
            para += trimmed
            i += 1
        }
    }
    flush()
    return blocks
}

private func matchHeading(_ line: String) -> (Int, String)? {
    var level = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == "#", level < 6 {
        level += 1; idx = line.index(after: idx)
    }
    guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
    let rest = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    return (level, rest)
}

private func matchBullet(_ line: String) -> String? {
    let t = line.drop(while: { $0 == " " })
    for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) {
        return String(t.dropFirst(2))
    }
    return nil
}

private func matchOrdered(_ line: String) -> (Int, String)? {
    let t = line.drop(while: { $0 == " " })
    var num = ""
    var idx = t.startIndex
    while idx < t.endIndex, t[idx].isNumber { num.append(t[idx]); idx = t.index(after: idx) }
    guard !num.isEmpty, idx < t.endIndex, t[idx] == "." || t[idx] == ")" else { return nil }
    let after = t.index(after: idx)
    guard after < t.endIndex, t[after] == " " else { return nil }
    return (Int(num) ?? 1, String(t[t.index(after: after)...]))
}

private func matchQuote(_ line: String) -> String? {
    guard line.hasPrefix(">") else { return nil }
    var s = String(line.dropFirst())
    if s.hasPrefix(" ") { s = String(s.dropFirst()) }
    return s
}

private func isRule(_ s: String) -> Bool {
    guard s.count >= 3 else { return false }
    let set = Set(s)
    return set.count == 1 && (set.first == "-" || set.first == "*" || set.first == "_")
}

// ── Code syntax highlighting ──────────────────────────────────────────────────
// Tokenized ONCE at parse time (same memoization as the block parse); colors are applied at
// render time from the theme palette so light/dark both read well. A small hand-rolled scanner,
// not a grammar — comments, strings, numbers, and a merged keyword set cover LLM-emitted code
// (Python/JS/Swift/Kotlin/shell) without a dependency.

struct CodeSeg {
    enum Kind { case plain, keyword, string, comment, number }
    let text: String
    let kind: Kind
}

private let codeKeywords: Set<String> = [
    // python
    "def", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "class",
    "try", "except", "finally", "with", "lambda", "pass", "break", "continue", "and", "or", "not",
    "is", "None", "True", "False", "raise", "yield", "global", "nonlocal", "assert", "del", "async", "await",
    // js / ts
    "function", "const", "let", "var", "new", "this", "typeof", "instanceof", "export", "default",
    "null", "undefined", "true", "false", "switch", "case", "do", "throw", "catch", "extends", "super", "of",
    // swift
    "func", "guard", "struct", "enum", "protocol", "extension", "init", "self", "nil", "some", "any",
    "public", "private", "internal", "static", "mutating", "defer",
    // kotlin / java
    "fun", "val", "when", "object", "data", "override", "open", "sealed", "companion", "int", "void",
]

/// Languages where `#` starts a comment; for an UNKNOWN language both `#` and `//` are treated as
/// comments — LLM answers default to Python-ish snippets, and a false comment line is a milder
/// failure than an unhighlighted one.
private func hashComments(_ lang: String?) -> Bool {
    guard let lang else { return true }
    return ["python", "py", "sh", "bash", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml", "r"].contains(lang)
}
private func slashComments(_ lang: String?) -> Bool {
    guard let lang else { return true }
    return !hashComments(lang)
}

func tokenizeCode(_ code: String, language: String?) -> [CodeSeg] {
    let useHash = hashComments(language)
    let useSlash = slashComments(language)
    var segs: [CodeSeg] = []
    var plain = ""
    func flushPlain() {
        if !plain.isEmpty { segs.append(CodeSeg(text: plain, kind: .plain)); plain = "" }
    }
    for (li, line) in code.components(separatedBy: "\n").enumerated() {
        if li > 0 { plain += "\n" }
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // comment → rest of line
            if (useHash && c == "#") || (useSlash && c == "/" && i + 1 < chars.count && chars[i + 1] == "/") {
                flushPlain()
                segs.append(CodeSeg(text: String(chars[i...]), kind: .comment))
                i = chars.count
            } else if c == "\"" || c == "'" || c == "`" {
                // string → to the matching quote on this line (escapes honored), else to EOL
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                let end = min(j, chars.count - 1)
                flushPlain()
                segs.append(CodeSeg(text: String(chars[i...end]), kind: .string))
                i = end + 1
            } else if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i + 1
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                flushPlain()
                segs.append(CodeSeg(text: String(chars[i..<j]), kind: .number))
                i = j
            } else if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if codeKeywords.contains(word) {
                    flushPlain()
                    segs.append(CodeSeg(text: word, kind: .keyword))
                } else {
                    plain += word
                }
                i = j
            } else {
                plain.append(c)
                i += 1
            }
        }
    }
    flushPlain()
    return segs
}

/// Renders pre-tokenized code with the palette's token colors. The colored AttributedString is
/// memoized per (code, scheme) — recycled LazyVStack rows must not rebuild it every body pass.
private struct CodeBlockView: View {
    let raw: String
    let segments: [CodeSeg]
    let plain: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(highlighted())
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(plain.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .textSelection(.enabled)
    }

    @MainActor
    private func highlighted() -> AttributedString {
        let key = "\(scheme == .dark ? "D" : "L")|\(raw)" as NSString
        if let hit = codeCache.object(forKey: key) { return hit.value }
        let p = QuenderinPalette.of(scheme)
        var out = AttributedString()
        for seg in segments {
            var run = AttributedString(seg.text)
            switch seg.kind {
            case .plain: run.foregroundColor = plain
            case .keyword: run.foregroundColor = p.codeKeyword
            case .string: run.foregroundColor = p.codeString
            case .comment: run.foregroundColor = p.codeComment
            case .number: run.foregroundColor = p.codeNumber
            }
            out += run
        }
        codeCache.setObject(Boxed(out), forKey: key)
        return out
    }
}

private final class Boxed {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

@MainActor
private let codeCache: NSCache<NSString, Boxed> = {
    let cache = NSCache<NSString, Boxed>()
    cache.countLimit = 64
    return cache
}()
#endif
