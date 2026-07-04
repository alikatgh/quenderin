#if canImport(SwiftUI)
import SwiftUI

/// The one screen every user must ACCEPT before using Quenderin — shown after the welcome
/// page on fresh installs, and once to existing users who predate it (its gate has its own
/// flag). Local models can be confidently wrong; this is where the user acknowledges that
/// the judgement — and the responsibility — stays with them. Twin of Android's
/// `ConsentScreen`; the copy lives in `SupportContact` so both platforms ship one wording.
public struct ConsentView: View {
    let onAgree: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    public init(onAgree: @escaping () -> Void) {
        self.onAgree = onAgree
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        ZStack {
            p.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Image(systemName: "hand.raised")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(p.primary)
                Text("Use with judgement")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(p.onSurface)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 18) {
                    ConsentRow(icon: "exclamationmark.bubble", title: "AI can be wrong",
                               detail: SupportContact.consentWrong, palette: p)
                    ConsentRow(icon: "stethoscope", title: "It is not advice",
                               detail: SupportContact.consentNotAdvice, palette: p)
                    ConsentRow(icon: "person.fill.checkmark", title: "You are in charge",
                               detail: SupportContact.consentResponsibility, palette: p)
                }
                .padding(.top, 28)
                .frame(maxWidth: 380, alignment: .leading)

                // The binding sentence, in full, right above the button that accepts it.
                Text(SupportContact.consentLegal)
                    .font(.footnote)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.top, 24)

                Spacer(minLength: 24)

                Button(action: onAgree) {
                    Text("I understand and agree")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 13)
                        .background(p.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button {
                    if let url = URL(string: SupportContact.termsURL) { openURL(url) }
                } label: {
                    Text("Read the full terms")
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

private struct ConsentRow: View {
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

/// Has this install accepted the AI-output disclaimer? Separate flag from `WelcomeGate` ON
/// PURPOSE: users who predate the consent screen have already been welcomed, but still must
/// agree once. Injectable seam for tests, like `WelcomeGate`.
public enum ConsentGate {
    static let key = "quenderin.disclaimerAccepted"

    public static func needsConsent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key)
    }

    public static func markAccepted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
#endif
