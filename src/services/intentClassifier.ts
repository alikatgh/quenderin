/**
 * Intent Classifier (ported from off-grid-mobile pattern)
 *
 * The SINGLE intent classifier: a fast, LLM-free regex pass that labels a user message
 * action | code | chat | math | image (with a confidence). Results are cached for repeated patterns.
 *
 * Q-637: this used to ALSO ship a `classifyWithLlmFallback` — a second, divergent LLM classifier with
 * its OWN 5-category prompt that no production code called. It was removed: it could only drift against
 * the one LLM intent step that IS live — the agent loop's chat-vs-action `INTENT_CLASSIFIER_PROMPT`
 * (agent.service.ts), which runs regex-first (this module) and only calls the LLM to break a
 * low-confidence tie. The WebSocket chat path uses this regex result directly (surfaced to the UI as
 * routing info). Keep it this way: one regex classifier here, one LLM tiebreak in the agent — no third.
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

/** djb2 hash → compact, collision-resistant key material for the intent cache. */
function hashString(s: string): string {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
}

function cacheKey(input: string): string {
    // Q-635: key on the WHOLE normalized message (length + hash), not its first 200 chars — two long
    // messages that share a 200-char prefix but diverge later must NOT collide to one cached intent.
    const norm = input.toLowerCase().trim();
    return `${norm.length}:${hashString(norm)}`;
}

/** Bounded insert — evict the oldest entry when full so the cache can't grow past MAX_CACHE_SIZE.
 *  The one write path (classifyIntent) goes through this, so a long session of distinct messages can't
 *  leak the cache unbounded. (Historically a second, LLM-fallback path `cache.set` here directly and
 *  leaked; that path was removed in Q-637, but the bound stays as the single insert's guarantee.) */
function setCached(key: string, result: ClassificationResult): void {
    if (cache.size >= MAX_CACHE_SIZE && !cache.has(key)) {
        const firstKey = cache.keys().next().value;
        if (firstKey !== undefined) cache.delete(firstKey);
    }
    cache.set(key, result);
}

// ─── Classifier ─────────────────────────────────────────────────────────────

/** Classify a user message intent using regex patterns (fast, no LLM needed) */
export function classifyIntent(input: string): ClassificationResult {
    const key = cacheKey(input);
    const cached = cache.get(key);
    if (cached) return cached;

    const result = runRegexClassification(input);
    setCached(key, result);

    // Q-636: log the OUTCOME + message LENGTH only, never the content — the classifier sees EVERY user
    // message, so a plaintext snippet in the logs is a privacy leak (same rule as Q-357 / Q-644).
    logger.log(`[Intent] ${input.length} chars → ${result.intent} (${result.confidence}, ${result.source})`);
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

/** Clear the classification cache (useful on preset switch) */
export function clearIntentCache(): void {
    cache.clear();
}

/** Current cache size — exported so tests can assert the MAX_CACHE_SIZE bound holds on both paths. */
export function intentCacheSize(): number {
    return cache.size;
}
