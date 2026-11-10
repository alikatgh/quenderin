import { promises as fsp } from 'fs';
import * as fsSync from 'fs';
import path from 'path';

/**
 * Write-temp-then-rename (r16): a bare `writeFile` onto the live path TRUNCATES the target the
 * moment it starts — a crash / ENOSPC / power loss mid-write leaves a half-file, and the guarded
 * readers then treat the store as empty (sessions, trajectories, telemetry silently gone).
 * `rename` within one directory is atomic on POSIX/NTFS, so the reader only ever sees the old
 * complete file or the new complete file. The temp name carries the pid so two processes can't
 * collide on it; a failed rename cleans its temp up best-effort.
 *
 * The resolved target must stay inside its own parent directory, and the temp file is created
 * in that same parent so the rename cannot be pointed at a different directory.
 */
function confinedWritePaths(filePath: string): { target: string; tmp: string } {
    const target = path.resolve(filePath);
    const root = path.dirname(target);
    const prefix = root.endsWith(path.sep) ? root : root + path.sep;
    if (!target.startsWith(prefix)) {
        throw new Error('Refusing to write outside the destination directory');
    }
    const tmp = path.resolve(prefix, `.${path.basename(target)}.${process.pid}.tmp`);
    if (!tmp.startsWith(prefix)) {
        throw new Error('Refusing to write a temporary file outside the destination directory');
    }
    return { target, tmp };
}

export async function atomicWriteFile(filePath: string, data: string): Promise<void> {
    const { target, tmp } = confinedWritePaths(filePath);
    await fsp.writeFile(tmp, data, 'utf-8');
    try {
        await fsp.rename(tmp, target);
    } catch (err) {
        await fsp.unlink(tmp).catch(() => { /* best-effort */ });
        throw err;
    }
}

/** Sync twin for the session store's synchronous flush path. */
export function atomicWriteFileSync(filePath: string, data: string): void {
    const { target, tmp } = confinedWritePaths(filePath);
    fsSync.writeFileSync(tmp, data, 'utf8');
    try {
        fsSync.renameSync(tmp, target);
    } catch (err) {
        try { fsSync.unlinkSync(tmp); } catch { /* best-effort */ }
        throw err;
    }
}
