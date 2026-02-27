/**
 * Tool Handlers — Execute tool calls and return results
 */
import os from 'os';
import { safeCalculate, CalculatorError } from './calculator.js';
import { ToolCall, ToolResult, AVAILABLE_TOOLS } from './registry.js';
import logger from '../../utils/logger.js';

/** Execute a single tool call */
export function executeTool(call: ToolCall): ToolResult {
    // Validate tool exists
    const toolDef = AVAILABLE_TOOLS.find(t => t.name === call.tool);
    if (!toolDef) {
        return { tool: call.tool, success: false, result: '', error: `Unknown tool: ${call.tool}` };
    }

    try {
        switch (call.tool) {
            case 'calculator': {
                const expression = String(call.args.expression ?? '');
                if (!expression) {
                    return { tool: 'calculator', success: false, result: '', error: 'Missing expression parameter' };
                }
                const result = safeCalculate(expression);
                return { tool: 'calculator', success: true, result: String(result) };
            }

            case 'datetime': {
                const now = new Date();
                const result = JSON.stringify({
                    iso: now.toISOString(),
                    local: now.toLocaleString(),
                    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
                    unix: Math.floor(now.getTime() / 1000),
                });
                return { tool: 'datetime', success: true, result };
            }

            case 'system_info': {
                const result = JSON.stringify({
                    platform: os.platform(),
                    arch: os.arch(),
                    cpus: os.cpus().length,
                    totalRamGb: (os.totalmem() / (1024 ** 3)).toFixed(1),
                    freeRamGb: (os.freemem() / (1024 ** 3)).toFixed(1),
                    hostname: os.hostname(),
                    uptime: `${(os.uptime() / 3600).toFixed(1)} hours`,
                });
                return { tool: 'system_info', success: true, result };
            }

            default:
                return { tool: call.tool, success: false, result: '', error: `No handler for tool: ${call.tool}` };
        }
    } catch (err) {
        const message = err instanceof CalculatorError ? err.message : 'Tool execution failed';
        logger.error(`[Tool] Error executing ${call.tool}:`, err);
        return { tool: call.tool, success: false, result: '', error: message };
    }
}

/** Execute multiple tool calls (with safety limits) */
export function executeToolCalls(calls: ToolCall[]): ToolResult[] {
    const MAX_CALLS = 5;
    const limited = calls.slice(0, MAX_CALLS);
    return limited.map(executeTool);
}
