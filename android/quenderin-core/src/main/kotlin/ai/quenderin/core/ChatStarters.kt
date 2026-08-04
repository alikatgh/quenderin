package ai.quenderin.core

/**
 * First-message chips for an empty chat. Tuned for **1–4B on-device** models: short prompts,
 * concrete tasks. Twin of iOS `ChatStarters` — keep titles/prompts in sync when editing either.
 */
data class ChatStarter(
    val id: String,
    /** Short chip label. */
    val title: String,
    /** Full prompt inserted/sent when the chip is tapped. */
    val prompt: String,
)

object ChatStarters {
    /** Default pack for private offline chat. Order = most likely to delight on first try. */
    val offlineChat: List<ChatStarter> = listOf(
        ChatStarter(
            id = "summarize",
            title = "Summarize",
            prompt = "Summarize the following in 3 short bullet points. If I haven't pasted anything yet, ask me what to summarize:\n\n",
        ),
        ChatStarter(
            id = "rewrite",
            title = "Rewrite clearly",
            prompt = "Rewrite this so it's clearer and more concise, without changing the meaning:\n\n",
        ),
        ChatStarter(
            id = "translate",
            title = "Translate",
            prompt = "Translate the following into Spanish. Keep names and numbers unchanged:\n\n",
        ),
        ChatStarter(
            id = "brainstorm",
            title = "Brainstorm",
            prompt = "Give me 5 practical dinner ideas that use eggs and rice. One line each.",
        ),
        ChatStarter(
            id = "explain",
            title = "Explain simply",
            prompt = "Explain jet lag like I'm 12 years old — short paragraphs, no jargon.",
        ),
        ChatStarter(
            id = "math",
            title = "Quick math",
            prompt = "What is 17% of 240? Show the arithmetic in one line.",
        ),
        ChatStarter(
            id = "email",
            title = "Draft email",
            prompt = "Draft a short, polite email declining a meeting because of a schedule conflict. Warm but firm, under 80 words.",
        ),
        ChatStarter(
            id = "checklist",
            title = "Packing list",
            prompt = "Make a packing checklist for a 3-day weekend city trip. Group by: bag, clothes, tech, documents.",
        ),
    )
}
