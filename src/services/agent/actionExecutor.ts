import { AgentEvents, UIElement, IDeviceProvider, AgentAction } from '../../types/index.js';
import { AgentEventEmitter } from '../agent.service.js';

export class SafetyViolationError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'SafetyViolationError';
    }
}

export class ActionExecutor {
    private readonly BLOCKLIST = ['pay', 'delete', 'password', 'buy', 'confirm purchase'];

    constructor(private deviceProvider: IDeviceProvider) { }

    private checkSafety(el: UIElement | undefined, inputText?: string) {
        const textToCheck = [
            el?.text,
            el?.contentDesc,
            inputText
        ].filter(Boolean).map(t => t!.toLowerCase());

        for (const word of this.BLOCKLIST) {
            const lowerWord = word.toLowerCase();
            for (const text of textToCheck) {
                if (text.includes(lowerWord)) {
                    throw new SafetyViolationError(`Safety Block: Refusing to interact with potentially destructive context matching '${word}'.`);
                }
            }
        }
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
                    emitter.emit('status', `Using spatial vision to locate target...`);

                    if (actionType === 'click') {
                        emitter.emit('status', `Tapping spatial coordinate...`);
                        await this.deviceProvider.click(actionObj.x, actionObj.y);
                        return true;
                    } else {
                        const text = actionObj.text || '';
                        emitter.emit('status', `Typing at spatial coordinate...`);
                        await this.deviceProvider.click(actionObj.x, actionObj.y);
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
            }

            emitter.emit('error', `Unknown action type: ${actionType}`);
            return false;

        } catch (error: any) {
            emitter.emit('error', error.message);
            if (error instanceof SafetyViolationError) {
                throw error; // Re-throw to abort entirely
            }
            return false;
        }
    }
}
