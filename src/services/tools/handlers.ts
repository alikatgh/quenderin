/**
 * Tool Handlers — Execute tool calls and return results
 */
import os from 'os';
import fs from 'fs';
import path from 'path';
import { availableMemBytes } from '../../utils/memory.js';
import { safeCalculate, CalculatorError } from './calculator.js';
import { runUnitConversion } from './unitConvert.js';
import { ToolCall, ToolResult, AVAILABLE_TOOLS } from './registry.js';
import { getSharedMemoryService } from '../memory.service.js';
import logger from '../../utils/logger.js';

const MAX_FILE_READ_BYTES = 8_000;

/**
 * Safety check: ensure a resolved path stays inside the user's home dir.
 * Prevents path-traversal attacks via ../../ sequences.
 */
function isInsideHome(filePath: string): boolean {
    const home = os.homedir();
    const resolved = path.resolve(filePath.replace(/^~/, home));
    return resolved.startsWith(home + path.sep) || resolved === home;
}

// Well-known credential/secret stores that live INSIDE $HOME. `read_file`'s path comes from
// untrusted model output (prompt injection), so home-containment alone is not enough — ~/.ssh,
// ~/.aws, browser cookie DBs, token dotfiles etc. are all inside home and would otherwise be
// readable into the model context / chat UI. Deny them. (Security audit HIGH, handlers.ts read_file.)
const SENSITIVE_DIR_PREFIXES = [
    '.ssh', '.aws', '.gnupg', '.gpg', '.azure', '.kube', '.docker', '.quenderin',
    '.config/gcloud', '.config/gh', '.config/google-chrome', '.config/chromium',
    '.mozilla', '.electrum', '.ethereum', '.bitcoin',
    'library/keychains',
    'library/application support/google/chrome',
    'library/application support/chromium',
    'library/application support/firefox',
];
const SENSITIVE_BASENAMES = new Set([
    '.netrc', '.npmrc', '.pypirc', '.git-credentials', '.dockercfg',
    '.bash_history', '.zsh_history', '.python_history', '.mysql_history',
    'credentials', '.env',
]);
// Private keys, cert/key material, env files, and anything that names itself a secret/credential.
const SENSITIVE_NAME_PATTERN =
    /^(id_(rsa|dsa|ecdsa|ed25519)|.*\.(pem|key|p12|pfx|keystore)|\.env(\..+)?|.*secret.*|.*credential.*)$/i;

/**
 * True if `realResolved` (an absolute, symlink-resolved path already known to be inside $HOME) names
 * a known secret store. Compared case-insensitively (macOS/Windows FS), against a path relative to
 * home, so `.SSH` or a nested `.config/gcloud/...` is still caught.
 */
function isSensitivePath(realResolved: string): boolean {
    const home = os.homedir();
    const rel = path.relative(home, realResolved).split(path.sep).join('/').toLowerCase();
    if (rel === '' || rel.startsWith('..')) return false; // not under home — caller already gates this
    for (const prefix of SENSITIVE_DIR_PREFIXES) {
        if (rel === prefix || rel.startsWith(prefix + '/')) return true;
    }
    const base = path.basename(realResolved).toLowerCase();
    return SENSITIVE_BASENAMES.has(base) || SENSITIVE_NAME_PATTERN.test(base);
}

/** Execute a single tool call */
export async function executeTool(call: ToolCall): Promise<ToolResult> {
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

            case 'unit_convert': {
                const expression = String(call.args.expression ?? '').trim();
                if (!expression) {
                    return { tool: 'unit_convert', success: false, result: '', error: 'Missing expression parameter' };
                }
                // runUnitConversion never throws — it degrades garbage input to a hint —
                // so a successful tool result always carries a human-readable string.
                const result = runUnitConversion(expression);
                return { tool: 'unit_convert', success: true, result };
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
                // Deny known secret stores BEFORE touching the filesystem — so a prompt-injected
                // read can't exfiltrate credentials, and can't even probe whether they exist.
                if (isSensitivePath(resolved)) {
                    return { tool: 'read_file', success: false, result: '', error: 'Access denied: this is a sensitive credential/secret location and cannot be read by the assistant.' };
                }
                if (!fs.existsSync(resolved)) {
                    return { tool: 'read_file', success: false, result: '', error: `File not found: ${resolved}` };
                }
                // Defeat symlink escape: follow symlinks to the real target and re-check
                // containment. A lexical (path.resolve) check alone lets a symlink that
                // lives inside $HOME point at an out-of-home file (e.g. ~/link -> /etc/passwd)
                // slip past the prefix check.
                let realResolved: string;
                try {
                    realResolved = fs.realpathSync(resolved);
                } catch {
                    return { tool: 'read_file', success: false, result: '', error: `File not found: ${resolved}` };
                }
                if (!isInsideHome(realResolved)) {
                    return { tool: 'read_file', success: false, result: '', error: 'Access denied: path resolves (via symlink) to a location outside your home directory.' };
                }
                // Re-check after symlink resolution: a benign-looking name inside $HOME could be a
                // symlink to ~/.ssh/id_rsa. The real target must not be a secret store either.
                if (isSensitivePath(realResolved)) {
                    return { tool: 'read_file', success: false, result: '', error: 'Access denied: path resolves (via symlink) to a sensitive credential/secret location.' };
                }
                const stat = fs.statSync(realResolved);
                if (!stat.isFile()) {
                    return { tool: 'read_file', success: false, result: '', error: 'Path is a directory, not a file.' };
                }
                // Read up to MAX_FILE_READ_BYTES to protect context window
                const buf = Buffer.alloc(MAX_FILE_READ_BYTES);
                const fd = fs.openSync(realResolved, 'r');
                // try/finally so a readSync failure (EIO on a network mount, a device file, a perms
                // change between stat and read) can't leak the fd — repeated failures would exhaust the
                // process fd table (EMFILE) and take down the server (deep-hunt HIGH).
                let bytesRead: number;
                try {
                    bytesRead = fs.readSync(fd, buf, 0, MAX_FILE_READ_BYTES, 0);
                } finally {
                    fs.closeSync(fd);
                }
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
                const title = String(call.args.title ?? '');
                const content = String(call.args.content ?? '');
                const saved = await getSharedMemoryService().saveNote(title, content);
                if ('error' in saved) {
                    return { tool: 'note_save', success: false, result: '', error: saved.error };
                }
                return { tool: 'note_save', success: true, result: `Note saved to ${saved.path}` };
            }

            case 'note_list': {
                const notes = await getSharedMemoryService().listNotesForTool();
                if (notes.length === 0) {
                    return { tool: 'note_list', success: true, result: 'No notes saved yet.' };
                }
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
export async function executeToolCalls(calls: ToolCall[]): Promise<ToolResult[]> {
    const MAX_CALLS = 5;
    const limited = calls.slice(0, MAX_CALLS);
    const results: ToolResult[] = [];
    for (const call of limited) {
        results.push(await executeTool(call));
    }
    return results;
}
