import Foundation

/// Turns a user-picked file into an `AttachedDocument` at attach time (Milestone 1 — roadmap
/// Stage 2 "documents in chat", the no-engine-work milestone). Text files only for now: strict
/// UTF-8 (a binary file is refused with a reason, never silently mangled), capped so one
/// attachment can't blow the model's context. PDF text extraction is the named next extension —
/// this is the seam it plugs into.
public enum DocumentTextExtractor {
    public enum Extraction: Equatable {
        case document(AttachedDocument)
        case rejected(reason: String)
    }

    /// 24 KB default: big enough for READMEs/configs/notes, small enough that a 2048-token
    /// context (a phone under pressure) still has room to answer about it.
    public static func extract(name: String, url: URL, maxBytes: Int = 24 * 1024) -> Extraction {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .rejected(reason: "Couldn't open \"\(name)\".")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else {
            return .rejected(reason: "Couldn't read \"\(name)\".")
        }
        let truncated = data.count > maxBytes
        guard let text = String(data: truncated ? data.prefix(maxBytes) : data, encoding: .utf8) else {
            return .rejected(reason: "\"\(name)\" isn't a text file — only text attachments are supported for now.")
        }
        let body = truncated ? text + "\n[…file truncated at \(maxBytes / 1024) KB]" : text
        return .document(AttachedDocument(name: name, text: body))
    }
}
