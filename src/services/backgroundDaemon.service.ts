import { EventEmitter } from 'events';
import { IDeviceProvider, ILlmProvider } from '../types/index.js';
import { MetricsService } from './metrics.service.js';
import fs from 'fs/promises';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';

export class BackgroundDaemonService extends EventEmitter {
    private isRunning = false;
    private pollIntervalMs = 3000; // 3 seconds per requirements
    private diffThreshold = 0.05;  // 5% minimum change to trigger LLM
    private lastPngData: PNG | null = null;
    private lastDimensions: { width: number, height: number } | null = null;

    constructor(
        private deviceProvider: IDeviceProvider,
        private llmProvider: ILlmProvider,
        private metricsService: MetricsService
    ) {
        super();
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

    private async calculateVisualDiff(currentImgPath: string): Promise<{ diffRatio: number, pngData: PNG | null }> {
        try {
            const currentBuffer = await fs.readFile(currentImgPath);
            const currentPng = await this.parsePng(currentBuffer);

            // First run, or dimension mismatch (e.g. rotated screen/different monitor)
            if (!this.lastPngData || !this.lastDimensions ||
                this.lastDimensions.width !== currentPng.width ||
                this.lastDimensions.height !== currentPng.height) {

                this.lastPngData = currentPng;
                this.lastDimensions = { width: currentPng.width, height: currentPng.height };
                return { diffRatio: 1.0, pngData: currentPng }; // 100% diff on first load
            }

            const lastPng = this.lastPngData;

            const numDiffPixels = pixelmatch(
                lastPng.data,
                currentPng.data,
                new Uint8Array(currentPng.width * currentPng.height * 4), // Requires a valid typed array, even if we drop it
                currentPng.width,
                currentPng.height,
                { threshold: 0.1 }
            );

            const totalPixels = currentPng.width * currentPng.height;
            const diffRatio = numDiffPixels / totalPixels;

            // Update state for next tick with parsed PNG to skip redundant parse calls
            this.lastPngData = currentPng;

            return { diffRatio, pngData: currentPng };
        } catch (e: any) {
            this.emit('error', `Failed to calculate visual diff: ${e.message}`);
            return { diffRatio: 0, pngData: null };
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

            // Wait until next tick
            await new Promise(res => setTimeout(res, this.pollIntervalMs));
        }
    }
}
