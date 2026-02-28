import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import { pipeline, env } from '@xenova/transformers';

// Setup Xenova for Node environment
env.allowLocalModels = false;
env.useBrowserCache = false;

export interface TrajectoryEntry {
    goal: string;
    actions: string[];
    timestamp: string;
}

export interface CorrectionEntry {
    id: string;
    uiContextString: string;
    correctionString: string;
    embeddingVector: number[];
    timestamp: string;
}

export class MemoryService {
    private memoryPath: string;
    private correctionsPath: string;
    private extractor: any = null;
    /** Awaited by all read/write methods to ensure dirs/files exist */
    private initPromise: Promise<void>;
    /** Simple promise-based write mutex to prevent read-modify-write races */
    private writeLock: Promise<void> = Promise.resolve();
    /** Release Xenova model after 5 min idle to free ~80 MB */
    private extractorIdleTimer: NodeJS.Timeout | null = null;
    private readonly EXTRACTOR_IDLE_MS = 5 * 60 * 1000;

    constructor() {
        const homeDir = os.homedir();
        const configDir = path.join(homeDir, '.quenderin');
        this.memoryPath = path.join(configDir, 'memory.json');
        this.correctionsPath = path.join(configDir, 'corrections.json');

        this.initPromise = this.initialize(configDir);
    }

    private async initialize(configDir: string): Promise<void> {
        try {
            await fs.mkdir(configDir, { recursive: true });
            await fs.access(this.memoryPath).catch(() =>
                fs.writeFile(this.memoryPath, JSON.stringify([]), 'utf-8')
            );
            await fs.access(this.correctionsPath).catch(() =>
                fs.writeFile(this.correctionsPath, JSON.stringify([]), 'utf-8')
            );
        } catch (err) {
            console.error('Failed to initialize Quenderin memory store:', err);
        }
    }

    /**
     * Serialise all writes through a single promise chain.
     * This prevents interleaved read-modify-write from dropping data.
     */
    private async withWriteLock<T>(fn: () => Promise<T>): Promise<T> {
        const prev = this.writeLock;
        let releaseLock!: () => void;
        this.writeLock = new Promise<void>(resolve => { releaseLock = resolve; });
        await prev; // wait for any prior write to finish
        try {
            return await fn();
        } finally {
            releaseLock();
        }
    }

    private resetExtractorIdleTimer(): void {
        if (this.extractorIdleTimer) clearTimeout(this.extractorIdleTimer);
        this.extractorIdleTimer = setTimeout(() => {
            if (this.extractor) {
                console.log('[Memory RAG] Releasing embedding model after idle timeout to free RAM');
                this.extractor = null;
            }
            this.extractorIdleTimer = null;
        }, this.EXTRACTOR_IDLE_MS);
        // Don't block process exit
        this.extractorIdleTimer.unref();
    }

    private async getExtractor() {
        if (!this.extractor) {
            console.log('\n[Memory RAG] Initializing local semantic embedding model (Xenova/all-MiniLM-L6-v2)...');
            this.extractor = await pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2');
        }
        // Reset the idle countdown each time it's actually used
        this.resetExtractorIdleTimer();
        return this.extractor;
    }

    private async embedText(text: string): Promise<number[]> {
        const extractor = await this.getExtractor();
        const output = await extractor(text, { pooling: 'mean', normalize: true });
        return Array.from(output.data);
    }

    public async saveTrajectory(goal: string, actions: string[]): Promise<void> {
        await this.initPromise;
        await this.withWriteLock(async () => {
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
        });
    }

    public async injectOverride(goal: string, actionsHistory: string[], manualAction: string): Promise<void> {
        await this.initPromise;
        await this.withWriteLock(async () => {
            try {
                const data = await fs.readFile(this.memoryPath, 'utf-8');
                let records: TrajectoryEntry[] = JSON.parse(data);

                if (records.length > 50) {
                    records = records.slice(1);
                }

                const cleanedHistory = actionsHistory.filter(a => a.startsWith('[Success]'));
                cleanedHistory.push(`[Success] (MANUAL OVERRIDE) ${manualAction}`);

                records.push({
                    goal,
                    actions: cleanedHistory,
                    timestamp: new Date().toISOString()
                });

                await fs.writeFile(this.memoryPath, JSON.stringify(records, null, 2), 'utf-8');
                console.log(`\n🧠 Memory forcefully updated with Manual Override for goal: ${goal}`);
            } catch (error) {
                console.error('Failed to inject manual override memory:', error);
            }
        });
    }

    public async findSimilarGoal(goal: string): Promise<TrajectoryEntry | null> {
        await this.initPromise;
        try {
            const data = await fs.readFile(this.memoryPath, 'utf-8');
            const records: TrajectoryEntry[] = JSON.parse(data);

            // Simple exact/includes matching for POC
            // A more advanced version would use normalized embeddings
            const lowerGoal = goal.toLowerCase();
            const match = records.reverse().find(r => r.goal.toLowerCase() === lowerGoal || lowerGoal.includes(r.goal.toLowerCase()));

            return match || null;
        } catch {
            return null;
        }
    }

    private readonly MAX_CORRECTIONS = 500;

    public async saveCorrection(uiContextString: string, correctionString: string): Promise<void> {
        await this.initPromise;
        await this.withWriteLock(async () => {
            try {
                const data = await fs.readFile(this.correctionsPath, 'utf-8');
                let records: CorrectionEntry[] = JSON.parse(data);

                // Evict the oldest entries when we hit the cap.
                // Each correction stores a 384-dim float vector (~3 KB as JSON).
                // 500 entries ≈ 1.5 MB on disk — a safe ceiling for low-RAM hosts.
                if (records.length >= this.MAX_CORRECTIONS) {
                    records = records.slice(-(this.MAX_CORRECTIONS - 1));
                }

                const embeddingVector = await this.embedText(uiContextString + " " + correctionString);

                records.push({
                    id: Date.now().toString(),
                    uiContextString,
                    correctionString,
                    embeddingVector,
                    timestamp: new Date().toISOString()
                });

                await fs.writeFile(this.correctionsPath, JSON.stringify(records, null, 2), 'utf-8');
                console.log(`\n[Memory RAG] 🧠 Correction persistently saved to Vector Store!`);
            } catch (error: any) {
                console.error('[Memory RAG] Failed to write correction to vector store:', error.message);
            }
        });
    }

    private cosineSimilarity(a: number[], b: number[]): number {
        let dotProduct = 0;
        let normA = 0;
        let normB = 0;
        for (let i = 0; i < a.length; i++) {
            dotProduct += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
        }
        if (normA === 0 || normB === 0) return 0;
        return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
    }

    public async findRelevantCorrections(uiContextString: string, k: number = 3): Promise<CorrectionEntry[]> {
        await this.initPromise;
        try {
            const data = await fs.readFile(this.correctionsPath, 'utf-8');
            const records: CorrectionEntry[] = JSON.parse(data);

            if (records.length === 0) return [];

            const targetVector = await this.embedText(uiContextString);

            // Score all vectors
            const scored = records.map(record => {
                const score = this.cosineSimilarity(targetVector, record.embeddingVector);
                return { record, score };
            });

            // Sort highest score first
            scored.sort((a, b) => b.score - a.score);

            // Filter by threshold (e.g. 0.70) and return top K
            return scored
                .filter(s => s.score >= 0.70)
                .slice(0, k)
                .map(s => s.record);

        } catch (error: any) {
            console.error('[Memory RAG] Failed to retrieve corrections:', error.message);
            return [];
        }
    }
}
