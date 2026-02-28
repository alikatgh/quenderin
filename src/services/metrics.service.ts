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
    private habitsPath: string;

    constructor() {
        const homeDir = os.homedir();
        // Ensure the global .quenderin config directory exists
        const configDir = path.join(homeDir, '.quenderin');
        this.telemetryPath = path.join(configDir, 'telemetry.json');
        this.habitsPath = path.join(configDir, 'habits.json');

        // Initialize directory and files if they don't exist
        fs.mkdir(configDir, { recursive: true }).then(() => {
            fs.access(this.telemetryPath).catch(() => {
                fs.writeFile(this.telemetryPath, JSON.stringify([]), 'utf-8');
            });
            fs.access(this.habitsPath).catch(() => {
                fs.writeFile(this.habitsPath, JSON.stringify([]), 'utf-8');
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

    public async appendHabitLog(log: HabitLog): Promise<void> {
        try {
            const data = await fs.readFile(this.habitsPath, 'utf-8');
            let records: HabitLog[] = JSON.parse(data);
            if (records.length >= 1000) {
                records = records.slice(-999);
            }
            records.push(log);
            await fs.writeFile(this.habitsPath, JSON.stringify(records, null, 2), 'utf-8');
        } catch (error) {
            console.error('Failed to write habit log data:', error);
        }
    }

    public async getHabits(): Promise<HabitLog[]> {
        try {
            const data = await fs.readFile(this.habitsPath, 'utf-8');
            return JSON.parse(data);
        } catch {
            return [];
        }
    }
}
