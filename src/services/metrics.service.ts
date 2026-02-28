import fs from 'fs/promises';
import path from 'path';
import os from 'os';

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
            console.error('Failed to initialize Quenderin metrics store:', err);
        });
    }

    public async appendMetrics(metrics: AgentMetrics): Promise<void> {
        try {
            const data = await fs.readFile(this.telemetryPath, 'utf-8');
            let records: AgentMetrics[] = JSON.parse(data);
            if (records.length >= 1000) {
                records = records.slice(-999);
            }
            records.push(metrics);
            await fs.writeFile(this.telemetryPath, JSON.stringify(records, null, 2), 'utf-8');
        } catch (error) {
            console.error('Failed to write telemetry data:', error);
        }
    }

    public async getMetrics(): Promise<AgentMetrics[]> {
        try {
            const data = await fs.readFile(this.telemetryPath, 'utf-8');
            return JSON.parse(data);
        } catch {
            return [];
        }
    }

    /** Append a single habit log entry. Uses NDJSON (one JSON per line) so this is a
     *  pure append — no read-parse-write-all cycle that would thrash the heap every 3s. */
    public async appendHabitLog(log: HabitLog): Promise<void> {
        try {
            await fs.appendFile(this.habitsNdjsonPath, JSON.stringify(log) + '\n', 'utf-8');
        } catch (error) {
            console.error('Failed to write habit log data:', error);
        }
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

            // Compact the file when it exceeds 2000 entries — rewrite with last 1000
            if (lines.length > 2000) {
                const kept = records.slice(-1000);
                fs.writeFile(this.habitsNdjsonPath, kept.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf-8')
                    .catch(() => { /* best-effort compaction */ });
                return kept;
            }

            return records.slice(-1000);
        } catch {
            return [];
        }
    }
}
