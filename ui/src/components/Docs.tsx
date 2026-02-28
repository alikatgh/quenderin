import { useState, useEffect } from 'react';
import { BookOpen, ArrowLeft, ChevronRight, FileText } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

interface DocsProps {
    onBack: () => void;
}

const MENU_ITEMS = [
    { label: 'Introduction', file: 'README.md' },
    { label: 'Quickstart', file: 'QUICKSTART.md' },
    { label: 'Feature Guide', file: 'FEATURES.md' },
    { label: 'Troubleshooting', file: 'TROUBLESHOOTING.md' },
    { label: 'Security', file: 'SECURITY.md' },
    { label: 'Setup Guide', file: 'SETUP.md' }
];

export function Docs({ onBack }: DocsProps) {
    const [activeFile, setActiveFile] = useState<string>('README.md');
    const [markdownData, setMarkdownData] = useState<string>('');
    const [isLoading, setIsLoading] = useState<boolean>(true);

    useEffect(() => {
        let isMounted = true;
        const fetchMarkdown = async () => {
            setIsLoading(true);
            try {
                const response = await fetch(`/api/docs/${activeFile}`);
                if (!response.ok) {
                    throw new Error(`Failed to fetch: ${response.status}`);
                }
                const text = await response.text();
                if (isMounted) setMarkdownData(text);
            } catch (err) {
                console.error("Markdown fetch error:", err);
                if (isMounted) setMarkdownData("### Page Not Found\n\nThe requested document could not be located in the repository.");
            } finally {
                if (isMounted) setIsLoading(false);
            }
        };

        fetchMarkdown();
        return () => { isMounted = false; };
    }, [activeFile]);

    const activeItem = MENU_ITEMS.find(i => i.file === activeFile) || MENU_ITEMS[0];

    return (
        <div className="flex-1 w-full flex bg-white dark:bg-[#18181b] overflow-hidden">
            {/* Left Sidebar Navigation */}
            <aside className="hidden md:flex flex-col w-[250px] flex-shrink-0 border-r border-zinc-200 dark:border-zinc-800 bg-zinc-50/50 dark:bg-[#18181b] overflow-y-auto">
                <div className="p-4 pt-6 border-b border-zinc-200 dark:border-zinc-800">
                    <button
                        onClick={onBack}
                        className="flex items-center gap-2 text-sm font-medium text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 transition-colors w-full px-2 py-1.5 rounded-lg hover:bg-zinc-100 dark:hover:bg-zinc-800/50"
                    >
                        <ArrowLeft className="w-4 h-4" /> Back to Agent
                    </button>
                </div>

                <div className="p-4 space-y-1">
                    <div className="text-xs font-bold tracking-wider text-zinc-400 uppercase mb-3 px-2 mt-4">Getting Started</div>
                    {MENU_ITEMS.map((item) => (
                        <button
                            key={item.file}
                            onClick={() => setActiveFile(item.file)}
                            className={`flex items-center gap-3 w-full text-left px-3 py-2 rounded-lg text-sm transition-all ${activeFile === item.file
                                ? 'bg-zinc-100 dark:bg-zinc-800 text-zinc-900 dark:text-white font-medium shadow-sm border border-zinc-200 dark:border-zinc-700/50'
                                : 'text-zinc-600 dark:text-zinc-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/30 hover:text-zinc-900 dark:hover:text-zinc-300 border border-transparent'
                                }`}
                        >
                            <FileText className={`w-4 h-4 ${activeFile === item.file ? 'text-blue-500' : 'text-zinc-400'}`} />
                            {item.label}
                        </button>
                    ))}
                </div>
            </aside>

            {/* Right Pane Reader */}
            <div className="flex-1 flex flex-col min-w-0 bg-white dark:bg-[#18181b] overflow-y-auto relative">

                {/* Mobile Header (Hidden on Desktop) */}
                <div className="md:hidden sticky top-0 bg-white/90 dark:bg-[#18181b]/90 backdrop-blur-md z-10 border-b border-zinc-200 dark:border-zinc-800 p-4 shrink-0">
                    <button
                        onClick={onBack}
                        className="flex items-center gap-2 text-sm font-medium text-zinc-600 dark:text-zinc-400"
                    >
                        <ArrowLeft className="w-4 h-4" /> Back to Agent
                    </button>
                </div>

                <div className="flex-1 w-full max-w-4xl mx-auto px-6 py-10 md:py-16">
                    {/* Breadcrumbs */}
                    <nav className="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400 mb-8 font-medium">
                        <BookOpen className="w-4 h-4" />
                        <span>Quenderin Docs</span>
                        <ChevronRight className="w-4 h-4 text-zinc-300 dark:text-zinc-600" />
                        <span className="text-zinc-900 dark:text-zinc-200">{activeItem.label}</span>
                    </nav>

                    {isLoading ? (
                        <div className="animate-pulse space-y-6 max-w-2xl">
                            <div className="h-10 bg-zinc-200 dark:bg-zinc-800 rounded-lg w-3/4"></div>
                            <div className="h-4 bg-zinc-200 dark:bg-zinc-800 rounded w-full"></div>
                            <div className="h-4 bg-zinc-200 dark:bg-zinc-800 rounded w-5/6"></div>
                            <div className="h-4 bg-zinc-200 dark:bg-zinc-800 rounded w-4/6"></div>
                            <div className="h-32 bg-zinc-200 dark:bg-zinc-800 rounded-xl w-full mt-8"></div>
                        </div>
                    ) : (
                        <div className="prose prose-zinc dark:prose-invert prose-blue max-w-none w-full animate-in fade-in duration-500 pb-32">
                            <ReactMarkdown remarkPlugins={[remarkGfm]}>
                                {markdownData}
                            </ReactMarkdown>
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}
