import { MemoryService } from '../memory.service.js';

export class PromptBuilder {
    constructor(private memoryService: MemoryService) { }

    public async buildEnvironment(goal: string, textRepresentation: string, actionHistory: string[]): Promise<string> {
        let memoryPromptAddition = "";

        // 1. Trajectory Memory Check (Exact Goal Match)
        const pastMemory = await this.memoryService.findSimilarGoal(goal);
        if (pastMemory) {
            memoryPromptAddition += `\n\n[SYSTEM WARNING]: You have successfully solved a similar goal in the past. Your previous winning trajectory was:\n${pastMemory.actions.join('\n')}\nConsider following this known-good sequence.`;
        }

        // 2. Self-Correction RAG (Semantic UI Match)
        const relevantCorrections = await this.memoryService.findRelevantCorrections(textRepresentation);
        if (relevantCorrections && relevantCorrections.length > 0) {
            const rules = relevantCorrections.map(c => `- ${c.correctionString}`).join('\n');
            memoryPromptAddition += `\n\n[CRITICAL USER CORRECTIONS FOR THIS CONTEXT]:\nThe user has previously corrected you on a screen identical to this one. YOU MUST OBEY THESE RULES FOREVER:\n${rules}`;
        }

        const historyText = actionHistory.length > 0 ? `\n\nRecent Actions:\n${actionHistory.slice(-5).join('\n')}` : '';

        const prompt = `Current UI State:\n${textRepresentation}${historyText}${memoryPromptAddition}\n\nUser Goal: ${goal}\n\n[INSTRUCTION]: Determine the next step. If the UI State lacks XML structure (e.g., Desktop environment or raw screenshot), you MUST analyze the image visually to determine exact coordinates, outputting {"action": "click", "x": 450, "y": 800} instead of an id. \n\nWhat is your next JSON action?`;

        return prompt;
    }
}
