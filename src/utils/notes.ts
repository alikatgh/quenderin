/**
 * Shared note filename sanitization — used by MemoryService and tool handlers
 * so API routes and note_save agree on safe filenames.
 */

/** Sanitize a note title for use as a filename (without .md extension). */
export function sanitizeNoteTitle(title: string): string | null {
    const safeTitle = title
        .replace(/[^a-zA-Z0-9\s\-_]/g, '')
        .trim()
        .replace(/\s+/g, '_')
        .slice(0, 80);
    return safeTitle || null;
}

/** Validate a note filename from API/tool input (must be a .md basename). */
export function sanitizeNoteFilename(filename: string): string | null {
    const base = filename.replace(/[/\\]/g, '').trim();
    if (!base.endsWith('.md')) return null;
    const stem = base.slice(0, -3);
    if (!stem || stem.includes('..')) return null;
    // Reject hidden files and names that don't match our sanitizer output
    if (!/^[a-zA-Z0-9_\-]+$/.test(stem)) return null;
    return base;
}