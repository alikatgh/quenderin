import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Turns a user-picked file into an `AttachedDocument` at attach time (Milestone 1 — roadmap
/// Stage 2 "documents in chat", the no-engine-work milestone). Plain text (strict UTF-8 — a
/// binary file is refused with a reason, never silently mangled) and, on Apple platforms,
/// **PDF text** via PDFKit (no new dependencies). Both capped so one attachment can't blow
/// the model's context. Android's twin is text-only until a dependency decision — recorded gap.
public enum DocumentTextExtractor {
    public enum Extraction: Equatable {
        case document(AttachedDocument)
        case rejected(reason: String)
    }

    /// 24 KB default: big enough for READMEs/configs/notes, small enough that a 2048-token
    /// context (a phone under pressure) still has room to answer about it.
    public static func extract(name: String, url: URL, maxBytes: Int = 24 * 1024) -> Extraction {
        #if canImport(PDFKit)
        if name.lowercased().hasSuffix(".pdf") {
            return extractPDF(name: name, url: url, maxBytes: maxBytes)
        }
        #endif
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .rejected(reason: "Couldn't open \"\(name)\".")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else {
            return .rejected(reason: "Couldn't read \"\(name)\".")
        }
        let truncated = data.count > maxBytes
        guard let text = String(data: truncated ? data.prefix(maxBytes) : data, encoding: .utf8) else {
            return .rejected(reason: "\"\(name)\" isn't a text file — only text and PDF attachments are supported for now.")
        }
        let body = truncated ? text + "\n[…file truncated at \(maxBytes / 1024) KB]" : text
        return .document(AttachedDocument(name: name, text: body))
    }

    #if canImport(PDFKit)
    /// PDF → text page by page, stopping once the cap is reached (a 500-page PDF must not be
    /// fully string-ified just to keep 24 KB). A PDF with no extractable text (scans) is
    /// refused honestly — OCR is out of scope for on-device v1.
    private static func extractPDF(name: String, url: URL, maxBytes: Int) -> Extraction {
        guard let pdf = PDFDocument(url: url) else {
            return .rejected(reason: "Couldn't open \"\(name)\" as a PDF.")
        }
        var text = ""
        var truncated = false
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), let pageText = page.string else { continue }
            text += pageText + "\n"
            if text.utf8.count > maxBytes {
                truncated = true
                break
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(reason: "\"\(name)\" has no extractable text (a scanned PDF?) — OCR isn't supported yet.")
        }
        var body = trimmed
        if truncated {
            while body.utf8.count > maxBytes { body.removeLast() }
            body += "\n[…PDF truncated at \(maxBytes / 1024) KB]"
        }
        return .document(AttachedDocument(name: name, text: body))
    }
    #endif
}
