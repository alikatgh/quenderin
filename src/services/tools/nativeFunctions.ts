/**
 * Native function-calling bridge — adapts AVAILABLE_TOOLS to node-llama-cpp's
 * `session.prompt(msg, { functions })` API.
 *
 * Why this exists: the XML `<tool_call>` protocol (toolLoop.ts) asks a small model to emit a
 * fragile text format, then scrapes it with regex and re-prompts manually. node-llama-cpp's
 * native functions instead constrain the decoder itself (the model cannot emit a malformed
 * call), run the call/result loop inside ONE prompt() invocation, and keep function syntax
 * out of the text stream entirely — no stream-level suppression needed.
 *
 * The XML path is NOT deleted: it remains the fallback for bindings without
 * `defineChatSessionFunction` and stays pinned by the cross-platform tool-format parity
 * vectors (the mobile twins still speak XML).
 *
 * All execution still funnels through `executeTool` — path guards, secret-store denials, and
 * every other safety property live in exactly one place (handlers.ts), whichever protocol
 * carried the call.
 */
import { AVAILABLE_TOOLS, maxToolCallsPerResponse, ToolParameter } from './registry.js';
import { executeTool } from './handlers.js';
import logger from '../../utils/logger.js';

/** Convert a registry parameter list to the GBNF-JSON object schema node-llama-cpp expects.
 *  Every current tool parameter is required, so the schema lists all properties plainly;
 *  parameterless tools pass no schema at all. */
function paramsSchema(parameters: ToolParameter[]): Record<string, unknown> | undefined {
    if (parameters.length === 0) return undefined;
    return {
        type: 'object',
        properties: Object.fromEntries(
            parameters.map(p => [p.name, { type: p.type, description: p.description }])
        ),
    };
}

/**
 * Build a fresh functions map for ONE prompt() invocation.
 *
 * Fresh per invocation because the map carries the per-response call counter: Q-639 requires the
 * executor to ENFORCE the same per-response cap the (XML) prompt advertises. The native loop is
 * driven by the library, so the cap is enforced in the handler — past the cap, the model receives
 * an explicit "limit reached" error result and finishes with what it has.
 *
 * @param defineChatSessionFunction the (dynamically imported) node-llama-cpp helper
 * @param onToolCall               optional observer, fired once per executed call (metrics/logs)
 */
export function buildNativeChatFunctions(
    defineChatSessionFunction: (def: unknown) => unknown,
    onToolCall?: (tool: string) => void
): Record<string, unknown> {
    let callsThisResponse = 0;
    const cap = maxToolCallsPerResponse();
    // Small models LOOP: the same call with the same args, over and over, burning the whole token
    // budget and ending the response empty (live-caught on a 1B via scripts/smoke_llm_engine.ts).
    // Two defenses, both visible to the model rather than silent:
    //  • identical repeat → the memoized result is returned WITHOUT re-execution or counting
    //    against the cap, prefixed with an explicit "you already called this";
    //  • past the cap → a terminal plain-string directive to answer now (an { error } object read
    //    as "retryable" to some models; a definitive instruction stops the loop sooner).
    const seenCalls = new Map<string, unknown>();
    const functions: Record<string, unknown> = {};
    for (const tool of AVAILABLE_TOOLS) {
        functions[tool.name] = defineChatSessionFunction({
            description: tool.description,
            params: paramsSchema(tool.parameters),
            handler: async (params: Record<string, unknown> | undefined) => {
                const callKey = `${tool.name}:${JSON.stringify(params ?? {})}`;
                if (seenCalls.has(callKey)) {
                    // Return the memoized result VERBATIM, like any idempotent API. The first
                    // version returned an instructional "you already called this…" paragraph —
                    // and the small model copied the lecture into its user-visible answer
                    // (live-caught). Tool results must contain results, never meta-commentary.
                    logger.debug(`[Tool] Repeated identical native call to ${tool.name} — returning memoized result.`);
                    return seenCalls.get(callKey);
                }
                callsThisResponse++;
                if (callsThisResponse > cap) {
                    // Same visible-not-silent shape as Q-293/Q-408: the model learns WHY the
                    // call didn't run instead of receiving a mystery failure. Kept SHORT: small
                    // models parrot tool results into their user-visible answer, so every word
                    // here is a word that can leak (live-caught — a longer directive did).
                    logger.warn(`[Tool] Native call to ${tool.name} exceeded the per-response cap (${cap}) — refused.`);
                    return 'Tool limit reached. Answer now.';
                }
                onToolCall?.(tool.name);
                const result = await executeTool({ tool: tool.name, args: params ?? {} });
                // Plain string on success (models handle it best); structured error otherwise.
                const out = result.success ? result.result : { error: result.error ?? 'Tool execution failed' };
                logger.debug(`[Tool] ${tool.name}(${JSON.stringify(params ?? {})}) → ${JSON.stringify(out).slice(0, 300)}`);
                seenCalls.set(callKey, out);
                return out;
            },
        });
    }
    return functions;
}
