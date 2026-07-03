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
    case code(String)
    case list(items: [AttributedString], ordered: Bool, start: Int)
    case quote(AttributedString)
    case rule

    @ViewBuilder func view(color: Color) -> some View {
        switch self {
        case let .heading(level, text):
            Text(text).font(headingFont(level)).fontWeight(.bold).foregroundStyle(color)
        case let .paragraph(t):
            Text(t).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        case let .code(code):
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
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
    (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(s)
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
            flush(); i += 1
            var buf: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                buf.append(lines[i]); i += 1
            }
            i += 1 // consume closing fence (or EOF)
            blocks.append(.code(buf.joined(separator: "\n")))
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
#endif
