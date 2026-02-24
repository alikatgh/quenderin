export interface UIElement {
    id: number;
    text: string;
    contentDesc: string;
    className: string;
    resourceId: string;
    clickable: boolean;
    scrollable: boolean;
    focusable: boolean;
    enabled: boolean;
    visible: boolean;
    bounds: string;
    center: { x: number; y: number };
    rect: { x: number; y: number; width: number; height: number };
}

export interface AgentEvents {
    status: (msg: string) => void;
    error: (msg: string) => void;
    observe: (elements: UIElement[]) => void;
    decide: (command: string) => void;
    action: (msg: string) => void;
    done: () => void;
}
