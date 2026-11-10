import path from 'path';

/**
 * Resolve `leaf` inside `rootDir` and refuse a result that leaves that directory.
 * `path.resolve` removes `..` segments before the prefix check, so a name that
 * climbs out of the directory cannot pass. The prefix includes the separator so
 * a sibling directory with the same prefix cannot pass either.
 */
export function resolveInside(rootDir: string, leaf: string): string {
    if (typeof leaf !== 'string' || leaf.length === 0 || leaf.includes('\0')) {
        throw new Error('Invalid path name');
    }
    const root = path.resolve(rootDir);
    const resolved = path.resolve(root, leaf);
    const prefix = root.endsWith(path.sep) ? root : root + path.sep;
    if (!resolved.startsWith(prefix)) {
        throw new Error('Path escapes the allowed directory');
    }
    return resolved;
}
