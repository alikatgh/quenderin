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
        try {
            const buf = fs.readFileSync(file);
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
}

/** The file toolkit for a granted workspace folder. */
export function fileCapabilities(workspace: () => string | null): Capability[] {
    return [
        new FsListCapability(workspace),
        new FsReadCapability(workspace),
        new FsMoveCapability(workspace),
        new FsRenameCapability(workspace),
        new FsTrashCapability(workspace),
    ];
}
