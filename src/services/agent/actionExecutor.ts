import { AgentEvents, UIElement, IDeviceProvider, AgentAction } from '../../types/index.js';
import { AgentEventEmitter } from '../agent.service.js';

export class ActionExecutor {
    constructor(private deviceProvider: IDeviceProvider) { }

    public async execute(actionObj: AgentAction, elements: UIElement[], emitter: AgentEventEmitter): Promise<boolean> {
        const actionType = actionObj.action;
        emitter.emit('action', actionType);

        if (actionType === 'done') {
            emitter.emit('status', `Goal achieved successfully.`);
            emitter.emit('done');
            return true;
        }

        if (actionType === 'click') {
            if (actionObj.x !== undefined && actionObj.y !== undefined) {
                emitter.emit('status', `Warning: Coordinate-based action bypasses UI text safety blocklist. Relying on VLM alignment.`);
                emitter.emit('status', `Clicking coordinate dynamically (${actionObj.x}, ${actionObj.y})`);
                await this.deviceProvider.click(actionObj.x, actionObj.y);
                return true;
            }

            const targetId = actionObj.id;
            const el = elements.find(e => e.id === targetId);
            if (el) {
                // Safety Sandboxing Check
                const blocklist = ['pay', 'buy', 'delete', 'remove', 'password', 'transfer'];
                const isBlocked = blocklist.some(word =>
                    (el.text && el.text.toLowerCase().includes(word)) ||
                    (el.contentDesc && el.contentDesc.toLowerCase().includes(word))
                );

                if (isBlocked) {
                    emitter.emit('error', `Safety Block: Refusing to interact with potentially destructive element [${el.text}].`);
                    return false;
                }

                emitter.emit('status', `Clicking dynamically on element ${targetId} at (${el.center.x}, ${el.center.y})`);
                await this.deviceProvider.click(el.center.x, el.center.y);
                return true;
            } else {
                emitter.emit('error', `Element with id ${targetId} not found.`);
                return false;
            }
        } else if (actionType === 'input') {
            const text = actionObj.text || '';

            if (actionObj.x !== undefined && actionObj.y !== undefined) {
                emitter.emit('status', `Warning: Coordinate-based action bypasses UI text safety blocklist. Relying on VLM alignment.`);
                emitter.emit('status', `Typing at coordinate (${actionObj.x}, ${actionObj.y})`);
                await this.deviceProvider.click(actionObj.x, actionObj.y);
                await new Promise(res => setTimeout(res, 500));
                await this.deviceProvider.type(text);
                return true;
            }

            const targetId = actionObj.id;
            const el = elements.find(e => e.id === targetId);
            if (el) {
                emitter.emit('status', `Typing into element ${targetId}`);
                await this.deviceProvider.click(el.center.x, el.center.y);
                // Simple delay for keyboard to appear
                await new Promise(res => setTimeout(res, 500));
                await this.deviceProvider.type(text);
                return true;
            } else {
                emitter.emit('error', `Element with id ${targetId} not found for input.`);
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
    }
}
