/** Jais 3's low-reasoning prompt ends in an open think_faster segment. Keep that
 * private across arbitrary token boundaries. An incomplete final channel stays hidden. */
export class JaisFinalChannelFilter {
    private pending = '';
    private hidden = true;
    private stopped = false;
    private readonly closers = ['</ifm|think>', '</ifm|think_faster>', '</ifm|think_fast>'];
    private readonly openers = ['<ifm|think>', '<ifm|think_faster>', '<ifm|think_fast>'];
    private readonly ends = ['<|ifm|im_end|>', '<|ifm|im_start|>', '<|end_of_text|>'];

    feed(chunk: string): string {
        if (this.stopped) return '';
        this.pending += chunk;
        let output = '';
        while (this.pending) {
            const tokens = this.hidden ? [...this.closers, ...this.ends] : [...this.openers, ...this.ends];
            const matches = tokens.map(token => ({ token, index: this.pending.indexOf(token) }))
                .filter(match => match.index >= 0).sort((a, b) => a.index - b.index);
            if (matches.length) {
                const { token, index } = matches[0];
                if (!this.hidden) output += this.pending.slice(0, index);
                this.pending = this.pending.slice(index + token.length);
                if (this.ends.includes(token)) { this.stopped = true; this.pending = ''; break; }
                this.hidden = !this.hidden;
            } else {
                // Retain only a possible partial delimiter, never an unbounded reasoning buffer.
                let held = 0;
                for (const token of tokens) {
                    for (let n = 1; n < token.length && n <= this.pending.length; n++) {
                        if (this.pending.endsWith(token.slice(0, n))) held = Math.max(held, n);
                    }
                }
                if (!this.hidden) output += this.pending.slice(0, this.pending.length - held);
                this.pending = held ? this.pending.slice(-held) : '';
                break;
            }
        }
        return output;
    }

    finish(): string { this.pending = ''; this.stopped = true; return ''; }

    static finalText(wire: string): string {
        const filter = new JaisFinalChannelFilter();
        return (filter.feed(wire) + filter.finish()).trim();
    }
}
