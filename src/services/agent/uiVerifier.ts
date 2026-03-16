import { AgentAction, IDeviceProvider, UIElement } from '../../types/index.js';
import { UiParserService } from '../uiParser.service.js';
import { OcrService } from '../ocr.service.js';
import { getHardwareProfile } from '../../utils/hardware.js';
import crypto from 'crypto';
import fs from 'fs/promises';
import { AgentEventEmitter } from '../agent.service.js';

const HW = getHardwareProfile();

export class UiVerifier {
    /** Polling interval between UI idle checks — scales with hardware tier */
    private readonly idlePollMs = HW.tier === 'embedded' ? 1500
        : HW.tier === 'constrained' ? 1000
        : 500;
    /** Retry backoff — longer on slow hardware */
    private readonly retryBackoffMs = HW.tier === 'embedded' ? 2000
        : HW.tier === 'constrained' ? 1500
        : 1000;

    constructor(
        private deviceProvider: IDeviceProvider,
        private uiParserService: UiParserService,
        private ocrService: OcrService
    ) { }

    public hashUiState(elements: UIElement[]): string {
        const hashContext = elements.map(el => {
            return `${el.className}-${el.resourceId}-${el.text}-${el.contentDesc}`;
        }).join('|');
        return crypto.createHash('sha256').update(hashContext).digest('hex');
    }

    public async waitForIdle(emitter: AgentEventEmitter): Promise<{ elements: UIElement[], textRepresentation: string, hash: string, screenshotPath: string }> {
        let isIdle = false;
        let finalParsed: { elements: UIElement[], textRepresentation: string } | null = null;
        let lastElementsLength = -1;
        let stableCount = 0;
        let finalScreenshotPath = "";
        let retries = 0;
        // Track ALL screenshot paths so we can delete the intermediate ones (each PNG is 2–5 MB)
        const allScreenshotPaths: string[] = [];

        emitter.emit('status', "Waiting for UI to become idle...");

        while (!isIdle) {
            try {
                const { xml, screenshotPath } = await this.deviceProvider.getScreenContext();
                allScreenshotPaths.push(screenshotPath);

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
                    await new Promise(res => setTimeout(res, this.idlePollMs));
                }
            } catch (error: unknown) {
                retries++;
                const message = error instanceof Error ? error.message : String(error);
                console.error(`Status: Retrying UI connection (${retries}/3) - ${message.split('\n')[0]}`);
                if (retries >= 3) {
                    throw error;
                }
                await new Promise(res => setTimeout(res, this.retryBackoffMs));
            }
        }

        // Delete every intermediate screenshot — only keep the final one we're returning.
        // Each Android/desktop PNG is 2–5 MB; without cleanup they pile up in /tmp fast.
        for (const p of allScreenshotPaths) {
            if (p && p !== finalScreenshotPath) {
                fs.unlink(p).catch(() => { /* temp file may already be gone */ });
            }
        }

        // Vision Fallback (OCR) integration
        if (finalParsed && finalParsed.elements.length < 5) {
            emitter.emit('status', "Few UI elements detected. Triggering Vision OCR Fallback...");
            try {
                // Use reduce instead of spread to avoid stack overflow on large element arrays
                const maxId = finalParsed.elements.length > 0
                    ? finalParsed.elements.reduce((max, e) => e.id > max ? e.id : max, 0) + 1
                    : 1000;

                const ocrElements = await this.ocrService.extractTextElements(finalScreenshotPath, maxId);

                if (ocrElements.length > 0) {
                    emitter.emit('status', `Found ${ocrElements.length} synthetic text nodes via OCR.`);
                    finalParsed.elements.push(...ocrElements);
                    // Regenerate the symbolic JSON text for the LLM
                    const stateMap = new Map(finalParsed.elements.map(el => [el.id, el]));
                    finalParsed.textRepresentation = this.uiParserService.buildLLMPromptRepresentation(stateMap);
                }
            } catch {
                emitter.emit('error', `**Screen Analysis Failed**\nThe vision model could not process the current screen. To fix this:\n1. Ensure the screen is not completely blank or showing a secure window (like a password screen).\n2. Navigate to a standard app screen manually.\n3. Ask me to proceed from here.`);
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

    public async verifyAction(
        actionObj: Partial<AgentAction>,
        preStateElements: UIElement[],
        postStateElements: UIElement[]
    ): Promise<string> {
        const actionType = actionObj.action?.toLowerCase();
        const targetIdRaw = actionObj.target_id !== undefined ? actionObj.target_id : actionObj.id;

        // If it wasn't a targeted interaction, we just check for general state hashes in the agent loop
        if (!targetIdRaw || (actionType !== 'click' && actionType !== 'input')) {
            return actionType ? `[Success] Executed ${actionType}.` : '[Success] Action executed.';
        }

        const targetId = typeof targetIdRaw === 'string' ? parseInt(targetIdRaw, 10) : targetIdRaw;

        // Find the node in the PRE state to know what we interacted with
        const preNode = preStateElements.find(e => e.id === targetId);
        if (!preNode) {
            return `[Warning] Executed action on ID ${targetId}, but it was not found in the pre-action state.`;
        }

        // Check if the node STILL exists exactly in the POST state
        // (By text, desc, and class, since IDs might shift on complete redraws)
        const nodeStillExists = postStateElements.some(e =>
            e.className === preNode.className &&
            e.text === preNode.text &&
            e.contentDesc === preNode.contentDesc
        );

        if (nodeStillExists) {
            return `[Failed] Action on '${preNode.text || preNode.className}' did not dismiss or change it. It is still visible. You may need to scroll, or it may be disabled.`;
        } else {
            return `[Success] Action executed and UI changed. Element '${preNode.text || preNode.className}' is no longer in the same state.`;
        }
    }
}
