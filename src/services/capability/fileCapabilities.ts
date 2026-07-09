import fs from 'fs';
import path from 'path';
import { Capability, CapabilityTier, BlastRadius, ActionPreview } from './capability.js';

/**
 * File capabilities for the desktop agent — the #1 chore class ("organize my downloads"), which
 * the CLI agent couldn't do before (fs.* lived only in the Swift/Kotlin apps). Same structural
 * safety as those twins: a WORKSPACE folder the user granted, plain-name inputs only (no paths,
 * no ".."), never overwrite, and each write implements `undo()` so it plugs into the session
 * rollback. The model names files it can see via fs.list; it never navigates the filesystem.
 */

const NO_WS = 'No workspace folder set. Grant one first (e.g. `quenderin do --workspace <dir>`).';

/** A plain filename inside the workspace — rejects paths, traversal, and empties. */
function safeName(name: string): boolean {
    const n = name.trim();
    return n.length > 0 && !n.includes('/') && !n.includes('\\') && !n.includes('..');
}

abstract class WorkspaceCapability {
    constructor(protected readonly workspace: () => string | null) { }
    protected dir(): string | null { return this.workspace(); }
}

/** T1: list the workspace folder. Read-only. */
export class FsListCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.list';
    readonly purpose = 'List the files in the workspace folder. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'the workspace folder' };

    async plan(): Promise<ActionPreview> {
        const d = this.dir();
        return { summary: d ? `Would list "${path.basename(d)}" (read-only).` : NO_WS, mutates: false };
    }
    async run(): Promise<string> {
        const d = this.dir();
        if (!d) return NO_WS;
        let names: string[];
        try { names = fs.readdirSync(d).filter(n => !n.startsWith('.')).sort(); }
        catch { return `Couldn't list "${path.basename(d)}".`; }
        if (names.length === 0) return `The workspace "${path.basename(d)}" is empty.`;
        const lines = names.slice(0, 200).map(n => {
            try { return fs.statSync(path.join(d, n)).isDirectory() ? `${n}/` : n; } catch { return n; }
        });
        return lines.join('\n') + (names.length > 200 ? `\n[…${names.length - 200} more]` : '');
    }
}

/** T1: read a text file the model named from fs.list. Read-only, capped. */
export class FsReadCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.read';
    readonly purpose = 'Read a text file in the workspace by name. Input: the file name.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'a workspace file' };
    constructor(workspace: () => string | null, private readonly maxBytes = 64 * 1024) { super(workspace); }

    async plan(input: string): Promise<ActionPreview> {
        return { summary: safeName(input) ? `Would read "${input.trim()}" (read-only).` : 'Input is a plain file name.', mutates: false };
    }
    async run(input: string): Promise<string> {
        const d = this.dir();
        if (!d) return NO_WS;
        if (!safeName(input)) return 'Input is a plain file name in the workspace — no paths.';
        const file = path.join(d, input.trim());
        // Q-277: `safeName` blocks paths in the NAME, but a plainly-named SYMLINK inside the
        // workspace could point at /etc/passwd — readFileSync would follow it. Resolve the real
        // path and refuse anything that escapes the workspace (realpath'd on both sides so an
        // intra-workspace link is fine and macOS's /tmp→/private/tmp doesn't false-positive).
        let realFile: string;
        try {
            const realWs = fs.realpathSync(d);
            realFile = fs.realpathSync(file);
            if (realFile !== realWs && !realFile.startsWith(realWs + path.sep)) {
                return `"${input.trim()}" resolves outside the workspace — refused.`;
            }
        } catch {
            return `No file named "${input.trim()}" in the workspace (or it isn't readable).`;
        }
        try {
            const buf = fs.readFileSync(realFile);
            const slice = buf.length > this.maxBytes ? buf.subarray(0, this.maxBytes) : buf;
            const text = slice.toString('utf8');
            if (text.includes('�')) return `"${input.trim()}" isn't a UTF-8 text file.`;
            return buf.length > this.maxBytes ? text + `\n[…truncated at ${this.maxBytes / 1024} KB]` : text;
        } catch {
            return `No file named "${input.trim()}" in the workspace (or it isn't readable).`;
        }
    }
}

/** T2: move a file into a subfolder. Never overwrites; undo moves it back. */
export class FsMoveCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.move';
    readonly purpose = 'Move a file into a subfolder of the workspace. Input: "<file> to <subfolder>".';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the workspace folder' };

    private parse(input: string): { file: string; dest: string } | null {
        const parts = input.split(' to ');
        if (parts.length !== 2) return null;
        const file = parts[0].trim(), dest = parts[1].trim();
        return safeName(file) && safeName(dest) ? { file, dest } : null;
    }
    async plan(input: string): Promise<ActionPreview> {
        const p = this.parse(input);
        if (!this.dir()) return { summary: NO_WS, mutates: false };
        return p
            ? { summary: `Move "${p.file}" into "${p.dest}/" (undoable).`, mutates: true }
            : { summary: 'Input must be "<file> to <subfolder>", plain names.', mutates: false };
    }
    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Input must be "<file> to <subfolder>" — plain names, no paths.';
        const src = path.join(d, p.file), destDir = path.join(d, p.dest), target = path.join(destDir, p.file);
        if (!fs.existsSync(src)) return `No file named "${p.file}" in the workspace. Use fs.list.`;
        try {
            if (fs.existsSync(destDir) && !fs.statSync(destDir).isDirectory()) return `"${p.dest}" is a file, not a folder.`;
            if (!fs.existsSync(destDir)) fs.mkdirSync(destDir);
            if (fs.existsSync(target)) return `"${p.dest}/${p.file}" already exists — refusing to overwrite.`;
            fs.renameSync(src, target);
            return `Moved "${p.file}" into "${p.dest}/". (Undo available.)`;
        } catch (e) { return `Couldn't move "${p.file}": ${String(e)}`; }
    }
    async undo(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Nothing to undo.';
        const from = path.join(d, p.dest, p.file), to = path.join(d, p.file);
        try { fs.renameSync(from, to); return `Moved "${p.file}" back.`; }
        catch (e) { return `Couldn't undo the move of "${p.file}": ${String(e)}`; }
    }
    /** Post-action check: target exists, source is gone. Annotates the observation if not. */
    async verify(input: string): Promise<{ ok: boolean; detail: string }> {
        const d = this.dir(); if (!d) return { ok: false, detail: NO_WS };
        const p = this.parse(input); if (!p) return { ok: false, detail: 'Bad input for verify.' };
        const target = path.join(d, p.dest, p.file);
        const src = path.join(d, p.file);
        if (fs.existsSync(target) && !fs.existsSync(src)) {
            return { ok: true, detail: `"${p.dest}/${p.file}" is in place.` };
        }
        return { ok: false, detail: `Move of "${p.file}" into "${p.dest}/" did not land (source still present or target missing).` };
    }
}

/** T2: rename a file. Never overwrites; undo reverses the name. */
export class FsRenameCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.rename';
    readonly purpose = 'Rename a file in the workspace. Input: "<current name> to <new name>".';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the workspace folder' };

    private parse(input: string): { from: string; to: string } | null {
        const parts = input.split(' to ');
        if (parts.length !== 2) return null;
        const from = parts[0].trim(), to = parts[1].trim();
        return safeName(from) && safeName(to) ? { from, to } : null;
    }
    async plan(input: string): Promise<ActionPreview> {
        const p = this.parse(input);
        if (!this.dir()) return { summary: NO_WS, mutates: false };
        return p ? { summary: `Rename "${p.from}" to "${p.to}" (undoable).`, mutates: true }
                 : { summary: 'Input must be "<current> to <new>", plain names.', mutates: false };
    }
    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Input must be "<current> to <new>" — plain names.';
        const from = path.join(d, p.from), to = path.join(d, p.to);
        if (!fs.existsSync(from)) return `No file named "${p.from}" in the workspace.`;
        if (fs.existsSync(to)) return `"${p.to}" already exists — refusing to overwrite.`;
        try { fs.renameSync(from, to); return `Renamed "${p.from}" to "${p.to}". (Undo available.)`; }
        catch (e) { return `Couldn't rename "${p.from}": ${String(e)}`; }
    }
    async undo(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Nothing to undo.';
        try { fs.renameSync(path.join(d, p.to), path.join(d, p.from)); return `Renamed "${p.to}" back to "${p.from}".`; }
        catch (e) { return `Couldn't undo the rename: ${String(e)}`; }
    }
    async verify(input: string): Promise<{ ok: boolean; detail: string }> {
        const d = this.dir(); if (!d) return { ok: false, detail: NO_WS };
        const p = this.parse(input); if (!p) return { ok: false, detail: 'Bad input for verify.' };
        const to = path.join(d, p.to), from = path.join(d, p.from);
        if (fs.existsSync(to) && !fs.existsSync(from)) {
            return { ok: true, detail: `"${p.to}" is in place.` };
        }
        return { ok: false, detail: `Rename to "${p.to}" did not land.` };
    }
}

/**
 * T2: CREATE a new text file in the workspace — the agent producing an artifact ("read these and
 * write me a summary.md"), not just reorganizing existing files. Create-only: never overwrites, so
 * it can't clobber your work. Undo relocates the created file into Trash/ (not a delete), which is
 * safe even across sessions — worst case a same-named file is recoverable in Trash/, never
 * destroyed. Like mac.notes.create / mac.mail.draft, the CONTENT is scanned by the blocklist, so a
 * body naming a blocked action is refused — the same conservative, fail-safe default.
 */
export class FsWriteCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.write';
    readonly purpose = 'Create a NEW text file in the workspace. Input: "<filename> | <text content>".';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the workspace folder' };

    private parse(input: string): { name: string; content: string } | null {
        const idx = input.indexOf('|');
        if (idx < 0) return null;
        const name = input.slice(0, idx).trim();
        const content = input.slice(idx + 1).replace(/^ /, '');   // one optional space after the pipe
        return safeName(name) ? { name, content } : null;
    }
    async plan(input: string): Promise<ActionPreview> {
        if (!this.dir()) return { summary: NO_WS, mutates: false };
        const p = this.parse(input);
        return p
            ? { summary: `Create a new file "${p.name}" (${p.content.length} chars; undoable — moves to Trash/).`, mutates: true }
            : { summary: 'Input must be "<filename> | <content>", a plain filename.', mutates: false };
    }
    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Input must be "<filename> | <content>" — a plain filename.';
        const target = path.join(d, p.name);
        if (fs.existsSync(target)) return `"${p.name}" already exists — refusing to overwrite. Pick a new name.`;
        try { fs.writeFileSync(target, p.content); return `Created "${p.name}" (${p.content.length} chars). (Undo available.)`; }
        catch (e) { return `Couldn't create "${p.name}": ${String(e)}`; }
    }
    async undo(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const p = this.parse(input); if (!p) return 'Nothing to undo.';
        const src = path.join(d, p.name), trashDir = path.join(d, 'Trash'), dest = path.join(trashDir, p.name);
        try {
            if (!fs.existsSync(src)) return `"${p.name}" is already gone.`;
            if (fs.existsSync(trashDir) && !fs.statSync(trashDir).isDirectory()) return '"Trash" is a file, not a folder.';
            if (!fs.existsSync(trashDir)) fs.mkdirSync(trashDir);
            if (fs.existsSync(dest)) return `Couldn't undo "${p.name}" — a Trash/ entry already has that name.`;
            fs.renameSync(src, dest);
            return `Moved the file "${p.name}" I created into Trash/.`;
        } catch (e) { return `Couldn't undo "${p.name}": ${String(e)}`; }
    }
    async verify(input: string): Promise<{ ok: boolean; detail: string }> {
        const d = this.dir(); if (!d) return { ok: false, detail: NO_WS };
        const p = this.parse(input); if (!p) return { ok: false, detail: 'Bad input for verify.' };
        const target = path.join(d, p.name);
        if (fs.existsSync(target) && fs.statSync(target).isFile()) {
            return { ok: true, detail: `"${p.name}" exists on disk.` };
        }
        return { ok: false, detail: `"${p.name}" was not created.` };
    }
}

/** T2: move a file to a visible Trash/ subfolder — never a real delete. Undo restores it. */
export class FsTrashCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.trash';
    readonly purpose = 'Move a file into the workspace Trash/ folder (not deleted). Input: the file name.';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the workspace folder' };

    async plan(input: string): Promise<ActionPreview> {
        if (!this.dir()) return { summary: NO_WS, mutates: false };
        return safeName(input)
            ? { summary: `Move "${input.trim()}" into Trash/ (undoable — not deleted).`, mutates: true }
            : { summary: 'Input is one plain file name.', mutates: false };
    }
    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        if (!safeName(input)) return 'Input is one plain file name — no paths.';
        const name = input.trim(), src = path.join(d, name), trashDir = path.join(d, 'Trash'), target = path.join(trashDir, name);
        if (!fs.existsSync(src)) return `No file named "${name}" in the workspace.`;
        try {
            if (fs.existsSync(trashDir) && !fs.statSync(trashDir).isDirectory()) return '"Trash" is a file, not a folder.';
            if (!fs.existsSync(trashDir)) fs.mkdirSync(trashDir);
            if (fs.existsSync(target)) return `Trash/${name} already exists — refusing to overwrite.`;
            fs.renameSync(src, target);
            return `Moved "${name}" to Trash/. (Undo restores it; nothing deleted.)`;
        } catch (e) { return `Couldn't trash "${name}": ${String(e)}`; }
    }
    async undo(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const name = input.trim();
        try { fs.renameSync(path.join(d, 'Trash', name), path.join(d, name)); return `Restored "${name}" from Trash/.`; }
        catch (e) { return `Couldn't restore "${name}": ${String(e)}`; }
    }
    async verify(input: string): Promise<{ ok: boolean; detail: string }> {
        const d = this.dir(); if (!d) return { ok: false, detail: NO_WS };
        if (!safeName(input)) return { ok: false, detail: 'Bad input for verify.' };
        const name = input.trim();
        const target = path.join(d, 'Trash', name);
        const src = path.join(d, name);
        if (fs.existsSync(target) && !fs.existsSync(src)) {
            return { ok: true, detail: `"${name}" is in Trash/.` };
        }
        return { ok: false, detail: `"${name}" did not land in Trash/.` };
    }
}

/**
 * Extension → destination folder for batch organize. Conservative, demo-friendly defaults.
 * Unknown extensions are skipped (never dumped into a catch-all that surprises the user).
 */
const ORGANIZE_MAP: Record<string, string> = {
    pdf: 'Documents', doc: 'Documents', docx: 'Documents', txt: 'Documents', md: 'Documents', rtf: 'Documents',
    png: 'Images', jpg: 'Images', jpeg: 'Images', gif: 'Images', webp: 'Images', heic: 'Images',
    mp3: 'Audio', wav: 'Audio', m4a: 'Audio', aac: 'Audio',
    mp4: 'Videos', mov: 'Videos', mkv: 'Videos',
    zip: 'Archives', tar: 'Archives', gz: 'Archives', '7z': 'Archives',
    csv: 'Data', json: 'Data', xlsx: 'Data',
};

/** Hidden journal so fs.organize can undo across a process restart (RunSession only has name+input). */
const ORGANIZE_UNDO_JOURNAL = '.quenderin-organize-undo.json';

/**
 * T2: batch-organize top-level files in the workspace by extension into type folders
 * (Documents/, Images/, …). One approval covers the whole batch — the #1 chore class without
 * N separate fs.move plans. Never overwrites; skips unknowns and anything already in a subfolder.
 * Undo reverses the last batch (LIFO), durable via a hidden workspace journal.
 */
export class FsOrganizeCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.organize';
    readonly purpose =
        'Organize top-level workspace files into type folders (Documents/, Images/, …) by extension. Input: empty or "dry" to preview only.';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the workspace folder' };

    private planMoves(d: string): Array<{ file: string; dest: string }> {
        let names: string[];
        try { names = fs.readdirSync(d).filter(n => !n.startsWith('.')); }
        catch { return []; }
        const out: Array<{ file: string; dest: string }> = [];
        for (const name of names) {
            if (!safeName(name)) continue;
            const full = path.join(d, name);
            let st: fs.Stats;
            try { st = fs.statSync(full); } catch { continue; }
            if (!st.isFile()) continue; // only top-level files; leave folders alone
            const ext = path.extname(name).slice(1).toLowerCase();
            const dest = ORGANIZE_MAP[ext];
            if (!dest) continue;
            const target = path.join(d, dest, name);
            if (fs.existsSync(target)) continue; // never overwrite
            out.push({ file: name, dest });
        }
        return out;
    }

    async plan(input: string): Promise<ActionPreview> {
        const d = this.dir();
        if (!d) return { summary: NO_WS, mutates: false };
        const moves = this.planMoves(d);
        if (moves.length === 0) {
            return { summary: 'No top-level files with known types to organize (or all destinations already exist).', mutates: false };
        }
        const preview = moves.slice(0, 12).map(m => `${m.file} → ${m.dest}/`).join('; ');
        const more = moves.length > 12 ? ` (+${moves.length - 12} more)` : '';
        const dry = input.trim().toLowerCase() === 'dry';
        return {
            summary: dry
                ? `Would organize ${moves.length} file(s) (dry): ${preview}${more}.`
                : `Organize ${moves.length} file(s) by type: ${preview}${more} (undoable).`,
            mutates: !dry,
        };
    }

    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        if (input.trim().toLowerCase() === 'dry') {
            const moves = this.planMoves(d);
            if (moves.length === 0) return 'Nothing to organize.';
            return `Dry run — would move:\n${moves.map(m => `- ${m.file} → ${m.dest}/`).join('\n')}`;
        }
        const moves = this.planMoves(d);
        if (moves.length === 0) return 'Nothing to organize — no matching top-level files.';
        const done: string[] = [];
        const skipped: string[] = [];
        const landed: Array<{ file: string; dest: string }> = [];
        for (const m of moves) {
            const src = path.join(d, m.file);
            const destDir = path.join(d, m.dest);
            const target = path.join(destDir, m.file);
            try {
                if (!fs.existsSync(src) || fs.existsSync(target)) {
                    skipped.push(m.file);
                    continue;
                }
                if (!fs.existsSync(destDir)) fs.mkdirSync(destDir);
                fs.renameSync(src, target);
                done.push(`${m.file} → ${m.dest}/`);
                landed.push(m);
            } catch {
                skipped.push(m.file);
            }
        }
        if (landed.length > 0) {
            try {
                fs.writeFileSync(path.join(d, ORGANIZE_UNDO_JOURNAL), JSON.stringify(landed));
            } catch { /* undo may be incomplete without journal; moves still happened */ }
        }
        if (done.length === 0) return `Couldn't organize any files.${skipped.length ? ` Skipped: ${skipped.join(', ')}.` : ''}`;
        const skipNote = skipped.length ? ` Skipped ${skipped.length}: ${skipped.slice(0, 5).join(', ')}${skipped.length > 5 ? '…' : ''}.` : '';
        return `Organized ${done.length} file(s):\n${done.map(x => `- ${x}`).join('\n')}.${skipNote} (Undo available.)`;
    }

    private loadUndoJournal(d: string): Array<{ file: string; dest: string }> {
        try {
            const raw = fs.readFileSync(path.join(d, ORGANIZE_UNDO_JOURNAL), 'utf8');
            const parsed = JSON.parse(raw) as unknown;
            if (!Array.isArray(parsed)) return [];
            return parsed.filter((m): m is { file: string; dest: string } =>
                typeof (m as { file?: string })?.file === 'string'
                && typeof (m as { dest?: string })?.dest === 'string'
                && safeName((m as { file: string }).file)
                && safeName((m as { dest: string }).dest),
            );
        } catch {
            return [];
        }
    }

    async undo(_input = ''): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const moves = this.loadUndoJournal(d);
        if (moves.length === 0) return 'Nothing to undo for fs.organize (no prior batch journal).';
        const restored: string[] = [];
        for (const m of [...moves].reverse()) {
            const from = path.join(d, m.dest, m.file);
            const to = path.join(d, m.file);
            try {
                if (fs.existsSync(from) && !fs.existsSync(to)) {
                    fs.renameSync(from, to);
                    restored.push(m.file);
                }
            } catch { /* keep going */ }
        }
        try { fs.unlinkSync(path.join(d, ORGANIZE_UNDO_JOURNAL)); } catch { /* ok */ }
        return restored.length
            ? `Restored ${restored.length} file(s) from organize: ${restored.join(', ')}.`
            : 'Could not restore organized files (moved or missing).';
    }

    async verify(_input = ''): Promise<{ ok: boolean; detail: string }> {
        const d = this.dir(); if (!d) return { ok: false, detail: NO_WS };
        const moves = this.loadUndoJournal(d);
        if (moves.length === 0) return { ok: true, detail: 'no organize journal (nothing to check)' };
        const bad = moves.filter(m => {
            const target = path.join(d, m.dest, m.file);
            const src = path.join(d, m.file);
            return !(fs.existsSync(target) && !fs.existsSync(src));
        });
        if (bad.length === 0) return { ok: true, detail: `${moves.length} file(s) in type folders.` };
        return { ok: false, detail: `${bad.length} organized file(s) not at destination.` };
    }
}

/**
 * T1: collect text from several workspace files into one observation — the perception half of
 * "read these notes and write a report". Input: comma-separated plain filenames (from fs.list).
 * Cap total bytes so a weak model isn't flooded. No mutation; model summarizes, then fs.write.
 */
export class FsCollectCapability extends WorkspaceCapability implements Capability {
    readonly name = 'fs.collect';
    readonly purpose =
        'Read several text files and return them labeled for summarization. Input: "file1.txt, file2.md" (comma-separated plain names).';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'workspace text files' };

    constructor(
        workspace: () => string | null,
        private readonly maxFiles = 20,
        private readonly maxBytesPerFile = 24 * 1024,
        private readonly maxTotalBytes = 64 * 1024,
    ) { super(workspace); }

    private parseNames(input: string): string[] | null {
        const parts = input.split(',').map(s => s.trim()).filter(Boolean);
        if (parts.length === 0) return null;
        if (!parts.every(safeName)) return null;
        return parts;
    }

    async plan(input: string): Promise<ActionPreview> {
        const d = this.dir();
        if (!d) return { summary: NO_WS, mutates: false };
        const names = this.parseNames(input);
        if (!names) return { summary: 'Input: comma-separated plain file names from fs.list.', mutates: false };
        return {
            summary: `Would read ${Math.min(names.length, this.maxFiles)} text file(s) for a combined summary (read-only).`,
            mutates: false,
        };
    }

    async run(input: string): Promise<string> {
        const d = this.dir(); if (!d) return NO_WS;
        const names = this.parseNames(input);
        if (!names) return 'Input must be comma-separated plain file names, e.g. "notes.txt, todo.md".';
        const pick = names.slice(0, this.maxFiles);
        let total = 0;
        const sections: string[] = [];
        const missing: string[] = [];
        let realWs: string;
        try { realWs = fs.realpathSync(d); } catch { return `Couldn't open workspace.`; }

        for (const name of pick) {
            if (total >= this.maxTotalBytes) {
                sections.push(`[…stopped at ${this.maxTotalBytes / 1024} KB total cap; ${pick.length - sections.length} file(s) not read]`);
                break;
            }
            const file = path.join(d, name);
            let realFile: string;
            try {
                realFile = fs.realpathSync(file);
                if (realFile !== realWs && !realFile.startsWith(realWs + path.sep)) {
                    missing.push(name);
                    continue;
                }
            } catch {
                missing.push(name);
                continue;
            }
            try {
                const buf = fs.readFileSync(realFile);
                const room = Math.min(this.maxBytesPerFile, this.maxTotalBytes - total);
                const slice = buf.length > room ? buf.subarray(0, room) : buf;
                const text = slice.toString('utf8');
                if (text.includes('�')) {
                    sections.push(`## ${name}\n(not UTF-8 text — skipped)`);
                    continue;
                }
                total += slice.length;
                const trunc = buf.length > room ? `\n[…truncated at ${room} bytes]` : '';
                sections.push(`## ${name}\n${text}${trunc}`);
            } catch {
                missing.push(name);
            }
        }

        if (sections.length === 0) {
            return missing.length
                ? `Could not read any of: ${missing.join(', ')}.`
                : 'No files to collect.';
        }
        const header = `Collected ${sections.filter(s => s.startsWith('##')).length} file(s)` +
            (missing.length ? ` (${missing.length} missing/unreadable: ${missing.slice(0, 5).join(', ')})` : '') +
            '.\nSummarize the content below, then use fs.write to save a report if asked.\n';
        return header + sections.join('\n\n');
    }
}

/** The file toolkit for a granted workspace folder. */
export function fileCapabilities(workspace: () => string | null): Capability[] {
    return [
        new FsListCapability(workspace),
        new FsReadCapability(workspace),
        new FsCollectCapability(workspace),
        new FsMoveCapability(workspace),
        new FsOrganizeCapability(workspace),
        new FsRenameCapability(workspace),
        new FsWriteCapability(workspace),
        new FsTrashCapability(workspace),
    ];
}
