import Foundation

public struct SpeechVocabularyTerm: Codable, Sendable, Equatable {
    public let term: String
    public let phoneticHints: [String]
    public let caseSensitive: Bool

    public init(term: String, phoneticHints: [String] = [], caseSensitive: Bool = false) {
        self.term = term
        self.phoneticHints = phoneticHints
        self.caseSensitive = caseSensitive
    }
}

public struct SpeechFormattingOptions: Codable, Sendable, Equatable {
    public let vocabulary: [SpeechVocabularyTerm]
    public let removeFillerWords: Bool
    public let spokenPunctuation: Bool
    public let spokenLists: Bool
    public let frenchSpacing: Bool
    public let endWithPeriod: Bool
    public let lowercaseOutput: Bool
    public let language: String?

    public init(
        vocabulary: [SpeechVocabularyTerm] = [],
        removeFillerWords: Bool = false,
        spokenPunctuation: Bool = false,
        spokenLists: Bool = false,
        frenchSpacing: Bool = false,
        endWithPeriod: Bool = false,
        lowercaseOutput: Bool = false,
        language: String? = nil
    ) {
        self.vocabulary = vocabulary
        self.removeFillerWords = removeFillerWords
        self.spokenPunctuation = spokenPunctuation
        self.spokenLists = spokenLists
        self.frenchSpacing = frenchSpacing
        self.endWithPeriod = endWithPeriod
        self.lowercaseOutput = lowercaseOutput
        self.language = language
    }
}

/// Enforces preferred spelling of technical or custom vocabulary terms (MIT port of anomalyco/hex HEXShared).
public enum VocabularySpelling {
    private struct Rule {
        let needle: String
        let replacement: String
        let caseSensitive: Bool
    }

    private struct Span {
        let start: String.Index
        let end: String.Index
        let replacement: String
    }

    public static func apply(to text: String, vocabulary: [SpeechVocabularyTerm]) -> String {
        guard !text.isEmpty, !vocabulary.isEmpty else { return text }
        var rules: [Rule] = []
        var seen = Set<String>()
        for entry in vocabulary.prefix(100) {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for rawCandidate in [term] + entry.phoneticHints {
                let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { continue }
                let key = "\(entry.caseSensitive ? "s" : "i"):\(candidate.lowercased())->\(term)"
                if seen.insert(key).inserted {
                    rules.append(Rule(needle: candidate, replacement: term, caseSensitive: entry.caseSensitive))
                }
            }
        }
        guard !rules.isEmpty else { return text }
        rules.sort { $0.needle.count > $1.needle.count }

        var spans: [Span] = []
        for rule in rules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.needle)
            let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: fullRange) {
                guard let range = Range(match.range, in: text) else { continue }
                let overlaps = spans.contains { range.lowerBound < $0.end && range.upperBound > $0.start }
                if !overlaps {
                    spans.append(Span(start: range.lowerBound, end: range.upperBound, replacement: rule.replacement))
                }
            }
        }
        guard !spans.isEmpty else { return text }
        spans.sort { $0.start < $1.start }

        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.start]
            result += span.replacement
            cursor = span.end
        }
        result += text[cursor...]
        return result
    }
}

public enum SpokenPunctuation {
    private static let rules: [(String, String)] = [
        (#"\bnew paragraph\b"#, "\n\n"),
        (#"\bnew line\b"#, "\n"),
        (#"\bquestion mark\b"#, "?"),
        (#"\bexclamation point\b"#, "!"),
        (#"\bexclamation mark\b"#, "!"),
        (#"\bsemicolon\b"#, ";"),
        (#"\bcolon\b"#, ":"),
        (#"\bcomma\b"#, ","),
        (#"\bperiod\b"#, "."),
    ]

    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for (pattern, symbol) in rules {
            out = out.replacingOccurrences(of: pattern, with: symbol, options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: #"[ \t]+([.,!?;:])"#, with: "$1", options: .regularExpression)
        return out
    }
}

public enum SpokenLists {
    /// Converts explicit spoken enumerations (`"first X second Y third Z"`) into clean multiline bullets.
    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let ordinals = ["first", "second", "third", "fourth", "fifth"]
        var working = text
        var hits = 0
        for (index, word) in ordinals.enumerated() {
            let pattern = #"(?i)(?:^|\s)\#(word)[:,]?\s+"#.replacingOccurrences(of: "#(word)", with: word)
            if working.range(of: pattern, options: .regularExpression) != nil {
                hits += 1
                let prefix = index == 0 ? "1. " : "\n\(index + 1). "
                working = working.replacingOccurrences(of: pattern, with: prefix, options: .regularExpression)
            } else {
                break
            }
        }
        return hits >= 2 ? working.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

public enum FrenchSpacing {
    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text.replacingOccurrences(of: #"\s*([;:!?»])"#, with: "\u{202F}$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"«\s*"#, with: "«\u{202F}", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptFormatter {
    public static func format(_ text: String, options: SpeechFormattingOptions = SpeechFormattingOptions()) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "" }

        if options.removeFillerWords {
            out = out.replacingOccurrences(
                of: #"(?i)(?<![\p{L}\p{N}_])(um+|uh+|er+|ah+)(?![\p{L}\p{N}_])[,\s]*"#,
                with: " ",
                options: .regularExpression
            )
        }
        if options.spokenPunctuation {
            out = SpokenPunctuation.apply(to: out)
        }
        if options.spokenLists {
            out = SpokenLists.apply(to: out)
        }
        if !options.vocabulary.isEmpty {
            out = VocabularySpelling.apply(to: out, vocabulary: options.vocabulary)
        }
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        if options.frenchSpacing {
            out = FrenchSpacing.apply(to: out)
        }
        if options.lowercaseOutput {
            out = out.lowercased()
        }
        if options.endWithPeriod && !out.isEmpty,
           let last = out.last,
           !".!?…".contains(last) {
            out += "."
        }
        return out
    }
}
