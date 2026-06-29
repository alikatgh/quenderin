import { XMLParser } from 'fast-xml-parser';
import { UIElement } from '../types/index.js';

type RawXmlNode = {
    node?: RawXmlNode | RawXmlNode[];
    text?: string; 'content-desc'?: string; bounds?: string;
    'resource-id'?: string; class?: string;
    clickable?: string; scrollable?: string; focusable?: string;
    enabled?: string; visible?: string; displayed?: string;
};
type RawXmlTree = { hierarchy?: RawXmlNode };

export class UiParserService {
    private xmlParser = new XMLParser({
        ignoreAttributes: false,
        attributeNamePrefix: "",
        // The XML is device-sourced (/sdcard/window_dump.xml) and untrusted — disable entity
        // expansion to avoid the fast-xml-parser numeric-entity DoS (CVE-2026-33036).
        processEntities: false
    });

    public parseUI(xmlContent: string): { elements: UIElement[], textRepresentation: string } {
        const rawTree = this.parseRawTree(xmlContent);
        const stateMap = this.buildStateMap(rawTree);
        const textRepresentation = this.buildLLMPromptRepresentation(stateMap);

        const elements = Array.from(stateMap.values());
        return { elements, textRepresentation };
    }

    public parseRawTree(xmlContent: string): RawXmlTree {
        return this.xmlParser.parse(xmlContent) as RawXmlTree;
    }

    // The XML is device-sourced + untrusted. Bound the walk so a maliciously deep or huge dump can't
    // overflow the stack (deep recursion) or exhaust memory (unbounded element map). Real Android view
    // hierarchies are rarely > ~50 deep or > a few hundred nodes; these caps are far above legitimate use.
    private static readonly MAX_TREE_DEPTH = 500;
    private static readonly MAX_ELEMENTS = 5000;

    public buildStateMap(rawTree: RawXmlTree): Map<number, UIElement> {
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

        const traverse = (node: RawXmlNode | undefined, depth: number) => {
            // Bail on a too-deep or already-full tree — an adversarial dump must not overflow the stack
            // or grow the map without bound.
            if (!node || depth > UiParserService.MAX_TREE_DEPTH || stateMap.size >= UiParserService.MAX_ELEMENTS) return;

            if (node.node) {
                const children = Array.isArray(node.node) ? node.node : [node.node];
                for (const child of children) {
                    traverse(child, depth + 1);
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

            // Skip structural/container nodes with no text, no content-desc, AND no bounds — the
            // bounds-less hierarchy root was being registered as a ghost element at id 0 / center
            // (0,0), letting a confused or adversarial model tap the screen's top-left corner (M6).
            if (text || contentDesc || bounds) {
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
            }
        };

        if (rawTree && rawTree.hierarchy) {
            traverse(rawTree.hierarchy, 0);
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
