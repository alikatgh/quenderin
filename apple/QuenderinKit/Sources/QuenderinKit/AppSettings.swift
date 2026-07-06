#if canImport(SwiftUI)
import SwiftUI

/// User preferences that change how the app LOOKS and BEHAVES — one observable store,
/// UserDefaults-backed, every default matching the app's behavior before the setting existed
/// (a fresh install is byte-for-byte the old app until the user moves something).
///
/// Rule from the bug journal ("advertised-but-unimplemented surface"): a setting ships only
/// when something actually reads it. Twin of Android's settings DataStore (parity chip).
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public enum Theme: String, CaseIterable {
        case system, light, dark
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
        public var label: String { rawValue.capitalized }
    }

    public enum ChatFontStyle: String, CaseIterable {
        case standard, serif, monospaced
        public var design: Font.Design {
            switch self {
            case .standard: return .default
            case .serif: return .serif
            case .monospaced: return .monospaced
            }
        }
        public var label: String {
            switch self {
            case .standard: return "System"
            case .serif: return "Serif"
            case .monospaced: return "Monospaced"
            }
        }
    }

    public enum ChatFontSize: String, CaseIterable {
        case small, standard, large, extraLarge
        public var points: CGFloat {
            switch self {
            case .small: return 13
            case .standard: return 15
            case .large: return 17
            case .extraLarge: return 19
            }
        }
        public var label: String {
            switch self {
            case .small: return "Small"
            case .standard: return "Standard"
            case .large: return "Large"
            case .extraLarge: return "Extra large"
            }
        }
    }

    /// User-bubble color presets, all sampled/derived from the brand artwork so every choice
    /// stays "ours" (no free color picker — that's how Stripe purple sneaks back in).
    public enum BubbleAccent: String, CaseIterable {
        case teal, copper, forest, slate
        public var label: String {
            switch self {
            case .teal: return "Teal (default)"
            case .copper: return "Copper"
            case .forest: return "Forest"
            case .slate: return "Slate"
            }
        }
        /// (bubble, text, timestamp) for the USER side, per color scheme — each pair checked
        /// for contrast on its bubble.
        public func colors(dark: Bool) -> (bubble: Color, text: Color, timestamp: Color) {
            switch (self, dark) {
            case (.teal, true):    return (Color(hex: 0x245A62), Color(hex: 0xEAF6F4), Color(hex: 0xA8CDD1))
            case (.teal, false):   return (Color(hex: 0x2E7680), .white, Color(hex: 0xC9E4E6))
            case (.copper, true):  return (Color(hex: 0x6E431C), Color(hex: 0xFFF3E4), Color(hex: 0xE3C4A1))
            case (.copper, false): return (Color(hex: 0xB4632A), .white, Color(hex: 0xF0D9C4))
            case (.forest, true):  return (Color(hex: 0x2F5738), Color(hex: 0xE9F5EA), Color(hex: 0xB5D9BC))
            case (.forest, false): return (Color(hex: 0x3A7047), .white, Color(hex: 0xD3E8D8))
            case (.slate, true):   return (Color(hex: 0x3A434C), Color(hex: 0xEDF2F6), Color(hex: 0xB7C4CE))
            case (.slate, false):  return (Color(hex: 0x51616E), .white, Color(hex: 0xD5DEE5))
            }
        }
    }

    public enum MessageDensity: String, CaseIterable {
        case comfortable, compact
        public var spacing: CGFloat { self == .comfortable ? 6 : 3 }
        public var label: String { rawValue.capitalized }
    }

    @Published public var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    @Published public var bubbleAccent: BubbleAccent { didSet { save(bubbleAccent.rawValue, "bubbleAccent") } }
    @Published public var messageDensity: MessageDensity { didSet { save(messageDensity.rawValue, "messageDensity") } }
    @Published public var chatFontStyle: ChatFontStyle { didSet { save(chatFontStyle.rawValue, "chatFontStyle") } }
    @Published public var chatFontSize: ChatFontSize { didSet { save(chatFontSize.rawValue, "chatFontSize") } }
    /// When on, the router suggests the best installed model for a new chat's first message.
    @Published public var suggestBestModel: Bool { didSet { defaults.set(suggestBestModel, forKey: Self.key("suggestBestModel")) } }

    /// Q-578: opt in to model downloads over cellular. Default OFF — a multi-GB pull on cellular can
    /// cost real money, so Wi-Fi-only is the safe default the DownloadPolicy reason string points the
    /// user to ("…or allow cellular downloads in settings"). This IS that setting.
    @Published public var allowCellularDownloads: Bool { didSet { defaults.set(allowCellularDownloads, forKey: Self.key("allowCellularDownloads")) } }

    /// The active download network policy, derived from the toggle above. The onboarding + model-library
    /// download gates read THIS (honoring the journal rule: a setting ships only when something reads it).
    public var downloadPolicy: DownloadPolicy { allowCellularDownloads ? .wifiOrCellular : .wifiOnly }

    /// The chat transcript's base font — bubbles inherit it via the environment; Markdown
    /// headings/code keep their own explicit sizes.
    public var chatFont: Font {
        .system(size: chatFontSize.points, design: chatFontStyle.design)
    }

    private let defaults: UserDefaults
    private static func key(_ name: String) -> String { "quenderin.settings.\(name)" }
    private func save(_ value: String, _ name: String) { defaults.set(value, forKey: Self.key(name)) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme(rawValue: defaults.string(forKey: Self.key("theme")) ?? "") ?? .system
        bubbleAccent = BubbleAccent(rawValue: defaults.string(forKey: Self.key("bubbleAccent")) ?? "") ?? .teal
        messageDensity = MessageDensity(rawValue: defaults.string(forKey: Self.key("messageDensity")) ?? "") ?? .comfortable
        chatFontStyle = ChatFontStyle(rawValue: defaults.string(forKey: Self.key("chatFontStyle")) ?? "") ?? .standard
        chatFontSize = ChatFontSize(rawValue: defaults.string(forKey: Self.key("chatFontSize")) ?? "") ?? .standard
        suggestBestModel = defaults.object(forKey: Self.key("suggestBestModel")) as? Bool ?? true
        allowCellularDownloads = defaults.object(forKey: Self.key("allowCellularDownloads")) as? Bool ?? false
    }
}
#endif
