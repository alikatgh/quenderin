/**
 * Extract the FIRST complete, balanced `{ … }` object from text, walking braces and skipping quoted
 * strings — NOT `indexOf('{')`..`lastIndexOf('}')`, which over-extends the moment the model emits a
 * second object or a trailing `}` in prose, making `JSON.parse` throw and silently dropping a valid
 * first action (audit H13; parity vector decision-h13-first-object). Mirrors the mobile
 * `AgentDecisionParser.firstJSONObject`. The ONE desktop implementation — the OS-agent loop and the
 * capability agent both import from here (two hand-kept copies had already begun to drift in style).
 */
export function firstJsonObject(text: string): string | null {
    const start = text.indexOf('{');
    if (start === -1) return null;
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
        const c = text[i];
        if (inString) {
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === '"') inString = false;
        } else if (c === '"') inString = true;
        else if (c === '{') depth++;
        else if (c === '}') { depth--; if (depth === 0) return text.substring(start, i + 1); }
    }
    return null;
}
