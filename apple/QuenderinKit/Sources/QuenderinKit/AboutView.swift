#if canImport(SwiftUI)
import SwiftUI

/// In-app About / Privacy. Both stores prefer privacy info reachable inside the app (Play expects
/// an in-app link, not just the store listing). Surfaces the on-device promise, the AI-content
/// disclaimer, the privacy-policy link, and a support contact. Twin of Android `AboutScreen`.
public struct AboutView: View {
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return List {
            Section {
                Text("Quenderin runs entirely on your device. No account, no cloud, no tracking — "
                   + "once a model is downloaded it works fully offline, and nothing you type leaves your phone.")
                    .font(.callout)
            }
            Section("Privacy") {
                if let url = URL(string: SupportContact.privacyPolicyURL) {
                    Button { openURL(url) } label: { Label("Privacy Policy", systemImage: "lock.shield") }
                }
                Text(SupportContact.aiDisclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Support") {
                if let url = URL(string: "mailto:\(SupportContact.reportEmail)") {
                    Button { openURL(url) } label: { Label("Contact support", systemImage: "envelope") }
                }
            }
            Section {
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
