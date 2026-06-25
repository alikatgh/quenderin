import Foundation

/// Renders a chat transcript to a portable Markdown document the user can share or save — their data
/// stays theirs, exportable off the device on THEIR terms (not silently uploaded). Pure + testable.
/// Twin of Android `ConversationExporter`.
public enum ConversationExporter {
    public static func markdown(_ messages: [ChatMessage], title: String? = nil) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = (trimmed?.isEmpty == false) ? trimmed! : "Conversation"
        let count = messages.count
        var out = "# \(heading)\n\n"
        out += "_Exported from Quenderin — on-device, \(count) message\(count == 1 ? "" : "s")._\n\n"
        for message in messages {
            let speaker = message.role == .user ? "You" : "Quenderin"
            out += "**\(speaker):**\n\(message.text)\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
