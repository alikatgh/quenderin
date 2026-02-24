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

export class MetricsService {
    private telemetryPath: string;

    constructor() {
        const homeDir = os.homedir();
        // Ensure the global .quenderin config directory exists
        const configDir = path.join(homeDir, '.quenderin');
        this.telemetryPath = path.join(configDir, 'telemetry.json');

        // Initialize directory and file if they don't exist
        fs.mkdir(configDir, { recursive: true }).then(() => {
            return fs.access(this.telemetryPath).catch(() => {
                return fs.writeFile(this.telemetryPath, JSON.stringify([]), 'utf-8');
            });
        }).catch(err => {
            console.error('Failed to initialize Quenderin telemetry store:', err);
        });
    }

    public async appendMetrics(metrics: AgentMetrics): Promise<void> {
        try {
            const data = await fs.readFile(this.telemetryPath, 'utf-8');
            const records: AgentMetrics[] = JSON.parse(data);
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
        } catch (error) {
            return [];
        }
    }
}
