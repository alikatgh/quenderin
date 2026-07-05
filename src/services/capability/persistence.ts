import fs from 'fs';
import path from 'path';
import os from 'os';
import { AuditEntry, AuditLedger } from './capability.js';
import { SkillMemory } from './skillMemory.js';
import { UndoAction, isUndoAction } from './undo.js';

/**
 * On-disk state for the CLI agent, so "the agent gets better at what you repeat" and "review what
 * it did" are REAL across sessions (each `quenderin do` is a fresh process — in-memory state would
 * reset every time). Everything lives under ~/.quenderin/, alongside the models. Nothing leaves
 * the machine, as ever.
 */
export const QUENDERIN_DIR = path.join(os.homedir(), '.quenderin');
export const LEDGER_PATH = path.join(QUENDERIN_DIR, 'agent-ledger.jsonl');
export const SKILLS_PATH = path.join(QUENDERIN_DIR, 'agent-skills.json');
export const UNDO_PATH = path.join(QUENDERIN_DIR, 'agent-undo.json');
export const CONFIG_PATH = path.join(QUENDERIN_DIR, 'config.json');

/** Per-user defaults for `quenderin do`, so a repeat user needn't retype `--workspace ~/Downloads
 *  --gui` every time. CLI flags always override these; these override the built-in defaults. */
export interface CliConfig {
    model?: string;
    workspace?: string;
    gui?: boolean;
    maxSteps?: number;
}

/** Load ~/.quenderin/config.json (empty if none/corrupt). Every field is validated — a bad value is
 *  dropped, not fatal, so a typo in the config never bricks the CLI. */
export function loadCliConfig(file: string = CONFIG_PATH): CliConfig {
    let raw: unknown;
    try { raw = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return {}; }
    if (typeof raw !== 'object' || raw === null) return {};
    const o = raw as Record<string, unknown>;
    const cfg: CliConfig = {};
    if (typeof o.model === 'string') cfg.model = o.model;
    if (typeof o.workspace === 'string') cfg.workspace = o.workspace;
    if (typeof o.gui === 'boolean') cfg.gui = o.gui;
    if (typeof o.maxSteps === 'number' && Number.isFinite(o.maxSteps)) cfg.maxSteps = o.maxSteps;
    return cfg;
}

/** The flight recorder, persisted as JSONL — append-only, so a crash can at worst truncate the
 *  LAST line and every prior action survives (torn tails are skipped on read). Twin of the Swift
 *  FileAuditLedger. */
export class FileAuditLedger implements AuditLedger {
    constructor(private readonly file: string = LEDGER_PATH) { }

    append(entry: AuditEntry): void {
        const row: AuditEntry = { ...entry, input: entry.input.slice(0, 200), outcome: entry.outcome?.slice(0, 200) };
        try {
            fs.mkdirSync(path.dirname(this.file), { recursive: true });
            fs.appendFileSync(this.file, JSON.stringify(row) + '\n');
        } catch {
            // The ledger must never take the agent down; a lost row is better than a crash.
        }
    }

    entries(): AuditEntry[] {
        let text: string;
        try { text = fs.readFileSync(this.file, 'utf8'); } catch { return []; }
        const out: AuditEntry[] = [];
        for (const line of text.split('\n')) {
            if (!line.trim()) continue;
            try { out.push(JSON.parse(line) as AuditEntry); } catch { /* torn/corrupt line — skip */ }
        }
        return out;
    }
}

/** Load a SkillMemory from disk (empty if none/unreadable) — call once at CLI startup. */
export function loadSkillMemory(file: string = SKILLS_PATH, threshold?: number, capacity?: number): SkillMemory {
    const memory = new SkillMemory(threshold, capacity);
    try {
        memory.restore(JSON.parse(fs.readFileSync(file, 'utf8')));
    } catch {
        // No file yet, or corrupt — start fresh.
    }
    return memory;
}

/** Persist a SkillMemory's snapshot to disk (atomic write). Call after a run that learned. */
export function saveSkillMemory(memory: SkillMemory, file: string = SKILLS_PATH): void {
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(memory.snapshot()));
        fs.renameSync(tmp, file);   // atomic: a crash never leaves a half-written skills file
    } catch {
        // Non-fatal: the agent still worked, it just won't remember this run.
    }
}

/** Persist the undoable actions of the just-finished run (atomic write), so `quenderin undo` can
 *  reverse them later from a fresh process. Replaces any prior journal — undo targets the LAST task
 *  only, matching the single "undo this task" affordance the in-run prompt already offers. */
export function saveUndoJournal(actions: UndoAction[], file: string = UNDO_PATH): void {
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(actions));
        fs.renameSync(tmp, file);
    } catch {
        // Non-fatal: cross-session undo just won't be available for this run.
    }
}

/** Load the undo journal (empty if none/corrupt). Validates every row — it's on-disk, untrusted. */
export function loadUndoJournal(file: string = UNDO_PATH): UndoAction[] {
    try {
        const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
        return Array.isArray(parsed) ? parsed.filter(isUndoAction) : [];
    } catch {
        return [];
    }
}

/** Delete the undo journal — call after a successful undo, or after an in-run undo already reversed
 *  the task, so a later `quenderin undo` can't double-reverse it. */
export function clearUndoJournal(file: string = UNDO_PATH): void {
    try { fs.rmSync(file, { force: true }); } catch { /* already gone — fine */ }
}
