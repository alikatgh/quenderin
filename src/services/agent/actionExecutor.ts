import { UIElement, IDeviceProvider, AgentAction } from '../../types/index.js';
import { AgentEventEmitter } from '../agent.service.js';
import { matchedBlockedKeyword } from '../capability/safety.js';

export class SafetyViolationError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'SafetyViolationError';
    }
}

export class ActionExecutor {
    constructor(private deviceProvider: IDeviceProvider) { }

    private checkSafety(el: UIElement | undefined, inputText?: string) {
        const textToCheck = [
            el?.text,
            el?.contentDesc,
            el?.resourceId,   // H10: icon buttons with empty labels but a resource-id like "confirm_transfer_btn"
            inputText
        ].filter(Boolean) as string[];

        for (const text of textToCheck) {
            const hit = matchedBlockedKeyword(text);
            if (hit) {
                throw new SafetyViolationError(`Safety Block: Refusing to interact with potentially destructive context matching '${hit}'.`);
            }
        }
    }

    /** Every UI element whose bounding box (expanded by the OS touch-slop margin) contains the point —
     *  used to re-apply the safety blocklist to a raw coordinate click (which has no target element of
     *  its own). Q-550: the strict point-in-rect test let a tap landing JUST OUTSIDE a destructive
     *  control's reported rect — but within the radius the OS still resolves to that control — dodge the
     *  blocklist. The slop margin (≈ Android's ~8dp ViewConfiguration touch slop) closes that gap. It can
     *  only ADD elements to the safety check, never remove one, so a click can never become less safe. */
    private static readonly TOUCH_SLOP_PX = 24;
    private elementsContaining(x: number, y: number, elements: UIElement[]): UIElement[] {
        const slop = ActionExecutor.TOUCH_SLOP_PX;
        return elements.filter(e =>
            e.rect &&
            x >= e.rect.x - slop && x <= e.rect.x + e.rect.width + slop &&
            y >= e.rect.y - slop && y <= e.rect.y + e.rect.height + slop);
    }

    /** Refuse a blatantly destructive GOAL before the agent loop starts (H10). Throws SafetyViolationError. */
    public assertGoalSafe(goal: string): void {
        this.checkSafety(undefined, goal);
    }

    public async execute(actionObj: AgentAction, elements: UIElement[], emitter: AgentEventEmitter): Promise<boolean> {
        const actionType = actionObj.action;
        emitter.emit('action', actionType);

        if (actionType === 'done') {
            emitter.emit('status', `Goal achieved successfully.`);
            emitter.emit('done');
            return true;
        }

        try {
            // Safety Sandboxing Check for any input texts
            this.checkSafety(undefined, actionObj.text);

            if (actionType === 'click' || actionType === 'input') {
                const targetIdRaw = actionObj.target_id !== undefined ? actionObj.target_id : actionObj.id;

                if (targetIdRaw !== undefined && targetIdRaw !== null) {
                    const targetId = typeof targetIdRaw === 'string' ? parseInt(targetIdRaw, 10) : targetIdRaw;
                    // A non-numeric LLM target_id parses to NaN; NaN !== every element id, so it would
                    // fall through to a confusing "id NaN not found". Reject it explicitly (deep-hunt).
                    if (typeof targetId !== 'number' || Number.isNaN(targetId)) {
                        emitter.emit('error', `Invalid non-numeric target id: ${JSON.stringify(targetIdRaw)}.`);
                        return false;
                    }

                    // Translation Layer
                    const el = elements.find(e => e.id === targetId);
                    if (el) {
                        // Safety Sandboxing Check for element content
                        this.checkSafety(el);

                        // Extract bounds center
                        const centerX = el.center.x;
                        const centerY = el.center.y;

                        if (actionType === 'click') {
                            emitter.emit('status', `Tapping target element...`);
                            await this.deviceProvider.click(centerX, centerY);
                            return true;
                        } else {
                            const text = actionObj.text || '';
                            emitter.emit('status', `Typing into element...`);
                            await this.deviceProvider.click(centerX, centerY);
                            await new Promise(res => setTimeout(res, 500));
                            await this.deviceProvider.type(text);
                            return true;
                        }
                    } else {
                        emitter.emit('error', `Element with id ${targetId} not found.`);
                        return false;
                    }
                } else if (actionObj.x !== undefined && actionObj.y !== undefined) {
                    // Validate the LLM-supplied coordinate before it reaches the device. A non-finite or
                    // negative/absurd coordinate (hallucination or injection) should be refused, not piped
                    // into `adb input tap` (deep-hunt). 100000px is far beyond any real display.
                    const { x, y } = actionObj;
                    if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x > 100000 || y > 100000) {
                        emitter.emit('error', `Refusing coordinate action with out-of-range coordinates (${x}, ${y}).`);
                        return false;
                    }

                    emitter.emit('status', `Using spatial vision to locate target...`);

                    // A coordinate (x/y) click otherwise BYPASSES the element-level blocklist — the
                    // agent could tap a "confirm transfer" button by raw pixel instead of by id and
                    // dodge checkSafety. Re-apply it to every UI element the point falls inside (audit MEDIUM).
                    for (const el of this.elementsContaining(x, y, elements)) {
                        this.checkSafety(el);
                    }

                    if (actionType === 'click') {
                        emitter.emit('status', `Tapping spatial coordinate...`);
                        await this.deviceProvider.click(x, y);
                        return true;
                    } else {
                        const text = actionObj.text || '';
                        emitter.emit('status', `Typing at spatial coordinate...`);
                        await this.deviceProvider.click(x, y);
                        await new Promise(res => setTimeout(res, 500));
                        await this.deviceProvider.type(text);
                        return true;
                    }
                } else {
                    emitter.emit('error', `No valid target_id or coordinates provided for ${actionType}.`);
                    return false;
                }
            } else if (actionType === 'scroll') {
                const direction = actionObj.direction || 'down';

                if (direction === 'left' || direction === 'right') {
                    emitter.emit('error', `Horizontal scrolling (${direction}) is not currently supported by the device provider.`);
                    return false;
                }

                emitter.emit('status', `Scrolling ${direction}`);
                await this.deviceProvider.scroll(direction as 'up' | 'down');
                return true;
            } else if (actionType === 'key') {
                // Hardware/navigation keys (back/home/enter) — wires the previously-dead
                // deviceProvider.pressKey() so the agent can dismiss dialogs / submit forms (C8/C9).
                const key = (actionObj.key || '').toLowerCase();
                const allowed = ['back', 'home', 'enter'];
                if (!allowed.includes(key)) {
                    emitter.emit('error', `Unsupported key '${actionObj.key}'. Supported: ${allowed.join(', ')}.`);
                    return false;
                }
                // Safety (H9): `enter` can confirm a dialog the agent was just blocked from clicking
                // (e.g. a payment confirm). If any on-screen element matches the blocklist, refuse the
                // keystroke so it can't bypass the click-level gate. (checkSafety throws → aborts.)
                if (key === 'enter') {
                    for (const el of elements) this.checkSafety(el);
                }
                emitter.emit('status', `Pressing ${key}`);
                await this.deviceProvider.pressKey(key);
                return true;
            }

            emitter.emit('error', `Unknown action type: ${actionType}`);
            return false;

        } catch (error: unknown) {
            const message = error instanceof Error ? error.message : String(error);
            emitter.emit('error', message);
            if (error instanceof SafetyViolationError) {
                throw error; // Re-throw to abort entirely
            }
            return false;
        }
    }
}
