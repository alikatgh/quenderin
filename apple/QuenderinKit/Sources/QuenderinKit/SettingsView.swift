#if canImport(SwiftUI)
import SwiftUI

/// Settings / manage: the active model, on-device storage, and the in-app About/Privacy (folded in
/// from `AboutView`). Reachable as a tab. Clearing conversations lives in the chat History sheet,
/// where the live `ConversationCoordinator` is — this screen reads the count for display.
/// Twin of Android `SettingsScreen`.
public struct SettingsView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    private let model: ModelEntry
    @Environment(\.openURL) private var openURL

    public init(coordinator: ConversationCoordinator, model: ModelEntry) {
        self.coordinator = coordinator
        self.model = model
    }

    public var body: some View {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return List {
            Section("Model") {
                LabeledRow(title: "Active model", value: model.label)
                LabeledRow(title: "Size", value: model.sizeLabel)
                Text("Runs entirely on-device via llama.cpp — no cloud.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledRow(title: "Saved conversations", value: "\(coordinator.summaries.count)")
                Text("Browse, switch, or clear conversations from the History button in Chat.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                if let url = URL(string: SupportContact.privacyPolicyURL) {
                    Button { openURL(url) } label: { Label("Privacy Policy", systemImage: "lock.shield") }
                }
                Text(SupportContact.aiDisclaimer)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Support") {
                if let url = URL(string: "mailto:\(SupportContact.reportEmail)") {
                    Button { openURL(url) } label: { Label("Contact support", systemImage: "envelope") }
                }
            }
            Section {
                Text("Quenderin runs entirely on your device. No account, no cloud, no tracking — "
                   + "once a model is downloaded it works fully offline, and nothing you type leaves your phone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A title-on-the-left, value-on-the-right settings row.
private struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
