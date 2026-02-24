import { IDeviceProvider, UIElement } from '../../types/index.js';
import { UiParserService } from '../uiParser.service.js';
import { OcrService } from '../ocr.service.js';
import crypto from 'crypto';
import { AgentEventEmitter } from '../agent.service.js';

export class UiVerifier {
    constructor(
        private deviceProvider: IDeviceProvider,
        private uiParserService: UiParserService,
        private ocrService: OcrService
    ) { }

    public hashUiState(elements: UIElement[]): string {
        const hashContext = elements.map(el => {
            return `${el.className}-${el.resourceId}-${el.text}-${el.contentDesc}`;
        }).join('|');
        return crypto.createHash('md5').update(hashContext).digest('hex');
    }

    public async waitForIdle(emitter: AgentEventEmitter): Promise<{ elements: UIElement[], textRepresentation: string, hash: string, screenshotPath: string }> {
        let isIdle = false;
        let finalParsed: { elements: UIElement[], textRepresentation: string } | null = null;
        let lastElementsLength = -1;
        let stableCount = 0;
        let finalScreenshotPath = "";
        let retries = 0;

        emitter.emit('status', "Waiting for UI to become idle...");

        while (!isIdle) {
            try {
                // Fetch both XML and Screenshot natively via the Provider
                const { xml, screenshotPath } = await this.deviceProvider.getScreenContext();
                const parsed = this.uiParserService.parseUI(xml);

                if (parsed.elements.length === lastElementsLength) {
                    stableCount++;
                } else {
                    stableCount = 0;
                    lastElementsLength = parsed.elements.length;
                }

                if (stableCount >= 2) {
                    isIdle = true;
                    finalParsed = parsed;
                    finalScreenshotPath = screenshotPath;
                } else {
                    await new Promise(res => setTimeout(res, 500));
                }
            } catch (error: any) {
                retries++;
                console.error(`Status: Retrying UI connection (${retries}/3) - ${error.message.split('\n')[0]}`);
                if (retries >= 3) {
                    emitter.emit('error', `Fatal: Cannot connect to device. UI dump failed 3 times.`);
                    throw new Error("Device disconnected or UI dump failed continuously. Aborting.");
                }
                await new Promise(res => setTimeout(res, 1000));
            }
        }

        // Vision Fallback (OCR) integration
        if (finalParsed && finalParsed.elements.length < 5) {
            emitter.emit('status', "Few UI elements detected. Triggering Vision OCR Fallback...");
            try {
                // Find next available ID
                const nextId = finalParsed.elements.length > 0
                    ? Math.max(...finalParsed.elements.map(e => e.id)) + 1
                    : 1000;

                const ocrElements = await this.ocrService.extractTextElements(finalScreenshotPath, nextId);

                if (ocrElements.length > 0) {
                    emitter.emit('status', `Found ${ocrElements.length} synthetic text nodes via OCR.`);
                    finalParsed.elements.push(...ocrElements);
                    // Regenerate the symbolic JSON text for the LLM
                    finalParsed.textRepresentation = this.uiParserService.formatElementsToSymbolicState(finalParsed.elements);
                }
            } catch (err: any) {
                emitter.emit('error', `Vision Fallback Error: ${err.message}`);
            }
        }

        const hash = this.hashUiState(finalParsed!.elements);

        return {
            elements: finalParsed!.elements,
            textRepresentation: finalParsed!.textRepresentation,
            hash,
            screenshotPath: finalScreenshotPath
        };
    }
}
