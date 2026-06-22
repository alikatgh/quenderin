import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import { pipeline, env } from '@xenova/transformers';
import logger from '../utils/logger.js';
import { sanitizeNoteFilename, sanitizeNoteTitle } from '../utils/notes.js';

export interface NoteSummary {
    filename: string;
    title: string;
    preview: string;
    modifiedAt: number;
    sizeBytes: number;
}

export interface TrajectorySummary {
    goal: string;
    actionCount: number;
    timestamp: string;
}

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

/** Process-wide singleton so HTTP routes and tool handlers share one write lock. */
let sharedMemoryService: MemoryService | null = null;

export function getSharedMemoryService(): MemoryService {
    if (!sharedMemoryService) {
        sharedMemoryService = new MemoryService();
    }
    return sharedMemoryService;
}

export function setSharedMemoryService(service: MemoryService): void {
    sharedMemoryService = service;
}

export class MemoryService {
    private memoryPath: string;
    private correctionsPath: string;
    private notesDir: string;
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
        this.notesDir = path.join(configDir, 'notes');

        this.initPromise = this.initialize(configDir);
    }

    private async initialize(configDir: string): Promise<void> {
        try {
            await fs.mkdir(configDir, { recursive: true });
            await fs.mkdir(this.notesDir, { recursive: true });
            await fs.access(this.memoryPath).catch(() =>
                fs.writeFile(this.memoryPath, JSON.stringify([]), 'utf-8')
            );
            await fs.access(this.correctionsPath).catch(() =>
                fs.writeFile(this.correctionsPath, JSON.stringify([]), 'utf-8')
            );
        } catch (err) {
            logger.error('Failed to initialize Quenderin memory store:', err);
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
                logger.info('[Memory RAG] Releasing embedding model after idle timeout to free RAM');
                this.extractor = null;
            }
            this.extractorIdleTimer = null;
        }, this.EXTRACTOR_IDLE_MS);
        // Don't block process exit
        this.extractorIdleTimer.unref();
    }

    private async getExtractor() {
        if (!this.extractor) {
            logger.info('[Memory RAG] Initializing local semantic embedding model (Xenova/all-MiniLM-L6-v2)...');
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
                // Keep the most recent 49 so the push below lands exactly at the 50 cap.
                // (The old `slice(1)` dropped only ONE element, pinning the file at 51 forever.)
                if (records.length >= 50) {
                    records = records.slice(-(50 - 1));
                }

                records.push({
                    goal,
                    actions: actions.filter(a => a.startsWith('[Success]')), // Only save successful steps
                    timestamp: new Date().toISOString()
                });

                await fs.writeFile(this.memoryPath, JSON.stringify(records, null, 2), 'utf-8');
            } catch (error) {
                logger.error('Failed to write memory data:', error);
            }
        });
    }

    public async injectOverride(goal: string, actionsHistory: string[], manualAction: string): Promise<void> {
        await this.initPromise;
        await this.withWriteLock(async () => {
            try {
                const data = await fs.readFile(this.memoryPath, 'utf-8');
                let records: TrajectoryEntry[] = JSON.parse(data);

                // Keep the most recent 49 so the push below lands exactly at the 50 cap.
                // (The old `slice(1)` dropped only ONE element, pinning the file at 51 forever.)
                if (records.length >= 50) {
                    records = records.slice(-(50 - 1));
                }

                const cleanedHistory = actionsHistory.filter(a => a.startsWith('[Success]'));
                cleanedHistory.push(`[Success] (MANUAL OVERRIDE) ${manualAction}`);

                records.push({
                    goal,
                    actions: cleanedHistory,
                    timestamp: new Date().toISOString()
                });

                await fs.writeFile(this.memoryPath, JSON.stringify(records, null, 2), 'utf-8');
                logger.info(`Memory forcefully updated with Manual Override for goal: ${goal}`);
            } catch (error) {
                logger.error('Failed to inject manual override memory:', error);
            }
        });
    }

    public async listTrajectories(limit = 20): Promise<{ trajectories: TrajectorySummary[]; total: number }> {
        await this.initPromise;
        try {
            const data = await fs.readFile(this.memoryPath, 'utf-8');
            const records: TrajectoryEntry[] = JSON.parse(data);
            const trajectories = [...records].reverse().slice(0, limit).map((r) => ({
                goal: r.goal,
                actionCount: r.actions?.length ?? 0,
                timestamp: r.timestamp,
            }));
            return { trajectories, total: records.length };
        } catch {
            return { trajectories: [], total: 0 };
        }
    }

    public async clearTrajectories(): Promise<void> {
        await this.initPromise;
        await this.withWriteLock(async () => {
            await fs.writeFile(this.memoryPath, '[]', 'utf-8');
        });
    }

    public async listNotes(): Promise<NoteSummary[]> {
        await this.initPromise;
        await fs.mkdir(this.notesDir, { recursive: true });
        const files = await fs.readdir(this.notesDir);
        const notes = await Promise.all(
            files.filter((f) => f.endsWith('.md')).map(async (file) => {
                const filePath = path.join(this.notesDir, file);
                const stat = await fs.stat(filePath);
                const content = await fs.readFile(filePath, 'utf-8').catch(() => '');
                const preview = content.split('\n').slice(0, 3).join(' ').slice(0, 200);
                return {
                    filename: file,
                    title: file.replace(/\.md$/, '').replace(/_/g, ' '),
                    preview,
                    modifiedAt: stat.mtimeMs,
                    sizeBytes: stat.size,
                };
            })
        );
        notes.sort((a, b) => b.modifiedAt - a.modifiedAt);
        return notes;
    }

    public async getNote(filename: string): Promise<string | null> {
        await this.initPromise;
        const safe = sanitizeNoteFilename(filename);
        if (!safe) return null;
        const filePath = path.join(this.notesDir, safe);
        try {
            return await fs.readFile(filePath, 'utf-8');
        } catch {
            return null;
        }
    }

    public async deleteNote(filename: string): Promise<boolean> {
        await this.initPromise;
        const safe = sanitizeNoteFilename(filename);
        if (!safe) return false;
        const filePath = path.join(this.notesDir, safe);
        try {
            await this.withWriteLock(async () => {
                await fs.unlink(filePath);
            });
            return true;
        } catch {
            return false;
        }
    }

    public async saveNote(title: string, content: string): Promise<{ path: string } | { error: string }> {
        await this.initPromise;
        const trimmedTitle = title.trim();
        const trimmedContent = content.trim();
        if (!trimmedTitle) return { error: 'Missing title parameter' };
        if (!trimmedContent) return { error: 'Missing content parameter' };

        const safeTitle = sanitizeNoteTitle(trimmedTitle);
        if (!safeTitle) {
            return {
                error: 'Title has no filename-safe characters; use letters, digits, spaces, - or _',
            };
        }

        const notePath = path.join(this.notesDir, `${safeTitle}.md`);
        const header = `# ${trimmedTitle}\n_Saved: ${new Date().toISOString()}_\n\n`;

        await this.withWriteLock(async () => {
            await fs.mkdir(this.notesDir, { recursive: true });
            await fs.writeFile(notePath, header + trimmedContent, 'utf-8');
        });

        return { path: notePath };
    }

    public async listNotesForTool(): Promise<{ title: string; modified: string; preview: string }[]> {
        await this.initPromise;
        await fs.mkdir(this.notesDir, { recursive: true });
        const files = (await fs.readdir(this.notesDir)).filter((f) => f.endsWith('.md'));
        const notes: { title: string; modified: string; preview: string }[] = [];
        for (const f of files) {
            const notePath = path.join(this.notesDir, f);
            try {
                const [stat, content] = await Promise.all([
                    fs.stat(notePath),
                    fs.readFile(notePath, 'utf-8'),
                ]);
                notes.push({
                    title: f.replace(/\.md$/, ''),
                    modified: stat.mtime.toISOString(),
                    preview: content.replace(/\n/g, ' ').slice(0, 100),
                });
            } catch { /* non-fatal */ }
        }
        return notes;
    }

    public async findSimilarGoal(goal: string): Promise<TrajectoryEntry | null> {
        await this.initPromise;
        try {
            const data = await fs.readFile(this.memoryPath, 'utf-8');
            const records: TrajectoryEntry[] = JSON.parse(data);

            // Simple exact/includes matching for POC
            // A more advanced version would use normalized embeddings
            const lowerGoal = goal.toLowerCase();
            // Copy before reverse — `records.reverse()` mutates the parsed array in place, which
            // becomes a real bug the moment the parse is cached (see audit C4/M15).
            const match = [...records].reverse().find(r => r.goal.toLowerCase() === lowerGoal || lowerGoal.includes(r.goal.toLowerCase()));

            return match || null;
        } catch {
            return null;
        }
    }

    private readonly MAX_CORRECTIONS = 500;

    public async saveCorrection(uiContextString: string, correctionString: string): Promise<void> {
        await this.initPromise;

        // Embed OUTSIDE the write lock (M12): embedText is a read-only 100–500 ms inference; holding the
        // lock across it serialized it against every concurrent read/save. Only the file read-modify-write
        // below needs the lock.
        let embeddingVector: number[];
        try {
            embeddingVector = await this.embedText(uiContextString + " " + correctionString);
        } catch (error: unknown) {
            logger.error('[Memory RAG] Failed to embed correction:', error instanceof Error ? error.message : String(error));
            return;
        }

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

                records.push({
                    id: Date.now().toString(),
                    uiContextString,
                    correctionString,
                    embeddingVector,
                    timestamp: new Date().toISOString()
                });

                await fs.writeFile(this.correctionsPath, JSON.stringify(records, null, 2), 'utf-8');
                logger.info('[Memory RAG] Correction persistently saved to Vector Store');
            } catch (error: unknown) {
                const message = error instanceof Error ? error.message : String(error);
                logger.error('[Memory RAG] Failed to write correction to vector store:', message);
            }
        });
    }

    private cosineSimilarity(a: number[], b: number[]): number {
        // Differing lengths (e.g. an embedding-model dimension change) would read undefined → NaN,
        // which destabilizes the top-k sort comparator. Treat mismatched vectors as zero (M11).
        if (a.length !== b.length) return 0;
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

        } catch (error: unknown) {
            const message = error instanceof Error ? error.message : String(error);
            logger.error('[Memory RAG] Failed to retrieve corrections:', message);
            return [];
        }
    }
}
