import { createWorker } from 'tesseract.js';
import { UIElement } from '../types/index.js';

export class OcrService {
    private workerCache: any = null;

    private async getWorker() {
        if (!this.workerCache) {
            this.workerCache = await createWorker('eng');
        }
        return this.workerCache;
    }

    public async extractTextElements(imagePath: string, startingId: number = 1000): Promise<UIElement[]> {
        const worker = await this.getWorker();
        const { data } = await worker.recognize(imagePath);

        const syntheticElements: UIElement[] = [];
        let currentId = startingId;

        // Tesseract.js data.lines contains bounding boxes per line
        if (data && data.lines) {
            for (const line of data.lines) {
                const text = line.text.trim();
                // Ignore empty or completely useless noise
                if (text.length < 2) continue;

                const { x0, y0, x1, y1 } = line.bbox;
                const width = x1 - x0;
                const height = y1 - y0;

                syntheticElements.push({
                    id: currentId++,
                    text: text,
                    contentDesc: "OCR Synthetic Node",
                    className: "android.widget.TextView", // Fake class for context
                    resourceId: `ocr/node_${currentId}`,
                    clickable: true,
                    scrollable: false,
                    focusable: false,
                    enabled: true,
                    visible: true,
                    bounds: `[${Math.round(x0)},${Math.round(y0)}][${Math.round(x1)},${Math.round(y1)}]`,
                    center: {
                        x: Math.round(x0 + (width / 2)),
                        y: Math.round(y0 + (height / 2))
                    },
                    rect: {
                        x: Math.round(x0),
                        y: Math.round(y0),
                        width: Math.round(width),
                        height: Math.round(height)
                    }
                });
            }
        }

        return syntheticElements;
    }

    public async terminate() {
        if (this.workerCache) {
            await this.workerCache.terminate();
            this.workerCache = null;
        }
    }
}
