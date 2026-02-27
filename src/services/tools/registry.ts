/**
 * Tool Registry — Defines available tools and their schemas
 *
 * Based on off-grid-mobile's tool calling pattern.
 * Tools are registered with name, description, parameters schema, and handler reference.
 */

export interface ToolParameter {
    name: string;
    type: 'string' | 'number' | 'boolean';
    description: string;
    required: boolean;
}

export interface ToolDefinition {
    name: string;
    description: string;
    parameters: ToolParameter[];
}

export interface ToolCall {
    tool: string;
    args: Record<string, unknown>;
}

export interface ToolResult {
    tool: string;
    success: boolean;
    result: string;
    error?: string;
}

/** All available tools — sent to the LLM as context */
export const AVAILABLE_TOOLS: ToolDefinition[] = [
    {
        name: 'calculator',
        description: 'Evaluate a mathematical expression safely. Supports +, -, *, /, ^, %, sqrt(), sin(), cos(), tan(), log(), ln(), abs(), pi, e.',
        parameters: [
            { name: 'expression', type: 'string', description: 'The math expression to evaluate', required: true }
        ]
    },
    {
        name: 'datetime',
        description: 'Get the current date and time in the user\'s timezone.',
        parameters: []
    },
    {
        name: 'system_info',
        description: 'Get system information: OS, architecture, CPU count, total RAM, free RAM.',
        parameters: []
    },
];

/** Build a tool description block for the system prompt */
export function buildToolPrompt(): string {
    const toolDescriptions = AVAILABLE_TOOLS.map(t => {
        const params = t.parameters.length > 0
            ? `Parameters: ${t.parameters.map(p => `${p.name} (${p.type}${p.required ? ', required' : ''}): ${p.description}`).join('; ')}`
            : 'No parameters.';
        return `- ${t.name}: ${t.description}\n  ${params}`;
    }).join('\n');

    return `You have access to the following tools. To use a tool, include a tool call in your response using this XML format:
<tool_call>
<name>tool_name</name>
<args>{"param": "value"}</args>
</tool_call>

Available tools:
${toolDescriptions}

You may use up to 3 tool calls per response. After using a tool, the result will be provided and you should incorporate it into your answer.
If you don't need any tools, just respond normally without tool call tags.`;
}
