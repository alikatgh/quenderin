/**
 * Project/Context Presets (ported from off-grid-mobile pattern)
 *
 * Each preset defines a system prompt persona, temperature, and max tokens.
 * Users can switch presets to tailor the assistant to specific tasks.
 * Presets are hardware-aware: on embedded/constrained tiers, system prompts
 * are shortened and maxTokens reduced to fit small context windows.
 */
import { getHardwareProfile, type HardwareTier } from '../utils/hardware.js';

export interface Preset {
    id: string;
    label: string;
    description: string;
    icon: string;        // Lucide icon name for UI
    systemPrompt: string;
    temperature: number;
    maxTokens: number;
}

/** Scale preset maxTokens and trim system prompts for constrained hardware */
function adaptPreset(preset: Preset, tier: HardwareTier): Preset {
    if (tier === 'powerful' || tier === 'standard') return preset;

    const tokenScale = tier === 'embedded' ? 0.25 : 0.5; // constrained
    const maxPromptChars = tier === 'embedded' ? 80 : 150;

    return {
        ...preset,
        maxTokens: Math.max(64, Math.round(preset.maxTokens * tokenScale)),
        // Trim system prompt to save context tokens on tiny models
        systemPrompt: preset.systemPrompt.length > maxPromptChars
            ? preset.systemPrompt.slice(0, maxPromptChars).replace(/\s+\S*$/, '') + '.'
            : preset.systemPrompt,
    };
}

export const DEFAULT_PRESETS: Preset[] = [
    {
        id: 'general',
        label: 'General Assistant',
        description: 'Helpful all-purpose assistant',
        icon: 'MessageSquareText',
        systemPrompt: 'You are Quenderin, a helpful, intelligent, and offline AI assistant running locally on the user\'s hardware. You are friendly, highly capable, and concise. Format your responses in beautiful Markdown.',
        temperature: 0.7,
        maxTokens: 2048,
    },
    {
        id: 'code-review',
        label: 'Code Review',
        description: 'Thorough code reviewer with best-practice focus',
        icon: 'Code',
        systemPrompt: 'You are a senior software engineer performing a code review. Be thorough, point out bugs, security issues, and suggest improvements. Use Markdown code blocks for suggestions. Be direct and precise.',
        temperature: 0.3,
        maxTokens: 2048,
    },
    {
        id: 'creative-writer',
        label: 'Creative Writer',
        description: 'Imaginative writer for stories, emails, and content',
        icon: 'PenTool',
        systemPrompt: 'You are a creative writing assistant. Help the user write compelling stories, emails, blog posts, and other content. Be imaginative, expressive, and adapt to the requested style and tone.',
        temperature: 0.9,
        maxTokens: 2048,
    },
    {
        id: 'tutor',
        label: 'Tutor',
        description: 'Patient teacher that explains concepts clearly',
        icon: 'GraduationCap',
        systemPrompt: 'You are a patient, encouraging tutor. Break down complex topics into simple explanations. Use analogies, examples, and step-by-step walkthroughs. Ask follow-up questions to check understanding. Format math with LaTeX when appropriate.',
        temperature: 0.5,
        maxTokens: 2048,
    },
    {
        id: 'summarizer',
        label: 'Summarizer',
        description: 'Concise summarizer for long content',
        icon: 'FileText',
        systemPrompt: 'You are a concise summarizer. When given text, provide a clear, structured summary with key points. Use bullet points and headers. Focus on the most important information. Be brief but thorough.',
        temperature: 0.3,
        maxTokens: 1024,
    },
];

/** Retrieve a preset by ID, falling back to the general preset.
 *  Automatically adapts maxTokens and system prompt for the detected hardware tier. */
export function getPresetById(id: string): Preset {
    const base = DEFAULT_PRESETS.find(p => p.id === id) ?? DEFAULT_PRESETS[0];
    const hw = getHardwareProfile();
    return adaptPreset(base, hw.tier);
}
