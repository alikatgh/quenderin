import { XMLParser } from 'fast-xml-parser';
import { UIElement } from '../types/index.js';

export class UiParserService {
    public parseUI(xmlContent: string): { elements: UIElement[], textRepresentation: string } {
        const parser = new XMLParser({
            ignoreAttributes: false,
            attributeNamePrefix: ""
        });

        const parsed = parser.parse(xmlContent);
        const elements: UIElement[] = [];
        let idCounter = 0;

        function extractBounds(boundsString: string) {
            const match = boundsString.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
            if (match) {
                const x1 = parseInt(match[1], 10);
                const y1 = parseInt(match[2], 10);
                const x2 = parseInt(match[3], 10);
                const y2 = parseInt(match[4], 10);
                return {
                    center: {
                        x: Math.round(x1 + (x2 - x1) / 2),
                        y: Math.round(y1 + (y2 - y1) / 2)
                    },
                    rect: {
                        x: x1,
                        y: y1,
                        width: x2 - x1,
                        height: y2 - y1
                    }
                };
            }
            return { center: { x: 0, y: 0 }, rect: { x: 0, y: 0, width: 0, height: 0 } };
        }

        function traverse(node: any) {
            if (!node) return;

            if (node.node) {
                const children = Array.isArray(node.node) ? node.node : [node.node];
                for (const child of children) {
                    traverse(child);
                }
            }

            const clickable = node.clickable === 'true';
            const scrollable = node.scrollable === 'true';
            const focusable = node.focusable === 'true';
            const checkable = node.checkable === 'true';
            const longClickable = node['long-clickable'] === 'true';
            const enabled = node.enabled !== 'false'; // Defaults to true if missing
            const visible = node.visible !== 'false' && node.displayed !== 'false';

            const text = node.text || '';
            const contentDesc = node['content-desc'] || '';
            const bounds = node.bounds || '';
            const resourceId = node['resource-id'] || '';
            const className = node.class || '';

            const hasAction = clickable || scrollable || focusable || checkable || longClickable || className.includes('EditText');
            const hasMeaningfulContent = text.length > 0 || contentDesc.length > 0;
            const hasId = resourceId.length > 0;

            // Keep interactable nodes AND nodes with text, descriptions, or IDs (for layout context)
            const shouldInclude = bounds && (hasAction || hasMeaningfulContent || hasId);

            if (shouldInclude) {
                const parsedBounds = extractBounds(bounds);
                elements.push({
                    id: idCounter++,
                    text,
                    contentDesc,
                    className,
                    resourceId,
                    clickable,
                    scrollable,
                    focusable,
                    enabled,
                    visible,
                    bounds,
                    center: parsedBounds.center,
                    rect: parsedBounds.rect
                });
            }
        }

        if (parsed && parsed.hierarchy) {
            traverse(parsed.hierarchy);
        }

        const textRepresentation = this.formatElementsToSymbolicState(elements);
        return { elements, textRepresentation };
    }

    public formatElementsToSymbolicState(elements: UIElement[]): string {
        const symbolicNodes = elements.map(el => {
            return {
                id: el.id,
                class: el.className.split('.').pop(),
                ...(el.text ? { text: el.text } : {}),
                ...(el.contentDesc ? { desc: el.contentDesc } : {}),
                ...(el.resourceId ? { res: el.resourceId.split('/').pop() } : {}),
                ...(el.clickable ? { clickable: true } : {}),
                ...(el.scrollable ? { scrollable: true } : {}),
                ...(el.focusable ? { focusable: true } : {}),
                ...(!el.enabled ? { enabled: false } : {})
            };
        });
        return JSON.stringify(symbolicNodes);
    }
}
