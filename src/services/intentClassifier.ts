/**
 * Intent Classifier (ported from off-grid-mobile pattern)
 *
 * Classifies user messages into intents using regex-first approach with
 * optional LLM fallback. Results are cached for repeated patterns.
 */
import logger from '../utils/logger.js';

export type Intent = 'action' | 'code' | 'chat' | 'math' | 'image';

interface ClassificationResult {
    intent: Intent;
    confidence: 'high' | 'medium' | 'low';
    source: 'regex' | 'llm' | 'default';
}

// ─── Regex Pattern Banks ────────────────────────────────────────────────────

const ACTION_PATTERNS = [
    /\b(open|tap|click|press|swipe|scroll|navigate|go to|launch|find|search for)\b/i,
    /\b(start|stop|enable|disable|turn on|turn off|install|uninstall)\b/i,
    /\b(on my phone|on the screen|in the app|on device)\b/i,
];

const CODE_PATTERNS = [
    /\b(write|generate|create|build|implement|code|refactor|debug|fix the code|function|class|component)\b.*\b(code|script|function|api|endpoint|module|program|app)\b/i,
    /\b(python|javascript|typescript|rust|java|swift|kotlin|react|node|express)\b.*\b(code|script|function|app)\b/i,
    /```[\s\S]*```/,   // contains code block
    /\b(write a|create a|build a|generate a)\b.*\b(script|program|function|api|bot|tool)\b/i,
];

const MATH_PATTERNS = [
    /\b(calculate|compute|solve|evaluate|what is|how much is)\b.*[\d+*()^%/-]/i,
    /^\s*[\d+*().^%/\s-]+\s*$/,     // pure math expression
    /\b(math|equation|formula|derivative|integral|factorial)\b/i,
    /\b(sqrt|sin|cos|tan|log|ln|abs)\b\s*\(/i,
];

const IMAGE_PATTERNS = [
    /\b(draw|generate|create|make)\b.*\b(image|picture|illustration|art|photo|graphic)\b/i,
    /\b(visualize|render|design)\b.*\b(diagram|chart|graph|ui|mockup|layout)\b/i,
];

// ─── Cache ──────────────────────────────────────────────────────────────────

const cache = new Map<string, ClassificationResult>();
const MAX_CACHE_SIZE = 200;

function cacheKey(input: string): string {
    return input.toLowerCase().trim().slice(0, 200);
}

// ─── Classifier ─────────────────────────────────────────────────────────────

/** Classify a user message intent using regex patterns (fast, no LLM needed) */
export function classifyIntent(input: string): ClassificationResult {
    const key = cacheKey(input);
    const cached = cache.get(key);
    if (cached) return cached;

    const result = runRegexClassification(input);

    // Cache result (evict oldest if full)
    if (cache.size >= MAX_CACHE_SIZE) {
        const firstKey = cache.keys().next().value;
        if (firstKey !== undefined) cache.delete(firstKey);
    }
    cache.set(key, result);

    logger.log(`[Intent] "${input.slice(0, 60)}..." → ${result.intent} (${result.confidence}, ${result.source})`);
    return result;
}

function runRegexClassification(input: string): ClassificationResult {
    // Check math first (most specific patterns)
    if (MATH_PATTERNS.some(p => p.test(input))) {
        return { intent: 'math', confidence: 'high', source: 'regex' };
    }

    // Then code
    if (CODE_PATTERNS.some(p => p.test(input))) {
        return { intent: 'code', confidence: 'high', source: 'regex' };
    }

    // Then action (device interaction)
    if (ACTION_PATTERNS.some(p => p.test(input))) {
        return { intent: 'action', confidence: 'medium', source: 'regex' };
    }

    // Then image generation
    if (IMAGE_PATTERNS.some(p => p.test(input))) {
        return { intent: 'image', confidence: 'medium', source: 'regex' };
    }

    // Default to chat
    return { intent: 'chat', confidence: 'low', source: 'default' };
}

/**
 * LLM-based fallback classifier (for when regex confidence is 'low').
 * Takes a classify function that wraps LLM prompt.
 */
export async function classifyWithLlmFallback(
    input: string,
    llmClassify: (prompt: string) => Promise<string>
): Promise<ClassificationResult> {
    // Try regex first
    const regexResult = classifyIntent(input);
    if (regexResult.confidence === 'high' || regexResult.confidence === 'medium') {
        return regexResult;
    }

    // LLM fallback for low-confidence classifications
    try {
        const classifierPrompt = `Classify this user request into exactly one category: ACTION, CODE, CHAT, MATH, or IMAGE.
- ACTION: User wants to interact with a device (tap, open, navigate)
- CODE: User wants code generated or debugged
- CHAT: General conversation or knowledge questions
- MATH: Mathematical calculations
- IMAGE: Image/visual generation requests

User request: "${input.slice(0, 500)}"

Reply with exactly one word: ACTION, CODE, CHAT, MATH, or IMAGE.`;

        const llmResponse = await llmClassify(classifierPrompt);
        const parsed = llmResponse.trim().toUpperCase();

        const intentMap: Record<string, Intent> = {
            'ACTION': 'action',
            'CODE': 'code',
            'CHAT': 'chat',
            'MATH': 'math',
            'IMAGE': 'image',
        };

        const mapped = intentMap[parsed];
        if (mapped) {
            const result: ClassificationResult = { intent: mapped, confidence: 'medium', source: 'llm' };
            const key = cacheKey(input);
            cache.set(key, result);
            return result;
        }
    } catch (err) {
        logger.warn('[Intent] LLM fallback failed, using regex result:', err);
    }

    return regexResult;
}

/** Clear the classification cache (useful on preset switch) */
export function clearIntentCache(): void {
    cache.clear();
}
