import fs from 'fs/promises';
import path from 'path';
import os from 'os';

export interface TrajectoryEntry {
    goal: string;
    actions: string[];
    timestamp: string;
}

export class MemoryService {
    private memoryPath: string;

    constructor() {
        const homeDir = os.homedir();
        const configDir = path.join(homeDir, '.quenderin');
        this.memoryPath = path.join(configDir, 'memory.json');

        fs.mkdir(configDir, { recursive: true }).then(() => {
            return fs.access(this.memoryPath).catch(() => {
                return fs.writeFile(this.memoryPath, JSON.stringify([]), 'utf-8');
            });
        }).catch(err => {
            console.error('Failed to initialize Quenderin memory store:', err);
        });
    }

    public async saveTrajectory(goal: string, actions: string[]): Promise<void> {
        try {
            const data = await fs.readFile(this.memoryPath, 'utf-8');
            let records: TrajectoryEntry[] = JSON.parse(data);

            // Limit memory to the last 50 successful trajectories to prevent bloating
            if (records.length > 50) {
                records = records.slice(1);
            }

            records.push({
                goal,
                actions: actions.filter(a => a.startsWith('[Success]')), // Only save successful steps
                timestamp: new Date().toISOString()
            });

            await fs.writeFile(this.memoryPath, JSON.stringify(records, null, 2), 'utf-8');
        } catch (error) {
            console.error('Failed to write memory data:', error);
        }
    }

    public async findSimilarGoal(goal: string): Promise<TrajectoryEntry | null> {
        try {
            const data = await fs.readFile(this.memoryPath, 'utf-8');
            const records: TrajectoryEntry[] = JSON.parse(data);

            // Simple exact/includes matching for POC
            // A more advanced version would use normalized embeddings
            const lowerGoal = goal.toLowerCase();
            const match = records.reverse().find(r => r.goal.toLowerCase() === lowerGoal || lowerGoal.includes(r.goal.toLowerCase()));

            return match || null;
        } catch (error) {
            return null;
        }
    }
}
