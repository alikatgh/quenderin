import { promises as fsp } from 'fs';
import * as fsSync from 'fs';

/**
 * Write-temp-then-rename (r16): a bare `writeFile` onto the live path TRUNCATES the target the
 * moment it starts — a crash / ENOSPC / power loss mid-write leaves a half-file, and the guarded
 * readers then treat the store as empty (sessions, trajectories, telemetry silently gone).
 * `rename` within one directory is atomic on POSIX/NTFS, so the reader only ever sees the old
 * complete file or the new complete file. The temp name carries the pid so two processes can't
 * collide on it; a failed rename cleans its temp up best-effort.
 */
export async function atomicWriteFile(filePath: string, data: string): Promise<void> {
    const tmp = `${filePath}.${process.pid}.tmp`;
    await fsp.writeFile(tmp, data, 'utf-8');
    try {
        await fsp.rename(tmp, filePath);
    } catch (err) {
        await fsp.unlink(tmp).catch(() => { /* best-effort */ });
        throw err;
    }
}

/** Sync twin for the session store's synchronous flush path. */
export function atomicWriteFileSync(filePath: string, data: string): void {
    const tmp = `${filePath}.${process.pid}.tmp`;
    fsSync.writeFileSync(tmp, data, 'utf8');
    try {
        fsSync.renameSync(tmp, filePath);
    } catch (err) {
        try { fsSync.unlinkSync(tmp); } catch { /* best-effort */ }
        throw err;
    }
}
