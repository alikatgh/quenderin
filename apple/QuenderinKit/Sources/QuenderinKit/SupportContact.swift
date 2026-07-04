import Foundation

/// Content-safety surface for the Generative-AI store policies (App Store 1.2 / Play AI-content):
/// a one-line disclaimer shown under the chat/agent screens, and a "Report this response" action
/// that opens a pre-filled `mailto:`. Pure + testable; the SwiftUI views just open the URL.
/// Twin of Android `SupportContact`.
public enum SupportContact {
    /// Dedicated support / content-report address (ships in the app binary).
    public static let reportEmail = "quenderin@aulenor.com"

    /// Hosted privacy policy (Cloudflare Pages, apex domain). Source: website/privacy.html.
    public static let privacyPolicyURL = "https://quenderin.org/privacy"

    /// The open-source home — Quenderin's full source, issues, and discussions.
    public static let githubURL = "https://github.com/alikatgh/quenderin"

    /// The marketing site — every in-app link except GitHub lands on a quenderin.org page,
    /// so the website (not a popup menu) is where people learn the product.
    public static let websiteURL = "https://quenderin.org"

    /// Hosted help page (FAQ + how to reach us). Source: website/help.html.
    public static let helpURL = "https://quenderin.org/help"

    /// Hosted human-readable changelog. Source: website/changelog.html.
    public static let changelogURL = "https://quenderin.org/changelog"

    /// Shown beneath chat + agent output so users know responses are unfiltered, on-device AI.
    public static let aiDisclaimer =
        "Responses are AI-generated on-device and may be inaccurate or objectionable."

    /// Shown on a chat response that trips `SafetyBlocklist` — a non-blocking, on-device
    /// "minimize risk" safeguard for the Generative-AI policies. Kept identical to Android
    /// `SupportContact.FLAGGED_OUTPUT_NOTICE` (cross-platform parity).
    public static let flaggedOutputNotice =
        "This response mentions a sensitive action (e.g. payments, deletion, or credentials). It isn't filtered — verify before acting, and report if inappropriate."

    /// A `mailto:` URL pre-filled to report an AI response. `context` is "chat" or "agent".
    /// All user/model text is percent-encoded so arbitrary output can't break the URL.
    public static func reportMailto(reportedText: String, context: String = "chat") -> URL? {
        let snippet = reportedText.count > 1000 ? String(reportedText.prefix(1000)) + "…" : reportedText
        let subject = "Quenderin — report AI \(context) response"
        let body = """
        I'm reporting this AI-generated response as inappropriate:

        "\(snippet)"

        Why is it inappropriate? (optional):
        """
        // urlQueryAllowed keeps sub-delimiters (& + = ? #) literal — strip them so model output
        // containing them can't corrupt the query.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let s = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let b = body.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "mailto:\(reportEmail)?subject=\(s)&body=\(b)")
    }
}
