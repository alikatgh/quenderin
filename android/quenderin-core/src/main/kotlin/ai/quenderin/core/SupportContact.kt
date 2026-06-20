package ai.quenderin.core

import java.net.URLEncoder

/**
 * Content-safety surface for the Generative-AI store policies (Play AI-content / App Store 1.2):
 * a one-line disclaimer shown under the chat/agent screens, and a "Report this response" action
 * that opens a pre-filled `mailto:`. Pure + testable; the Compose UI opens the resulting URI via
 * an ACTION_SENDTO intent. Twin of iOS `SupportContact`.
 */
object SupportContact {
    /** Dedicated support / content-report address (ships in the app binary). */
    const val REPORT_EMAIL = "quenderin@aulenor.com"

    /** Hosted privacy policy (Cloudflare Pages, apex domain). Source: website/privacy.html. */
    const val PRIVACY_POLICY_URL = "https://quenderin.org/privacy"

    /** Shown beneath chat + agent output so users know responses are unfiltered, on-device AI. */
    const val AI_DISCLAIMER =
        "Responses are AI-generated on-device and may be inaccurate or objectionable."

    /** Shown on a chat response that trips [SafetyBlocklist] — a non-blocking, on-device
     *  "minimize risk" safeguard for the Generative-AI policies. Kept identical to iOS
     *  `SupportContact.flaggedOutputNotice` (cross-platform parity). */
    const val FLAGGED_OUTPUT_NOTICE =
        "This response mentions a sensitive action (e.g. payments, deletion, or credentials). It isn't filtered — verify before acting, and report if inappropriate."

    /** A `mailto:` URI pre-filled to report an AI response. [context] is "chat" or "agent". All
     *  user/model text is percent-encoded so arbitrary output can't break the URI. */
    fun reportMailtoUri(reportedText: String, context: String = "chat"): String {
        val snippet = if (reportedText.length > 1000) reportedText.take(1000) + "…" else reportedText
        val subject = enc("Quenderin — report AI $context response")
        val body = enc(
            "I'm reporting this AI-generated response as inappropriate:\n\n" +
                "\"$snippet\"\n\nWhy is it inappropriate? (optional):\n",
        )
        return "mailto:$REPORT_EMAIL?subject=$subject&body=$body"
    }

    // URLEncoder emits application/x-www-form-urlencoded (space -> '+'); mailto clients want %20.
    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
}
