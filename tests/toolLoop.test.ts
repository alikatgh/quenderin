import { describe, it, expect } from 'vitest';
import { hasToolCalls } from '../src/services/tools/toolLoop.js';

/**
 * Regression: hasToolCalls matched only the OPENING `<tool_call>`, so an unclosed/truncated tag
 * returned true while parseToolCalls (which needs the closing tag) extracted nothing — the outer
 * loop would treat the output as having tool calls and spin on unexecutable text. It must require a
 * complete pair, agreeing with the parser.
 */
describe('hasToolCalls — requires a complete tag pair', () => {
    it('is true only for a closed <tool_call>...</tool_call>', () => {
        expect(hasToolCalls('<tool_call>{"tool":"x"}</tool_call>')).toBe(true);
        expect(hasToolCalls('prose <tool_call>\n{"tool":"calc"}\n</tool_call> more')).toBe(true);
    });

    it('is false for an unclosed/malformed opening tag', () => {
        expect(hasToolCalls('<tool_call>{"tool":"x"}')).toBe(false);   // truncated, no close
        expect(hasToolCalls('here is some <tool_call without a real tag')).toBe(false);
        expect(hasToolCalls('just plain text, no tools')).toBe(false);
    });
});
