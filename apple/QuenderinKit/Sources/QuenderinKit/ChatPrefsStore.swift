import Foundation
import Combine

/// Per-CONVERSATION appearance overrides — "this chat looks like this", while the global
/// defaults live in Settings (AppSettings). Deliberately a tiny UserDefaults side-store keyed
/// by conversation id, NOT part of the conversation index: it works for a brand-new empty chat
/// (which has no index row yet — the WhatsApp rule), needs no persistence-schema change, and a
/// missing key simply means "follow the global default". Twin: Android SharedPreferences
/// ("quenderin.chatprefs.<id>", parity chip).
@MainActor
public final class ChatPrefsStore: ObservableObject {
    public static let shared = ChatPrefsStore()

    /// Bumped on every mutation so SwiftUI observers re-resolve effective values.
    @Published private(set) var version = 0

    private let defaults: UserDefaults
    private func key(_ id: String) -> String { "quenderin.chatprefs.\(id)" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func fontStyle(for id: String) -> String? {
        (defaults.dictionary(forKey: key(id)) as? [String: String])?["fontStyle"]
    }

    public func fontSize(for id: String) -> String? {
        (defaults.dictionary(forKey: key(id)) as? [String: String])?["fontSize"]
    }

    /// Set an override; nil clears that field. When both end up nil the key is removed —
    /// "no entry" and "all defaults" must stay the same state.
    public func set(fontStyle: String?, fontSize: String?, for id: String) {
        var dict: [String: String] = [:]
        if let fontStyle { dict["fontStyle"] = fontStyle }
        if let fontSize { dict["fontSize"] = fontSize }
        if dict.isEmpty {
            defaults.removeObject(forKey: key(id))
        } else {
            defaults.set(dict, forKey: key(id))
        }
        version += 1
    }

    /// Delete a conversation's overrides (called from the conversation delete/clear paths —
    /// orphaned prefs must not haunt a future conversation that reuses nothing but disk).
    public func clear(for id: String) {
        defaults.removeObject(forKey: key(id))
        version += 1
    }
}
