import { IDeviceService, UIElement } from '../types/index.js';
import { UiParserService } from './uiParser.service.js';
import { EventEmitter } from 'events';
import crypto from 'crypto';

export interface ObservationData {
    timestamp: string;
    hash: string;
    elements: UIElement[];
    xml: string;
}

export class DaemonService extends EventEmitter {
    private isRunning = false;
    private pollIntervalMs: number;
    private logSizeLimit: number;
    private observationLog: ObservationData[] = [];
    private lastHash = "";

    constructor(
        private deviceService: IDeviceService,
        private uiParserService: UiParserService,
        options = { pollIntervalMs: 2000, logSizeLimit: 100 }
    ) {
        super();
        this.pollIntervalMs = options.pollIntervalMs;
        this.logSizeLimit = options.logSizeLimit;
    }

    public start() {
        if (this.isRunning) return;
        this.isRunning = true;
        this.emit('status', 'Daemon started observing device background state.');
        this.pollLoop();
    }

    public stop() {
        this.isRunning = false;
        this.emit('status', 'Daemon paused.');
    }

    public getRecentObservations(): ObservationData[] {
        return this.observationLog;
    }

    private hashUiState(elements: UIElement[]): string {
        const hashContext = elements.map(el => {
            return `${el.className}-${el.resourceId}-${el.text}-${el.contentDesc}`;
        }).join('|');
        return crypto.createHash('md5').update(hashContext).digest('hex');
    }

    private async pollLoop() {
        while (this.isRunning) {
            try {
                const xmlDump = await this.deviceService.dumpUI();

                // If there's no XML returned, just skip this tick
                if (!xmlDump || xmlDump.length === 0) {
                    await new Promise(res => setTimeout(res, this.pollIntervalMs));
                    continue;
                }

                const parsed = this.uiParserService.parseUI(xmlDump);
                const currentHash = this.hashUiState(parsed.elements);

                // Only record meaningful state changes to prevent log bloat
                if (currentHash !== this.lastHash) {
                    this.lastHash = currentHash;

                    const observation: ObservationData = {
                        timestamp: new Date().toISOString(),
                        hash: currentHash,
                        elements: parsed.elements,
                        xml: xmlDump
                    };

                    this.observationLog.push(observation);

                    if (this.observationLog.length > this.logSizeLimit) {
                        this.observationLog.shift(); // Remove oldest
                    }

                    this.emit('observation', observation);
                }
            } catch (err: any) {
                this.emit('error', `Daemon polling error: ${err.message}`);
            }

            // Wait until next tick
            await new Promise(res => setTimeout(res, this.pollIntervalMs));
        }
    }
}
