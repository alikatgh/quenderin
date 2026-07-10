import { useState, type ReactNode } from 'react';
import { Check, Copy } from 'lucide-react';
// r23 (C7 re-pass): PrismAsync, not Prism — the sync build put the full 619 kB grammar bundle on
// the STARTUP modulepreload path (it was split into its own chunk, but still eagerly imported).
// The async variant dynamic-imports the highlighter when the first code block actually renders;
// until then the <pre> shows plain text, which is the right trade for first-paint.
import { PrismAsync as SyntaxHighlighter } from 'react-syntax-highlighter';
// Deep-import the one style — the styles barrel would statically anchor the whole package.
import vscDarkPlus from 'react-syntax-highlighter/dist/esm/styles/prism/vsc-dark-plus';

interface CodeBlockProps {
    children?: ReactNode;
    language?: string;
    [key: string]: unknown;
}

export function CodeBlock({ children, language, ...props }: CodeBlockProps) {
    const [copied, setCopied] = useState(false);
    const code = String(children).replace(/\n$/, '');

    const handleCopy = () => {
        navigator.clipboard.writeText(code);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
    };

    return (
        <div className="relative group/code my-4 overflow-hidden rounded-xl border border-zinc-200/50 dark:border-white/5">
            <div className="flex items-center justify-between px-4 py-2 bg-zinc-100 dark:bg-zinc-900 border-b border-zinc-200/50 dark:border-white/5">
                <div className="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">
                    {language || 'code'}
                </div>
                <button
                    onClick={handleCopy}
                    className="flex items-center gap-1.5 px-2 py-1 rounded-md text-[11px] font-medium text-zinc-400 hover:text-zinc-700 dark:hover:text-white hover:bg-zinc-200/50 dark:hover:bg-white/10 transition-all"
                >
                    {copied ? (
                        <>
                            <Check className="w-3 h-3 text-emerald-500" />
                            <span className="text-emerald-500">Copied</span>
                        </>
                    ) : (
                        <>
                            <Copy className="w-3 h-3" />
                            <span>Copy</span>
                        </>
                    )}
                </button>
            </div>
            <SyntaxHighlighter
                {...props}
                children={code}
                style={vscDarkPlus}
                language={language}
                PreTag="div"
                className="!bg-[#09090b] !p-4 !m-0 text-sm font-mono leading-relaxed"
                customStyle={{
                    fontFamily: '"JetBrains Mono", Menlo, Monaco, Consolas, monospace',
                }}
            />
        </div>
    );
}
