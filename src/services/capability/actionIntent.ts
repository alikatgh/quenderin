/**
 * Deterministic "this message is really a COMPUTER TASK" detector — the TypeScript twin of Swift
 * `ActionIntent` and Kotlin `ai.quenderin.core.ActionIntent` (IDENTICAL pattern strings; the three
 * platforms run the same fixtures in their checks).
 *
 * Used by the governed agent loop's zero-action guard: a goal that reads as an operate-the-computer
 * request must not be answered with a bare "Done" over zero capability calls (the weak-local-model
 * "fluent lie"). Conservative by design (precision over recall): a missed detection costs nothing —
 * the loop just doesn't nudge — while a false positive nags.
 */

/** Regexes over the lowercased message. IDENTICAL strings in the Swift/Kotlin twins. */
const PATTERNS: RegExp[] = [
    /\b(open|launch|start|quit|close)\b.*\b(browser|safari|chrome|firefox|mail|finder|app|application)\b/,
    /\b(write|send|compose|draft)\b.*\b(e-?mail|message)\b/,
    /\b(organize|organise|clean|sort|tidy)\b.*\b(files?|folders?|desktop|downloads|documents)\b/,
    /\b(move|rename|trash|copy)\b.*\b(files?|folders?)\b/,
    /\brun\b.*\bshortcut/,
    /\b(create|make)\b.*\b(folder|directory)\b/,
];

/** True when the text reads as an operate-the-computer request rather than a question. */
export function looksLikeComputerTask(text: string): boolean {
    const lowered = text.toLowerCase();
    return PATTERNS.some(p => p.test(lowered));
}
