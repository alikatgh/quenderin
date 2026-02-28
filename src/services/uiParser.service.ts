import { XMLParser } from 'fast-xml-parser';
import { UIElement } from '../types/index.js';

export class UiParserService {
    private xmlParser = new XMLParser({
        ignoreAttributes: false,
        attributeNamePrefix: ""
    });

    public parseUI(xmlContent: string): { elements: UIElement[], textRepresentation: string } {
        const rawTree = this.parseRawTree(xmlContent);
        const stateMap = this.buildStateMap(rawTree);
        const textRepresentation = this.buildLLMPromptRepresentation(stateMap);

        const elements = Array.from(stateMap.values());
        return { elements, textRepresentation };
    }

    public parseRawTree(xmlContent: string): any {
        return this.xmlParser.parse(xmlContent);
    }

    public buildStateMap(rawTree: any): Map<number, UIElement> {
        const stateMap = new Map<number, UIElement>();
        let idCounter = 0;

        const extractBounds = (boundsString: string) => {
            if (!boundsString) {
                return { center: { x: 0, y: 0 }, rect: { x: 0, y: 0, width: 0, height: 0 } };
            }
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
                    rect: { x: x1, y: y1, width: x2 - x1, height: y2 - y1 }
                };
            }
            return { center: { x: 0, y: 0 }, rect: { x: 0, y: 0, width: 0, height: 0 } };
        };

        const traverse = (node: any) => {
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
            const enabled = node.enabled !== 'false';
            const visible = node.visible !== 'false' && node.displayed !== 'false';

            const text = node.text || '';
            const contentDesc = node['content-desc'] || '';
            const bounds = node.bounds || '';
            const resourceId = node['resource-id'] || '';
            const className = node.class || '';

            const parsedBounds = extractBounds(bounds);

            const element: UIElement = {
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
            };

            stateMap.set(element.id, element);
        };

        if (rawTree && rawTree.hierarchy) {
            traverse(rawTree.hierarchy);
        }

        return stateMap;
    }

    public buildLLMPromptRepresentation(stateMap: Map<number, UIElement>): string {
        const llmNodes: {
            id: number;
            text: string | null;
            contentDescription: string | null;
            bounds: [number, number, number, number] | null;
            isInteractable: boolean;
        }[] = [];

        for (const el of stateMap.values()) {
            const isClickableClass = el.className.includes('Button') || el.className.includes('EditText');
            const isInteractable = el.clickable || el.scrollable || el.focusable || !!isClickableClass;

            llmNodes.push({
                id: el.id,
                text: el.text.length > 0 ? el.text : null,
                contentDescription: el.contentDesc.length > 0 ? el.contentDesc : null,
                bounds: null,
                isInteractable: isInteractable
            });
        }

        return JSON.stringify(llmNodes);
    }
}
