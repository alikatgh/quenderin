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

    @Published public var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    @Published public var chatFontStyle: ChatFontStyle { didSet { save(chatFontStyle.rawValue, "chatFontStyle") } }
    @Published public var chatFontSize: ChatFontSize { didSet { save(chatFontSize.rawValue, "chatFontSize") } }
    /// When on, the router suggests the best installed model for a new chat's first message.
    @Published public var suggestBestModel: Bool { didSet { defaults.set(suggestBestModel, forKey: Self.key("suggestBestModel")) } }

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
        chatFontStyle = ChatFontStyle(rawValue: defaults.string(forKey: Self.key("chatFontStyle")) ?? "") ?? .standard
        chatFontSize = ChatFontSize(rawValue: defaults.string(forKey: Self.key("chatFontSize")) ?? "") ?? .standard
        suggestBestModel = defaults.object(forKey: Self.key("suggestBestModel")) as? Bool ?? true
    }
}
#endif
