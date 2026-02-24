import { AgentEvents, UIElement, IDeviceProvider } from '../../types/index.js';
import { AgentEventEmitter } from '../agent.service.js';

export class ActionExecutor {
    constructor(private deviceProvider: IDeviceProvider) { }

    public async execute(actionObj: any, elements: UIElement[], emitter: AgentEventEmitter): Promise<boolean> {
        const actionType = actionObj.action;
        emitter.emit('action', actionType);

        if (actionType === 'done') {
            emitter.emit('status', `Goal achieved successfully.`);
            emitter.emit('done');
            return true;
        }

        if (actionType === 'click') {
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
            const targetId = actionObj.id;
            const text = actionObj.text;
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
            emitter.emit('status', `Scrolling ${direction}`);

            await this.deviceProvider.scroll(direction);
            return true;
        }

        emitter.emit('error', `Unknown action type: ${actionType}`);
        return false;
    }
}
