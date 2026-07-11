#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// The dedicated About PAGE — what used to be a popup menu at the rail foot (owner: "show the
/// page, with all these info instead of this pop up window"). GitHub is the only link that
/// leaves our world; help, changelog and privacy all land on their quenderin.org pages, so the
/// website — not a menu — is where people learn the product.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        let p = QuenderinPalette.of(scheme)
        ScrollView {
            VStack(spacing: 0) {
                // Identity header — the elf IS the account picture of an app with no accounts.
                VStack(spacing: 12) {
                    ModelAvatar(size: 96)
                    Text("Quenderin")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(p.onSurface)
                    Text("Version \(version) — on-device · private · open source")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(p.onSurfaceVariant)
                }
                .padding(.top, 48)
                .padding(.bottom, 28)

                VStack(spacing: 0) {
                    // macOS 14 removed the legacy `showSettingsWindow:` selector path — it fails
                    // SILENTLY, so this row was "clickable but opens nothing" (live user report).
                    // Use the SwiftUI openSettings action where it exists; the selector remains
                    // only for macOS 13.
                    if #available(macOS 14.0, *) {
                        OpenSettingsRow(palette: p)
                    } else {
                        aboutRow(icon: "gearshape", title: "Settings", detail: "⌘,", external: false, palette: p) {
                            openSettingsLegacy()
                        }
                    }
                    hairline(p)
                    aboutRow(icon: "questionmark.circle", title: "Get help", detail: "quenderin.org/help", external: true, palette: p) {
                        open(SupportContact.helpURL)
                    }
                    hairline(p)
                    aboutRow(icon: "clock.arrow.circlepath", title: "What's new — the changelog", detail: "quenderin.org/changelog", external: true, palette: p) {
                        open(SupportContact.changelogURL)
                    }
                    hairline(p)
                    aboutRow(icon: "lock.shield", title: "Privacy Policy", detail: "quenderin.org/privacy", external: true, palette: p) {
                        open(SupportContact.privacyPolicyURL)
                    }
                    hairline(p)
                    aboutRow(icon: "globe", title: "quenderin.org", detail: "the website", external: true, palette: p) {
                        open(SupportContact.websiteURL)
                    }
                    hairline(p)
                    aboutRow(icon: "chevron.left.forwardslash.chevron.right", title: "View the source on GitHub", detail: "MIT licensed", external: true, palette: p) {
                        open(SupportContact.githubURL)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
                .frame(maxWidth: 520)
                .padding(.horizontal, 32)

                // Where other apps put "Log out": the promise, stated where they'd expect the button.
                Text("No account, no log-out — your chats never leave this Mac.")
                    .font(.callout)
                    .foregroundStyle(p.onSurfaceVariant)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity)
        }
        .background(p.background)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { openURL(url) }
    }

    /// macOS 13 only — the selector this targets was removed in macOS 14 (it no-ops there).
    private func openSettingsLegacy() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func hairline(_ p: QuenderinPalette) -> some View {
        Rectangle().fill(p.onSurfaceVariant.opacity(0.15)).frame(height: 1).padding(.leading, 52)
    }

    @ViewBuilder
    private func aboutRow(icon: String, title: LocalizedStringKey, detail: String, external: Bool, palette p: QuenderinPalette, action: @escaping () -> Void) -> some View {
        AboutRowButton(icon: icon, title: title, detail: detail, external: external, palette: p, action: action)
    }
}

/// The Settings row on macOS 14+ — a separate view because `\.openSettings` only exists there,
/// and an `@Environment` property can't be availability-gated inside a macOS-13-deployment view.
@available(macOS 14.0, *)
private struct OpenSettingsRow: View {
    let palette: QuenderinPalette
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AboutRowButton(icon: "gearshape", title: "Settings", detail: "⌘,", external: false, palette: palette) {
            openSettings()
        }
    }
}

/// One About row: icon · title · muted detail · ↗ for links that leave the app. Hover is a
/// background tint only — geometry never moves (UI rule).
private struct AboutRowButton: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: String
    let external: Bool
    let palette: QuenderinPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(palette.onSurface)
                Spacer()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(palette.onSurfaceVariant)
                if external {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(hovering ? palette.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
#endif
