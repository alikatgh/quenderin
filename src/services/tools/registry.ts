/**
 * Tool Registry — Defines available tools and their schemas
 *
 * Based on off-grid-mobile's tool calling pattern.
 * Tools are registered with name, description, parameters schema, and handler reference.
 */
import { getHardwareProfile } from '../../utils/hardware.js';

const HW = getHardwareProfile();

/** Q-639: the ONE source of truth for how many tool calls a single response may make — the tool prompt
 *  TELLS the model this number, and the executor ENFORCES it. They were out of sync (prompt said 1/2/3
 *  by tier, the executor hardcoded 5), so a weak model could emit more calls than promised and have them
 *  silently run. Scales down on constrained hardware (fewer, cheaper tool round-trips). */
export function maxToolCallsPerResponse(): number {
    return HW.tier === 'embedded' ? 1 : HW.tier === 'constrained' ? 2 : 3;
}

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
    {
        name: 'read_file',
        description: 'Read the text contents of a file on the local filesystem. Only files inside the user\'s home directory are allowed. Truncated at 8000 characters.',
        parameters: [
            { name: 'path', type: 'string', description: 'Absolute or ~ path to the file to read', required: true }
        ]
    },
    {
        name: 'note_save',
        description: 'Save a named note to persistent local storage (~/.quenderin/notes/). Useful for remembering information across conversations.',
        parameters: [
            { name: 'title', type: 'string', description: 'Short title for the note (used as filename)', required: true },
            { name: 'content', type: 'string', description: 'The text content to save', required: true }
        ]
    },
    {
        name: 'note_list',
        description: 'List all saved notes with their titles, creation dates, and first 100 characters of content.',
        parameters: []
    },
    {
        name: 'unit_convert',
        description: 'Convert between common units fully offline — length (m, km, cm, mm, mi, ft, in, yd), mass (g, kg, mg, lb, oz), volume (l, ml, gal, floz), speed (mps, kph, mph), and temperature (C, F, K). Phrase the request as "<value> <from> to <to>", e.g. "20 km to mi", "30 C in F", "5 kg to lb".',
        parameters: [
            { name: 'expression', type: 'string', description: 'The conversion to perform, e.g. "20 km to mi"', required: true }
        ]
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

You may use up to ${maxToolCallsPerResponse()} tool calls per response. After using a tool, the result will be provided and you should incorporate it into your answer.
If you don't need any tools, just respond normally without tool call tags.`;
}
