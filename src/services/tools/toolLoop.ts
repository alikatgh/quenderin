/**
 * Tool Loop — Parses LLM output for tool calls, executes them, and re-prompts
 *
 * Uses XML fallback parsing (since small local models can't reliably output JSON tool calls).
 *
 * NOTE: only the parse/strip/format helpers are live — `generalChat` runs the loop inline
 * (`llm.service.ts`) and the WS layer does stream-level suppression. There is no shared loop fn.
 */
import type { ToolCall, ToolResult } from './registry.js';
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

/** Check if LLM output contains a COMPLETE tool call tag pair.
 *  Must agree with parseToolCalls (which needs the closing tag): matching only the opening `<tool_call>`
 *  returned true for unclosed/truncated output, so the outer loop would treat it as having tool calls
 *  while parseToolCalls extracted none — spinning on unexecutable output (deep-hunt). */
export function hasToolCalls(text: string): boolean {
    return /<tool_call>[\s\S]*?<\/tool_call>/i.test(text);
}

/** Strip tool call XML from the response text, keeping the rest */
export function stripToolCalls(text: string): string {
    return text
        .replace(/<tool_call>[\s\S]*?<\/tool_call>/gi, '')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
}

/** Suppress complete XML calls while preserving literal tags and unfinished examples. */
export class ToolCallStreamFilter {
    private pending = '';

    feed(chunk: string): string {
        this.pending += chunk;
        let visible = '';
        const open = '<tool_call>';
        const name = '<name>';
        const close = '</tool_call>';
        while (this.pending) {
            const start = this.pending.search(/<tool_call>/i);
            if (start < 0) {
                let held = Math.min(open.length - 1, this.pending.length);
                while (held > 0 && !open.startsWith(this.pending.slice(-held).toLowerCase())) held--;
                const end = this.pending.length - held;
                visible += this.pending.slice(0, end);
                this.pending = this.pending.slice(end);
                break;
            }

            visible += this.pending.slice(0, start);
            this.pending = this.pending.slice(start);
            const body = this.pending.slice(open.length);
            const next = body.trimStart().slice(0, name.length).toLowerCase();
            if (next !== name) {
                if (name.startsWith(next)) break;
            } else {
                const closeIndex = body.search(/<\/tool_call>/i);
                if (closeIndex < 0) break;
                const end = open.length + closeIndex + close.length;
                const candidate = this.pending.slice(0, end);
                if (/^<tool_call>\s*<name>[^<>]*<\/name>\s*<args>[\s\S]*?<\/args>\s*<\/tool_call>$/i.test(candidate)) {
                    this.pending = this.pending.slice(end);
                    continue;
                }
            }
            visible += this.pending.slice(0, open.length);
            this.pending = body;
        }
        return visible;
    }

    flush(): string {
        const tail = this.pending;
        this.pending = '';
        return tail;
    }
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

