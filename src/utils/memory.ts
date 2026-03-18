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
        // In containers, cgroup limits may be lower than physical RAM.
        // Check cgroup first and cap the result accordingly.
        const cgroupLimit = cgroupMemoryLimitBytes();

        let available: number;
        if (process.platform === 'darwin') {
            available = macosAvailableBytes();
        } else if (process.platform === 'linux') {
            available = linuxAvailableBytes();
        } else if (process.platform === 'win32') {
            available = windowsAvailableBytes();
        } else {
            available = os.freemem();
        }

        // If cgroup limit is set, don't report more available than the container allows
        if (cgroupLimit > 0) {
            const cgroupUsage = cgroupMemoryUsageBytes();
            const cgroupFree = Math.max(0, cgroupLimit - cgroupUsage);
            return Math.min(available, cgroupFree);
        }

        return available;
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

// ---------------------------------------------------------------------------
// Container — cgroup v1/v2 memory limits
// ---------------------------------------------------------------------------

/** Returns the cgroup memory limit in bytes, or 0 if not in a container / not detectable */
function cgroupMemoryLimitBytes(): number {
    if (process.platform !== 'linux') return 0;
    try {
        // cgroup v2 (unified hierarchy)
        const v2 = fs.readFileSync('/sys/fs/cgroup/memory.max', 'utf8').trim();
        if (v2 !== 'max') return parseInt(v2, 10) || 0;
    } catch { /* not cgroup v2 */ }
    try {
        // cgroup v1
        const v1 = fs.readFileSync('/sys/fs/cgroup/memory/memory.limit_in_bytes', 'utf8').trim();
        const limit = parseInt(v1, 10);
        // Kernel returns a huge number (close to max int64) when unlimited
        if (limit > 0 && limit < os.totalmem() * 2) return limit;
    } catch { /* not cgroup v1 */ }
    return 0;
}

/** Returns the current cgroup memory usage in bytes, or 0 if not detectable */
function cgroupMemoryUsageBytes(): number {
    if (process.platform !== 'linux') return 0;
    try {
        // cgroup v2
        return parseInt(fs.readFileSync('/sys/fs/cgroup/memory.current', 'utf8').trim(), 10) || 0;
    } catch { /* not cgroup v2 */ }
    try {
        // cgroup v1
        return parseInt(fs.readFileSync('/sys/fs/cgroup/memory/memory.usage_in_bytes', 'utf8').trim(), 10) || 0;
    } catch { /* not cgroup v1 */ }
    return 0;
}

// ---------------------------------------------------------------------------
// Windows — query WMI for free physical memory
// ---------------------------------------------------------------------------

function windowsAvailableBytes(): number {
    // Try PowerShell first — works on Windows 8+ and is the only option on
    // Windows 11 22H2+ where wmic has been removed.
    try {
        const out = execSync(
            'powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory"',
            { encoding: 'utf8', timeout: 5000 }
        );
        const kb = parseInt(out.trim(), 10);
        if (Number.isFinite(kb) && kb > 0) return kb * 1024;
    } catch { /* PowerShell unavailable — fall through to wmic */ }

    // Legacy fallback: wmic works on Windows 7–10 (deprecated, removed in Win11 22H2)
    const out = execSync(
        'wmic OS get FreePhysicalMemory /value',
        { encoding: 'utf8', timeout: 5000 }
    );
    const m = out.match(/FreePhysicalMemory=(\d+)/);
    if (!m) throw new Error('FreePhysicalMemory not found in wmic output');
    // wmic reports in KB
    return parseInt(m[1], 10) * 1024;
}
