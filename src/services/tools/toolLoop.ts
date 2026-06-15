/**
 * Tool Loop — Parses LLM output for tool calls, executes them, and re-prompts
 *
 * Uses XML fallback parsing (since small local models can't reliably output JSON tool calls).
 *
 * NOTE: only the parse/strip/format helpers are live — `generalChat` runs the loop inline
 * (`llm.service.ts`) and the WS layer does stream-level suppression. There is no shared loop fn.
 */
import { ToolCall, ToolResult } from './registry.js';
import logger from '../../utils/logger.js';

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

