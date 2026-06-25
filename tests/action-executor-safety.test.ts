import { EventEmitter } from 'events';
import { describe, it, expect } from 'vitest';
import { ActionExecutor, SafetyViolationError } from '../src/services/agent/actionExecutor.js';
import { AgentEventEmitter } from '../src/services/agent.service.js';
import type { IDeviceProvider, UIElement, AgentAction } from '../src/types/index.js';

function uiElement(id: number, text: string, rect = { x: 0, y: 0, width: 100, height: 100 }): UIElement {
    return {
        id,
        text,
        contentDesc: '',
        resourceId: '',
        className: 'android.widget.Button',
        clickable: true,
        bounds: `[${rect.x},${rect.y}][${rect.x + rect.width},${rect.y + rect.height}]`,
        center: { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 },
        rect,
    } as unknown as UIElement;
}

function deviceStub(): { provider: IDeviceProvider; clicks: Array<[number, number]> } {
    const clicks: Array<[number, number]> = [];
    const provider = Object.assign(new EventEmitter(), {
        click: async (x: number, y: number) => { clicks.push([x, y]); },
        type: async () => { },
        scroll: async () => { },
        pressKey: async () => { },
    }) as unknown as IDeviceProvider;
    return { provider, clicks };
}

const run = (exec: ActionExecutor, action: AgentAction, els: UIElement[]) => {
    const emitter = new AgentEventEmitter();
    emitter.on('error', () => { /* Node throws on an 'error' event with no listener; the loop always attaches one */ });
    return exec.execute(action, els, emitter);
};

/**
 * A raw coordinate click used to bypass the destructive-action blocklist entirely — only
 * element-targeted clicks ran checkSafety. This pins that a coordinate landing on a destructive
 * element is now blocked. (Security audit MEDIUM, actionExecutor.ts.)
 */
describe('ActionExecutor coordinate-click safety', () => {
    it('blocks a coordinate click that lands on a destructive element', async () => {
        const { provider, clicks } = deviceStub();
        const exec = new ActionExecutor(provider);
        const els = [uiElement(1, 'Confirm transfer', { x: 0, y: 0, width: 200, height: 80 })];
        await expect(run(exec, { action: 'click', x: 100, y: 40 } as AgentAction, els))
            .rejects.toBeInstanceOf(SafetyViolationError);
        expect(clicks).toHaveLength(0); // never reached the device
    });

    it('allows a coordinate click on a benign element', async () => {
        const { provider, clicks } = deviceStub();
        const exec = new ActionExecutor(provider);
        const els = [uiElement(1, 'Settings', { x: 0, y: 0, width: 200, height: 80 })];
        const ok = await run(exec, { action: 'click', x: 100, y: 40 } as AgentAction, els);
        expect(ok).toBe(true);
        expect(clicks).toEqual([[100, 40]]);
    });

    it('still blocks an element-targeted destructive click (existing behavior)', async () => {
        const { provider } = deviceStub();
        const exec = new ActionExecutor(provider);
        const els = [uiElement(7, 'Delete account')];
        await expect(run(exec, { action: 'click', target_id: 7 } as AgentAction, els))
            .rejects.toBeInstanceOf(SafetyViolationError);
    });
});
