import fs from 'fs';
import path from 'path';
import os from 'os';
import { AuditEntry, AuditLedger } from './capability.js';
import { SkillMemory } from './skillMemory.js';

/**
 * On-disk state for the CLI agent, so "the agent gets better at what you repeat" and "review what
 * it did" are REAL across sessions (each `quenderin do` is a fresh process — in-memory state would
 * reset every time). Everything lives under ~/.quenderin/, alongside the models. Nothing leaves
 * the machine, as ever.
 */
export const QUENDERIN_DIR = path.join(os.homedir(), '.quenderin');
export const LEDGER_PATH = path.join(QUENDERIN_DIR, 'agent-ledger.jsonl');
export const SKILLS_PATH = path.join(QUENDERIN_DIR, 'agent-skills.json');

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
