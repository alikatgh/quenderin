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

    it('Q-550: blocks a coordinate click landing just OUTSIDE a destructive element (touch slop)', async () => {
        const { provider, clicks } = deviceStub();
        const exec = new ActionExecutor(provider);
        // Confirm button occupies y∈[0,80]; tap at y=90 is 10px below it — outside the rect but inside the
        // OS touch-slop radius, so it must still be safety-checked and refused.
        const els = [uiElement(1, 'Confirm transfer', { x: 0, y: 0, width: 200, height: 80 })];
        await expect(run(exec, { action: 'click', x: 100, y: 90 } as AgentAction, els))
            .rejects.toBeInstanceOf(SafetyViolationError);
        expect(clicks).toHaveLength(0);
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

    it('rejects a non-numeric target id instead of dispatching a NaN lookup', async () => {
        const { provider, clicks } = deviceStub();
        const exec = new ActionExecutor(provider);
        const els = [uiElement(1, 'Settings')];
        const ok = await run(exec, { action: 'click', target_id: 'submit' } as unknown as AgentAction, els);
        expect(ok).toBe(false);
        expect(clicks).toHaveLength(0);
    });

    it('refuses out-of-range coordinates (negative / absurd / non-finite) before reaching the device', async () => {
        const { provider, clicks } = deviceStub();
        const exec = new ActionExecutor(provider);
        for (const [x, y] of [[-5, 10], [10, -5], [999999, 10], [Number.NaN, 10], [Infinity, 0]]) {
            const ok = await run(exec, { action: 'click', x, y } as AgentAction, []);
            expect(ok).toBe(false);
        }
        expect(clicks).toHaveLength(0);
    });
});

/**
 * The unified-blocklist matcher (Q-014 / AGENT_AUTONOMY_PLAN Milestone 0): single-word keywords
 * match on word boundaries, with camelCase and separators (`_`, `-`) split, so the expanded list
 * ('pin', 'bank', …) catches real destructive UI without firing on innocent substrings.
 */
describe('ActionExecutor unified-blocklist matching', () => {
    const block = async (label: string) => {
        const { provider } = deviceStub();
        const exec = new ActionExecutor(provider);
        return run(exec, { action: 'click', target_id: 1 } as AgentAction, [uiElement(1, label)]);
    };

    it('catches destructive keywords inside snake_case / camelCase resource labels (H10)', async () => {
        for (const label of ['confirm_transfer_btn', 'confirmTransferButton', 'wipe-device', 'Enter PIN']) {
            await expect(block(label), `"${label}" should block`).rejects.toBeInstanceOf(SafetyViolationError);
        }
    });

    it('does NOT fire on innocent words that merely contain a keyword', async () => {
        // 'pin' ⊄ spinner, 'bank' ⊄ bankruptcy, 'pay' ⊄ repay/display, 'buy' ⊄ buyer's-remorse-free label
        for (const label of ['Spinner settings', 'Bankruptcy filing help', 'Display options', 'Open the weather app']) {
            const ok = await block(label);
            expect(ok, `"${label}" should be allowed`).toBe(true);
        }
    });
});
