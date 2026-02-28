/**
 * memory.ts — Platform-aware available memory detection.
 *
 * On macOS, `os.freemem()` only returns truly idle pages (~200 MB on a busy
 * system), ignoring the large pool of inactive / speculative / purgeable pages
 * that the kernel can reclaim instantly.  This makes the app think no models
 * fit when there is actually plenty of headroom.
 *
 * This module provides `availableMemBytes()` which mirrors what macOS Activity
 * Monitor calls "Available Memory" and what Linux reports as `MemAvailable`.
 */
import { execSync } from 'child_process';
import fs from 'fs';
import os from 'os';

/**
 * Returns the number of bytes that are *readily* available for a new process.
 *
 * - **macOS**: parses `vm_stat` and sums free + inactive + speculative +
 *   purgeable pages multiplied by the VM page size.
 * - **Linux**: reads `MemAvailable` from `/proc/meminfo`.
 * - **Fallback**: `os.freemem()` (used on Windows and on error).
 */
export function availableMemBytes(): number {
    try {
        if (process.platform === 'darwin') {
            return macosAvailableBytes();
        }
        if (process.platform === 'linux') {
            return linuxAvailableBytes();
        }
    } catch {
        // fall through to safe fallback
    }
    return os.freemem();
}

// ---------------------------------------------------------------------------
// macOS — parse `vm_stat`
// ---------------------------------------------------------------------------

function macosAvailableBytes(): number {
    const out = execSync('vm_stat', { encoding: 'utf8', timeout: 2000 });

    // First line: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
    const pageSizeMatch = out.match(/page size of (\d+) bytes/);
    const pageSize = pageSizeMatch ? parseInt(pageSizeMatch[1], 10) : 16384;

    const pages = (label: string): number => {
        const m = out.match(new RegExp(`${label}:\\s+(\\d+)`));
        return m ? parseInt(m[1], 10) : 0;
    };

    const available =
        (pages('Pages free') +
            pages('Pages inactive') +
            pages('Pages speculative') +
            pages('Pages purgeable')) *
        pageSize;

    // Sanity: never return more than total RAM or less than 0
    return Math.max(0, Math.min(available, os.totalmem()));
}

// ---------------------------------------------------------------------------
// Linux — read /proc/meminfo
// ---------------------------------------------------------------------------

function linuxAvailableBytes(): number {
    const meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
    const m = meminfo.match(/MemAvailable:\s+(\d+)\s+kB/);
    if (!m) throw new Error('MemAvailable not found in /proc/meminfo');
    return parseInt(m[1], 10) * 1024;
}
