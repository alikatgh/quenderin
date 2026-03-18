/**
 * Tool Handlers — Execute tool calls and return results
 */
import os from 'os';
import fs from 'fs';
import path from 'path';
import { availableMemBytes } from '../../utils/memory.js';
import { safeCalculate, CalculatorError } from './calculator.js';
import { ToolCall, ToolResult, AVAILABLE_TOOLS } from './registry.js';
import logger from '../../utils/logger.js';

const NOTES_DIR = path.join(os.homedir(), '.quenderin', 'notes');
const MAX_FILE_READ_BYTES = 8_000;

function ensureNotesDir(): void {
    if (!fs.existsSync(NOTES_DIR)) {
        fs.mkdirSync(NOTES_DIR, { recursive: true });
    }
}

/**
 * Safety check: ensure a resolved path stays inside the user's home dir.
 * Prevents path-traversal attacks via ../../ sequences.
 */
function isInsideHome(filePath: string): boolean {
    const home = os.homedir();
    const resolved = path.resolve(filePath.replace(/^~/, home));
    return resolved.startsWith(home + path.sep) || resolved === home;
}

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
                    freeRamGb: (availableMemBytes() / (1024 ** 3)).toFixed(1),
                    hostname: os.hostname(),
                    uptime: `${(os.uptime() / 3600).toFixed(1)} hours`,
                });
                return { tool: 'system_info', success: true, result };
            }

            case 'read_file': {
                const rawPath = String(call.args.path ?? '').trim();
                if (!rawPath) {
                    return { tool: 'read_file', success: false, result: '', error: 'Missing path parameter' };
                }
                const expandedPath = rawPath.startsWith('~')
                    ? rawPath.replace(/^~/, os.homedir())
                    : rawPath;
                const resolved = path.resolve(expandedPath);
                if (!isInsideHome(resolved)) {
                    return { tool: 'read_file', success: false, result: '', error: 'Access denied: only files inside your home directory can be read.' };
                }
                if (!fs.existsSync(resolved)) {
                    return { tool: 'read_file', success: false, result: '', error: `File not found: ${resolved}` };
                }
                const stat = fs.statSync(resolved);
                if (!stat.isFile()) {
                    return { tool: 'read_file', success: false, result: '', error: 'Path is a directory, not a file.' };
                }
                // Read up to MAX_FILE_READ_BYTES to protect context window
                const buf = Buffer.alloc(MAX_FILE_READ_BYTES);
                const fd = fs.openSync(resolved, 'r');
                const bytesRead = fs.readSync(fd, buf, 0, MAX_FILE_READ_BYTES, 0);
                fs.closeSync(fd);
                const content = buf.slice(0, bytesRead).toString('utf8');
                const truncated = bytesRead === MAX_FILE_READ_BYTES && stat.size > MAX_FILE_READ_BYTES;
                return {
                    tool: 'read_file',
                    success: true,
                    result: JSON.stringify({
                        path: resolved,
                        sizeBytes: stat.size,
                        content,
                        truncated,
                        truncatedAt: truncated ? MAX_FILE_READ_BYTES : undefined,
                    }),
                };
            }

            case 'note_save': {
                const title = String(call.args.title ?? '').trim();
                const content = String(call.args.content ?? '').trim();
                if (!title) return { tool: 'note_save', success: false, result: '', error: 'Missing title parameter' };
                if (!content) return { tool: 'note_save', success: false, result: '', error: 'Missing content parameter' };
                // Sanitise title for use as filename
                const safeTitle = title.replace(/[^a-zA-Z0-9\s\-_]/g, '').trim().replace(/\s+/g, '_').slice(0, 80);
                ensureNotesDir();
                const notePath = path.join(NOTES_DIR, `${safeTitle}.md`);
                const header = `# ${title}\n_Saved: ${new Date().toISOString()}_\n\n`;
                fs.writeFileSync(notePath, header + content, 'utf8');
                return { tool: 'note_save', success: true, result: `Note saved to ${notePath}` };
            }

            case 'note_list': {
                ensureNotesDir();
                const files = fs.readdirSync(NOTES_DIR).filter(f => f.endsWith('.md'));
                if (files.length === 0) {
                    return { tool: 'note_list', success: true, result: 'No notes saved yet.' };
                }
                const notes = files.map(f => {
                    const notePath = path.join(NOTES_DIR, f);
                    const stat = fs.statSync(notePath);
                    let preview = '';
                    try {
                        const buf = Buffer.alloc(200);
                        const fd = fs.openSync(notePath, 'r');
                        const n = fs.readSync(fd, buf, 0, 200, 0);
                        fs.closeSync(fd);
                        preview = buf.slice(0, n).toString('utf8').replace(/\n/g, ' ').slice(0, 100);
                    } catch { /* non-fatal */ }
                    return { title: f.replace(/\.md$/, ''), modified: stat.mtime.toISOString(), preview };
                });
                return { tool: 'note_list', success: true, result: JSON.stringify(notes, null, 2) };
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
