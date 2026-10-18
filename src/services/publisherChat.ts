import { generateLocalTokens } from './localTokenGeneration.js';
/** Pinned publisher text protocols. Tools, grammar and multimodal turns are deliberately absent. */
export type PublisherFamily = 'beam' | 'muse';
export interface PublisherTurn { role: 'user' | 'assistant'; text: string; reasoning?: string }
const escape = (text: string) => text.replaceAll('<|', '< |').replace(/<(image|video|audio)>/g, '< $1>');

export function publisherPrompt(family: PublisherFamily, system: string, history: readonly PublisherTurn[]): string {
    if (family === 'beam') {
        let prompt = '<|start|>system<|message|>You are Beam, an AI assistant trained by Reflection.\n\nReasoning effort: 8'
            + '\n\n# Valid channels: analysis, final. Channel must be included for every message.<|end|>';
        if (system) prompt += '<|start|>developer<|message|># Instructions\n\n' + escape(system) + '<|end|>';
        for (const turn of history) {
            if (turn.role === 'user') prompt += '<|start|>user<|message|>' + escape(turn.text) + '<|end|>';
            // Official allow_missing_thinking=true policy for restored final-only turns;
            // preserve transient reasoning when this live session has it.
            else prompt += '<|start|>assistant<|channel|>analysis<|message|>' + escape(turn.reasoning ?? '') + '<|end|>'
                + '<|start|>assistant<|channel|>final<|message|>' + escape(turn.text) + '<|return|>';
        }
        return prompt + '<|start|>assistant';
    }
    const guide = 'Reasoning strength: 16.\nUse to=self for private reasoning and to=user for the final answer.';
    return '<|begin_of_text|><|start|>system<|message|>' + escape((system ? system + '\n\n' : '') + guide) + '<|eot|>'
        + history.map(turn => '<|start|>' + (turn.role === 'assistant' ? 'assistant to=user' : 'user')
            + '<|message|>' + escape(turn.text) + '<|eot|>').join('') + '<|start|>assistant';
}

/** Incremental fail-closed channel parser; never buffers an unbounded header or emits wire tags. */
export class PublisherOutputFilter {
    private state: 'header' | 'body' | 'next' | 'stopped' = 'header';
    private buffer = '';
    private visible = false;
    reasoning = '';
    get stopped(): boolean { return this.state === 'stopped'; }
    constructor(private readonly family: PublisherFamily) {}
    private stop(): void { this.state = 'stopped'; this.buffer = ''; }
    feed(text: string): string {
        if (this.stopped) return '';
        if (text.length > 1_048_576) { this.stop(); return ''; }
        this.buffer += text;
        let output = '';
        const body = (value: string) => {
            if (this.visible) output += value;
            else if (this.family === 'beam') {
                if (this.reasoning.length + value.length > 262_144) this.stop();
                else this.reasoning += value;
            }
        };
        while (this.buffer && !this.stopped) {
            if (this.state === 'header') {
                const end = this.buffer.indexOf('<|message|>');
                if (end < 0) { if (this.buffer.length > 1024) this.stop(); break; }
                if (end > 1024) { this.stop(); break; }
                const header = this.buffer.slice(0, end).trim();
                if (this.family === 'beam') {
                    if (header !== '<|channel|>analysis' && header !== '<|channel|>final') { this.stop(); break; }
                    this.visible = header === '<|channel|>final';
                } else {
                    if (!['', 'to=user', 'to=self', 'to=commentary'].includes(header)) { this.stop(); break; }
                    this.visible = header === '' || header === 'to=user';
                }
                this.buffer = this.buffer.slice(end + 11); this.state = 'body';
            } else if (this.state === 'next') {
                const prefix = '<|start|>assistant';
                if (this.buffer.length < prefix.length) { if (!prefix.startsWith(this.buffer)) this.stop(); break; }
                if (!this.buffer.startsWith(prefix)) { this.stop(); break; }
                this.buffer = this.buffer.slice(prefix.length); this.state = 'header';
            } else {
                const start = this.buffer.indexOf('<|');
                if (start < 0) {
                    const held = this.buffer.endsWith('<') ? '<' : '';
                    body(this.buffer.slice(0, this.buffer.length - held.length)); this.buffer = held; break;
                }
                body(this.buffer.slice(0, start));
                if (this.stopped) break;
                this.buffer = this.buffer.slice(start);
                const end = this.buffer.indexOf('|>');
                if (end < 0) { if (this.buffer.length > 128) this.stop(); break; }
                const token = this.buffer.slice(0, end + 2); this.buffer = this.buffer.slice(end + 2);
                if (token === (this.family === 'beam' ? '<|end|>' : '<|eom|>')) this.state = 'next';
                else this.stop(); // return/eot, tool calls and malformed tokens all halt.
            }
        }
        return output;
    }
    finish(): string { this.stop(); return ''; }
}

/** Actual Node evaluator adapter, shared by LlmService and model-free integration fixtures. */
export class PublisherChatSession {
    private history: PublisherTurn[] = [];
    constructor(private readonly family: PublisherFamily, private readonly sequence: any,
        private readonly system: string, private readonly bindings: any) {

    }
    dispose(): void { this.history = []; void Promise.resolve(this.sequence.dispose()).catch(() => {}); }
    getChatHistory(): PublisherTurn[] { return this.history.map(turn => ({ ...turn })); }
    setChatHistory(history: PublisherTurn[]): void { this.history = history.map(turn => ({ ...turn })); }
    async prompt(text: string, options: any): Promise<string> {
        if (options.grammar || (options.functions && Object.keys(options.functions).length)) throw new Error('This experimental model supports text chat only.');
        const maxTokens = Math.max(1, Math.min(2048, options.maxTokens ?? 512));
        const turns: PublisherTurn[] = [...this.history, { role: 'user', text }];
        const { LlamaText, SpecialTokensText } = this.bindings;
        let prompt: any;
        while (true) {
            prompt = LlamaText(new SpecialTokensText(publisherPrompt(this.family, this.system, turns)));
            if (prompt.tokenize(this.sequence.model.tokenizer).length + maxTokens <= this.sequence.contextSize) break;
            if (turns.length <= 1) throw new Error('This message exceeds the experimental model context budget.');
            turns.splice(0, 2);
        }
        const filter = new PublisherOutputFilter(this.family);
        let final = '';
        await generateLocalTokens(this.sequence, prompt.tokenize(this.sequence.model.tokenizer), {
            maxTokens, temperature: options.temperature ?? 0.7, signal: options.signal, repeatPenalty: options.repeatPenalty,
        }, piece => {
            const visible = filter.feed(piece);
            final += visible;
            if (visible) options.onTextChunk?.(visible);
            return !filter.stopped;
        });
        filter.finish();
        if (!final) throw new Error('Generation ended before producing a final-channel answer.');
        this.history = [...turns, { role: 'assistant' as const, text: final, ...(this.family === 'beam' ? { reasoning: filter.reasoning } : {}) }].slice(-32);
        return final;
    }
}
