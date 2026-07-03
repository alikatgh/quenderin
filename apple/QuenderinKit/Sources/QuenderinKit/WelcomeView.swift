#if canImport(SwiftUI)
import SwiftUI

/// The very first screen a new user sees — ONE calm page, before the model-setup flow:
/// who Quenderin is (the elf), the three things that make it different (private, offline,
/// open source), and a single Continue. Shown once (`WelcomeGate`); twin of Android's
/// `WelcomeScreen`.
public struct WelcomeView: View {
    let onContinue: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    public init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        ZStack {
            p.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                ModelOrb(size: 96)
                Text("Meet Quenderin")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(p.onSurface)
                    .padding(.top, 18)
                Text("A personal AI that lives on your \(deviceNoun) — not in someone's cloud.")
                    .font(.body)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 18) {
                    WelcomeRow(icon: "lock.shield", title: "Private by design",
                               detail: "Conversations never leave this \(deviceNoun). No account, no tracking.",
                               palette: p)
                    WelcomeRow(icon: "wifi.slash", title: "Works offline",
                               detail: "Download a model once — then it answers anywhere, airplane mode included.",
                               palette: p)
                    WelcomeRow(icon: "chevron.left.forwardslash.chevron.right", title: "Open source",
                               detail: "Every line of Quenderin is public. Read it, star it, improve it.",
                               palette: p)
                }
                .padding(.top, 28)
                .frame(maxWidth: 360, alignment: .leading)

                Spacer(minLength: 24)

                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 13)
                        .background(p.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button {
                    if let url = URL(string: SupportContact.githubURL) { openURL(url) }
                } label: {
                    Text("View the source on GitHub")
                        .font(.footnote)
                        .foregroundStyle(p.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .padding(28)
        }
    }
}

private struct WelcomeRow: View {
    let icon: String
    let title: String
    let detail: String
    let palette: QuenderinPalette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(palette.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.onSurface)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Has this install already seen the welcome page? A plain UserDefaults flag with an
/// injectable seam so tests (and previews) can force either state.
public enum WelcomeGate {
    static let key = "quenderin.hasWelcomed"

    public static func needsWelcome(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key)
    }

    public static func markWelcomed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
#endif
