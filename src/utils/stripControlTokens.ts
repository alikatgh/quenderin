/**
 * Strip LLM control/special tokens from generated text.
 * Ported from off-grid-mobile's messageContent utility.
 * Prevents garbled output when model emits template markers.
 */

const CONTROL_TOKEN_PATTERNS: RegExp[] = [
    // ChatML markers
    /<\|im_start\|>\s*(?:system|assistant|user|tool)?\s*\n?/gi,
    /<\|im_end\|>\s*\n?/gi,
    // Llama/Phi end-of-turn
    /<\|end\|>/gi,
    /<\|eot_id\|>/gi,
    /<\|end_of_text\|>/gi,
    // Legacy EOS
    /<\/s>/gi,
    // Tool call XML blocks (strip entire block)
    /<tool_call>[\s\S]*?<\/tool_call>\s*/g,
    // Stray BOS
    /<s>/gi,
    // Header tokens from Llama 3+
    /<\|start_header_id\|>[\s\S]*?<\|end_header_id\|>\s*\n?/gi,
];

export function stripControlTokens(content: string): string {
    return CONTROL_TOKEN_PATTERNS.reduce(
        (result, pattern) => result.replace(pattern, ''),
        content
    ).trim();
}
