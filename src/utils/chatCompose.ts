/**
 * Fold attached documents into a chat message so the model actually sees them (Q-284). The WS `chat`
 * path used to drop `attachments` entirely — `generalChat` takes a plain string — so "ask about this
 * file" silently ignored the file. We prepend each document as a labeled block; the caller still
 * persists the CLEAN user message to the session (the user sees what they typed, the model sees the
 * docs + the message). Pure + deterministic, so it's unit-tested without a WS or a model.
 */
export function composeChatMessage(message: string, attachments: { name: string; content: string }[]): string {
    if (!attachments || attachments.length === 0) return message;
    const docs = attachments
        .map(a => `[Attached document: ${a.name}]\n${a.content}`)
        .join('\n\n');
    return message ? `${docs}\n\n${message}` : docs;
}
