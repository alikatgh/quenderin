/**
 * Tool Loop — Parses LLM output for tool calls, executes them, and re-prompts
 *
 * Uses XML fallback parsing (since small local models can't reliably output JSON tool calls).
 * Maximum 3 iterations to prevent infinite loops.
 */
import { ToolCall, ToolResult } from './registry.js';
import { executeToolCalls } from './handlers.js';
import logger from '../../utils/logger.js';

const MAX_ITERATIONS = 3;

/** Parse tool calls from LLM output using XML tags */
export function parseToolCalls(text: string): ToolCall[] {
    const calls: ToolCall[] = [];
    const regex = /<tool_call>\s*<name>([\s\S]*?)<\/name>\s*<args>([\s\S]*?)<\/args>\s*<\/tool_call>/gi;

    let match;
    while ((match = regex.exec(text)) !== null) {
        const toolName = match[1].trim();
        const argsStr = match[2].trim();

        try {
            const args = argsStr ? JSON.parse(argsStr) : {};
            calls.push({ tool: toolName, args });
        } catch {
            // Try to extract key-value pairs manually
            logger.warn(`[ToolLoop] Failed to parse JSON args for ${toolName}: ${argsStr}`);
            calls.push({ tool: toolName, args: {} });
        }
    }

    return calls;
}

/** Check if LLM output contains any tool call tags */
export function hasToolCalls(text: string): boolean {
    return /<tool_call>/i.test(text);
}

/** Strip tool call XML from the response text, keeping the rest */
export function stripToolCalls(text: string): string {
    return text
        .replace(/<tool_call>[\s\S]*?<\/tool_call>/gi, '')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
}

/** Format tool results for injecting back into the conversation */
export function formatToolResults(results: ToolResult[]): string {
    return results.map(r => {
        if (r.success) {
            return `[Tool: ${r.tool}] Result: ${r.result}`;
        } else {
            return `[Tool: ${r.tool}] Error: ${r.error}`;
        }
    }).join('\n');
}

/**
 * Run the tool loop — execute tool calls from LLM output and generate a follow-up.
 *
 * @param initialResponse - The LLM's first response (may contain tool calls)
 * @param promptWithResults - Function to re-prompt the LLM with tool results
 * @returns Final text response (with tool calls stripped)
 */
export async function runToolLoop(
    initialResponse: string,
    promptWithResults: (toolResultContext: string) => Promise<string>
): Promise<{ finalText: string; toolResults: ToolResult[] }> {
    let currentText = initialResponse;
    const allResults: ToolResult[] = [];

    for (let i = 0; i < MAX_ITERATIONS; i++) {
        if (!hasToolCalls(currentText)) {
            break;
        }

        const calls = parseToolCalls(currentText);
        if (calls.length === 0) break;

        logger.log(`[ToolLoop] Iteration ${i + 1}: executing ${calls.length} tool call(s)`);
        const results = executeToolCalls(calls);
        allResults.push(...results);

        // Re-prompt the LLM with tool results
        const resultContext = formatToolResults(results);
        try {
            currentText = await promptWithResults(resultContext);
        } catch (err) {
            logger.error('[ToolLoop] Re-prompt failed:', err);
            break;
        }
    }

    return {
        finalText: stripToolCalls(currentText),
        toolResults: allResults,
    };
}
