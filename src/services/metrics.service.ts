import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import logger from '../utils/logger.js';
import { atomicWriteFile } from '../utils/atomicWrite.js';

export interface AgentMetrics {
    id: string;
    goal_text: string;
    success: boolean;
    total_steps: number;
    duration_ms: number;
    total_retries: number;
    timestamp: string;
}

export interface HabitLog {
    id: string;
    timestamp: string;
    diff_score: number;
    description: string;
}

export class MetricsService {
    private telemetryPath: string;
    /** Habit logs use NDJSON (newline-delimited JSON) so each write is a single
     *  fs.appendFile call — no read-parse-write-all cycle every 3 seconds. */
    private habitsNdjsonPath: string;

    constructor() {
        const homeDir = os.homedir();
        const configDir = path.join(homeDir, '.quenderin');
        this.telemetryPath = path.join(configDir, 'telemetry.json');
        this.habitsNdjsonPath = path.join(configDir, 'habits.ndjson');

        fs.mkdir(configDir, { recursive: true }).then(() => {
            fs.access(this.telemetryPath).catch(() => {
                fs.writeFile(this.telemetryPath, JSON.stringify([]), 'utf-8');
            });
            // NDJSON file — just create empty if missing (no brackets needed)
            fs.access(this.habitsNdjsonPath).catch(() => {
                fs.writeFile(this.habitsNdjsonPath, '', 'utf-8');
            });
        }).catch(err => {
            logger.error('Failed to initialize Quenderin metrics store:', err);
        });
    }

    // Q-285: appendMetrics is read-modify-write on one JSON file; two concurrent agent runs
    // interleave and lose records (last write wins). Serialize every write through a promise chain —
    // single process, so an in-memory mutex is enough (no file lock). Each read-modify-write runs to
    // completion before the next begins; the caller awaits its own link.
    private writeChain: Promise<void> = Promise.resolve();

    public appendMetrics(metrics: AgentMetrics): Promise<void> {
        this.writeChain = this.writeChain.then(async () => {
            try {
                const data = await fs.readFile(this.telemetryPath, 'utf-8');
                let records: AgentMetrics[] = JSON.parse(data);
                if (records.length >= 1000) {
                    records = records.slice(-999);
                }
                records.push(metrics);
                await atomicWriteFile(this.telemetryPath, JSON.stringify(records, null, 2));
            } catch (error) {
                logger.error('Failed to write telemetry data:', error);
            }
        });
        return this.writeChain;
    }

    public async getMetrics(): Promise<AgentMetrics[]> {
        try {
            const data = await fs.readFile(this.telemetryPath, 'utf-8');
            const parsed = JSON.parse(data);
            return Array.isArray(parsed) ? parsed as AgentMetrics[] : [];
        } catch {
            return [];
        }
    }

    /** Serializes habit appends AND the getHabits() compaction (r-uc #14). Without it, a compaction's
     *  atomicWriteFile rename could clobber a line appended concurrently by the ~3s daemon loop. */
    private habitsChain: Promise<void> = Promise.resolve();

    /** Append a single habit log entry. Uses NDJSON (one JSON per line) so this is a
     *  pure append — no read-parse-write-all cycle that would thrash the heap every 3s. */
    public async appendHabitLog(log: HabitLog): Promise<void> {
        this.habitsChain = this.habitsChain.then(async () => {
            try {
                await fs.appendFile(this.habitsNdjsonPath, JSON.stringify(log) + '\n', 'utf-8');
            } catch (error) {
                logger.error('Failed to write habit log data:', error);
            }
        });
        return this.habitsChain;
    }

    public async getHabits(): Promise<HabitLog[]> {
        try {
            const raw = await fs.readFile(this.habitsNdjsonPath, 'utf-8');
            const lines = raw.split('\n').filter(line => line.trim().length > 0);
            const records = lines
                .map(line => {
                    try { return JSON.parse(line) as HabitLog; }
                    catch { return null; }
                })
                .filter((r): r is HabitLog => r !== null);

            // Compact the file when it exceeds 2000 entries — rewrite with last 1000. r-uc #14: run
            // the compaction THROUGH the habits chain, and RE-READ inside it, so it (a) can't interleave
            // with a concurrent append and (b) never writes a stale snapshot that drops a line appended
            // after this read. The response still returns this read's records (compaction is a side effect).
            if (lines.length > 2000) {
                this.habitsChain = this.habitsChain.then(async () => {
                    try {
                        const fresh = await fs.readFile(this.habitsNdjsonPath, 'utf-8');
                        const recs = fresh.split('\n').filter(l => l.trim().length > 0)
                            .map(l => { try { return JSON.parse(l) as HabitLog; } catch { return null; } })
                            .filter((r): r is HabitLog => r !== null);
                        if (recs.length > 2000) {
                            await atomicWriteFile(this.habitsNdjsonPath, recs.slice(-1000).map(r => JSON.stringify(r)).join('\n') + '\n');
                        }
                    } catch { /* best-effort compaction */ }
                });
                return records.slice(-1000);
            }

            return records.slice(-1000);
        } catch {
            return [];
        }
    }
}
