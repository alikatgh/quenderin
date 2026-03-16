import { EventEmitter } from 'events';
import { IDeviceProvider, ILlmProvider } from '../types/index.js';
import { MetricsService } from './metrics.service.js';
import { getHardwareProfile } from '../utils/hardware.js';
import fs from 'fs/promises';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';

const HW = getHardwareProfile();

export class BackgroundDaemonService extends EventEmitter {
    private isRunning = false;
    /** Poll interval scales with hardware tier to avoid CPU/battery drain on low-end.
     *  Can be overridden via QUENDERIN_POLL_INTERVAL_MS env var. */
    private pollIntervalMs: number;
    private diffThreshold = 0.05;  // 5% minimum change to trigger LLM
    /** Consecutive idle cycles — used for adaptive backoff to save resources */
    private idleCycleCount = 0;
    /** Store only the raw RGBA pixel data — NOT the full PNG object to save ~16MB */
    private lastPixelData: Buffer | null = null;
    private lastDimensions: { width: number, height: number } | null = null;
    /** Pre-allocated diff scratch buffer — reused every tick to avoid GC pressure */
    private diffScratch: Uint8Array | null = null;

    constructor(
        private deviceProvider: IDeviceProvider,
        private llmProvider: ILlmProvider,
        private metricsService: MetricsService
    ) {
        super();
        const envPoll = Number(process.env.QUENDERIN_POLL_INTERVAL_MS);
        this.pollIntervalMs = Number.isFinite(envPoll) && envPoll >= 1000
            ? envPoll
            : HW.pollIntervalMs;
    }

    public start() {
        if (this.isRunning) return;
        this.isRunning = true;
        console.log(`[Observer] Background watching started (${this.pollIntervalMs}ms loop).`);
        this.pollLoop();
    }

    public stop() {
        this.isRunning = false;
        console.log(`[Observer] Background watching paused.`);
    }

    private async parsePng(buffer: Buffer): Promise<PNG> {
        return new Promise((resolve, reject) => {
            const png = new PNG();
            png.parse(buffer, (err, data) => {
                if (err) reject(err);
                else resolve(data);
            });
        });
    }

    private async calculateVisualDiff(currentImgPath: string): Promise<{ diffRatio: number }> {
        try {
            const currentBuffer = await fs.readFile(currentImgPath);
            const currentPng = await this.parsePng(currentBuffer);

            // First run, or dimension mismatch (e.g. rotated screen/different monitor)
            if (!this.lastPixelData || !this.lastDimensions ||
                this.lastDimensions.width !== currentPng.width ||
                this.lastDimensions.height !== currentPng.height) {

                // Store only raw pixel data — drop the PNG wrapper to free ~8–16 MB
                this.lastPixelData = Buffer.from(currentPng.data);
                this.lastDimensions = { width: currentPng.width, height: currentPng.height };
                // Pre-allocate/resize scratch buffer for pixelmatch output
                const pixelCount = currentPng.width * currentPng.height * 4;
                if (!this.diffScratch || this.diffScratch.length !== pixelCount) {
                    this.diffScratch = new Uint8Array(pixelCount);
                }
                return { diffRatio: 1.0 }; // 100% diff on first load
            }

            const lastPixelData = this.lastPixelData;

            const numDiffPixels = pixelmatch(
                lastPixelData,
                currentPng.data,
                this.diffScratch!, // reuse pre-allocated buffer — no GC pressure
                currentPng.width,
                currentPng.height,
                { threshold: 0.1 }
            );

            const totalPixels = currentPng.width * currentPng.height;
            const diffRatio = numDiffPixels / totalPixels;

            // Update stored pixel data (only the raw buffer, not the PNG object)
            this.lastPixelData = Buffer.from(currentPng.data);

            return { diffRatio };
        } catch (e: any) {
            this.emit('error', `Failed to calculate visual diff: ${e.message}`);
            return { diffRatio: 0 };
        }
    }

    private async pollLoop() {
        while (this.isRunning) {
            try {
                // 1. Get Screenshot
                const { screenshotPath } = await this.deviceProvider.getScreenContext();

                if (!screenshotPath) {
                    await new Promise(res => setTimeout(res, this.pollIntervalMs));
                    continue;
                }

                // 2. Visual Diffing
                const { diffRatio } = await this.calculateVisualDiff(screenshotPath);

                // 3. LLM Processing if screen changed significantly
                if (diffRatio > this.diffThreshold) {
                    this.idleCycleCount = 0; // Reset backoff — screen is active
                    console.log(`[Observer] Screen changed by ${(diffRatio * 100).toFixed(1)}%. Triggering LLM...`);

                    // We don't provide a UI struct here. Pure zero-shot vision.
                    // Assuming the provider (like LLaVA) accepts an imagePath and ignores system prompt if empty
                    const description = await this.llmProvider.generateAction(
                        "Describe what the user is doing right now in one sentence.",
                        "",
                        { maxTokens: 100, temperature: 0.2 },
                        screenshotPath
                    );

                    console.log(`[Observer Log]: ${description}`);

                    // 4. Log to Habit Tracker Database
                    await this.metricsService.appendHabitLog({
                        id: Date.now().toString(),
                        timestamp: new Date().toISOString(),
                        diff_score: parseFloat(diffRatio.toFixed(3)),
                        description: description
                    });
                } else {
                    this.idleCycleCount++;
                }

                // Cleanup temp screenshot if needed (depending on provider behavior)
                // AndroidProvider unlinks XML, but currently leaves PNG. Let's force cleanup.
                if (screenshotPath) {
                    await fs.unlink(screenshotPath).catch(() => { });
                }

            } catch (err: any) {
                if (err.code !== 'ADB_MISSING' && !err.message.includes('Android Device Not Found') && !err.message.includes('adb: no devices/emulators found')) {
                    this.emit('error', `Background polling error: ${err.message.split('\n')[0]}`);
                }
            }

            // Adaptive backoff: when screen is idle for many cycles, slow down polling
            // to save CPU/battery. Resets immediately when screen changes.
            const backoffMultiplier = this.idleCycleCount > 10 ? 3
                : this.idleCycleCount > 5 ? 2
                : 1;
            const effectiveInterval = this.pollIntervalMs * backoffMultiplier;
            await new Promise(res => setTimeout(res, effectiveInterval));
        }
    }
}
