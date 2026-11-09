import Foundation

/// Named guidance, adapted from Turnstone 1.9 skills.
///
/// At most one note is active, and only because the user named it. A note has
/// text. It does not choose a model, temperature, or tool grant. The shell
/// fills `{{model}}` from the selected model's label. Other `{{...}}` stay
/// as written.
public enum GuidanceResult: Sendable, Equatable {
    case ok
    case rejected(String)
}

public enum NamedGuidance {
    public static let nameMessage = "Guidance names are 1-48 letters, digits, spaces, or hyphens."
    public static let textMessage = "Guidance text must be 1-1500 characters."
    public static let capacityMessage = "The guidance notebook already holds 24 notes. Remove one before saving another."

    public static func unknownMessage(_ name: String) -> String {
        "No guidance named \"\(name)\". Choose a saved note by its exact name."
    }

    public static func fillModelPlaceholder(_ text: String, modelLabel: String) -> String {
        let label = String(modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return text.replacingOccurrences(of: "{{model}}", with: label)
    }

    public static func body(name: String, text: String, modelLabel: String) -> String {
        "Guidance note \"\(name)\" (instructions only; it does not change the model or which tools can run):\n\(fillModelPlaceholder(text, modelLabel: modelLabel))"
    }

    public static func append(_ base: String, rendered: String?) -> String {
        guard let rendered, !rendered.isEmpty else { return base }
        if base.isEmpty { return rendered }
        return base + "\n\n" + rendered
    }
}

public final class GuidanceNotebook: @unchecked Sendable {
    public static let maxNotes = 24
    private var notes: [String: String] = [:]
    public private(set) var active: String?

    public init() {}

    public func save(name: String, text: String) -> GuidanceResult {
        guard let cleanedName = Self.normalizeName(name) else { return .rejected(NamedGuidance.nameMessage) }
        guard let cleanedText = Self.normalizeText(text) else { return .rejected(NamedGuidance.textMessage) }
        if notes[cleanedName] == nil && notes.count >= Self.maxNotes {
            return .rejected(NamedGuidance.capacityMessage)
        }
        notes[cleanedName] = cleanedText
        return .ok
    }

    /// Activate a saved note by its exact name. Does not create a note and does not search.
    public func select(name: String) -> GuidanceResult {
        let cleanedName = Self.normalizeName(name)
        guard let cleanedName, notes[cleanedName] != nil else {
            return .rejected(NamedGuidance.unknownMessage(cleanedName ?? name.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        active = cleanedName
        return .ok
    }

    public func clear() { active = nil }

    public func render(modelLabel: String) -> String? {
        guard let active, let text = notes[active] else { return nil }
        return NamedGuidance.body(name: active, text: text, modelLabel: modelLabel)
    }

    private static func normalizeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(trimmed.count) else { return nil }
        var first = true
        for scalar in trimmed.unicodeScalars {
            let value = scalar.value
            let digit = value >= 48 && value <= 57
            let upper = value >= 65 && value <= 90
            let lower = value >= 97 && value <= 122
            let space = value == 32
            let hyphen = value == 45
            if first {
                if !(digit || upper || lower) { return nil }
                first = false
            } else if !(digit || upper || lower || space || hyphen) {
                return nil
            }
        }
        return trimmed
    }

    private static func normalizeText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1500).contains(trimmed.count) else { return nil }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 32 && scalar.value != 10 { return nil }
        }
        return trimmed
    }
}
