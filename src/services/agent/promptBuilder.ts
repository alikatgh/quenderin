import { MemoryService } from '../memory.service.js';

export class PromptBuilder {
    constructor(private memoryService: MemoryService) { }

    public async buildEnvironment(goal: string, textRepresentation: string, actionHistory: string[]): Promise<string> {
        let memoryPromptAddition = "";

        // Trajectory Memory check
        const pastMemory = await this.memoryService.findSimilarGoal(goal);
        if (pastMemory) {
            memoryPromptAddition = `\n\n[SYSTEM WARNING]: You have successfully solved a similar goal in the past. Your previous winning trajectory was:\n${pastMemory.actions.join('\n')}\nConsider following this known-good sequence.`;
        }

        const historyText = actionHistory.length > 0 ? `\n\nRecent Actions:\n${actionHistory.slice(-5).join('\n')}` : '';

        const prompt = `Current UI State:\n${textRepresentation}${historyText}${memoryPromptAddition}\n\nUser Goal: ${goal}\n\nWhat is your next JSON action?`;

        return prompt;
    }
}
