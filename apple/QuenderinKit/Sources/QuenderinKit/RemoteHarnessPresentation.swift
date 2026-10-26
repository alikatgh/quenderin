import Foundation

/// Remote output is untrusted and can be MiB-scale. Gate before any Markdown
/// parsing/cache lookup: at most 16 KiB, 128 delimiter markers, and 128 lines.
/// One line can produce at most one block/list row in the existing renderer.
enum RemoteHarnessTextBudget {
    static let maximumFormattingBytes = 16_384
    static let maximumFormattingMarkers = 128
    static let maximumFormattedLines = 128
    static let maximumRawPageBytes = 16_384
    static func allowsFormatting(_ text: String) -> Bool {
        var bytes = 0, markers = 0, lines = 1
        for byte in text.utf8 {
            bytes += 1
            if bytes > maximumFormattingBytes { return false }
            if byte == 42 || byte == 95 || byte == 91 || byte == 96 {
                markers += 1
                if markers > maximumFormattingMarkers { return false }
            }
            if byte == 10 {
                lines += 1
                if lines > maximumFormattedLines { return false }
            }
        }
        return true
    }
}

/// Extract just the selected raw page, never an eager array of every page.
/// Boundaries preserve UTF-8 scalars and the original CRLF/spacing bytes.
struct RemoteHarnessRawTextPage {
    let text: String
    let index: Int
    let count: Int
    init(_ source: String, index requested: Int) {
        let bytes = source.utf8, byteCount = bytes.count
        // Reserve three bytes for moving a boundary past a multibyte scalar.
        let stride = RemoteHarnessTextBudget.maximumRawPageBytes - 3
        func boundary(_ offset: Int) -> String.UTF8View.Index {
            var result = bytes.index(bytes.startIndex, offsetBy: min(offset, byteCount))
            while result != bytes.endIndex, bytes[result] & 0xc0 == 0x80 { bytes.formIndex(after: &result) }
            return result
        }
        var pages = max(1, (byteCount + stride - 1) / stride)
        if pages > 1, boundary((pages - 1) * stride) == bytes.endIndex { pages -= 1 }
        count = pages; index = min(max(0, requested), pages - 1)
        let start = boundary(index * stride), end = boundary((index + 1) * stride)
        text = String(decoding: bytes[start..<end], as: UTF8.self)
    }
}

#if canImport(Combine)
import Combine

/// Presentation only. These preferences never travel to a Host or change its
/// model, workspace, permission mode, notifications, or execution policy.
@MainActor final class RemoteHarnessPresentationPreferences: ObservableObject {
    enum TextSize: String, CaseIterable {
        case standard, larger, largest
        var title: String {
            switch self {
            case .standard: return "Standard"
            case .larger: return "Larger"
            case .largest: return "Largest"
            }
        }
    }
    static let wrapsCodeKey = "remoteHarness.presentation.wrapsCode"
    static let textSizeKey = "remoteHarness.presentation.textSize"
    private let defaults: UserDefaults
    @Published var wrapsCode: Bool { didSet { defaults.set(wrapsCode, forKey: Self.wrapsCodeKey) } }
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: Self.textSizeKey) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wrapsCode = defaults.object(forKey: Self.wrapsCodeKey) as? Bool ?? true
        textSize = defaults.string(forKey: Self.textSizeKey).flatMap(TextSize.init(rawValue:)) ?? .standard
    }
}
#endif
