import { useState, useEffect } from 'react';
import { FileText, ChevronDown, ChevronRight, Trash2 } from 'lucide-react';
import { apiFetch } from '../../lib/api.js';

/**
 * Saved Notes panel — extracted from SettingsArea (r38/r44 split, 2026-07-11). Self-contained:
 * lazy-fetches on first expand, deletes only on confirmed 2xx (Q-529). Moved verbatim.
 */
export function NotesSection() {
    const [notes, setNotes] = useState<{ filename: string; title: string; preview: string; modifiedAt: number; sizeBytes: number }[]>([]);
    const [notesOpen, setNotesOpen] = useState(false);
    const [deletingNote, setDeletingNote] = useState<string | null>(null);

    useEffect(() => {
        if (notesOpen) {
            apiFetch('/api/notes').then(r => r.ok ? r.json() : null).then(d => { if (d?.notes) setNotes(d.notes); }).catch(() => {});
        }
    }, [notesOpen]);

    const handleDeleteNote = async (filename: string) => {
        setDeletingNote(filename);
        // Q-529: only drop the note from the UI when the DELETE actually succeeded. The old optimistic
        // remove made a failed delete look successful — the note silently reappeared on the next refresh.
        const ok = await apiFetch(`/api/notes/${encodeURIComponent(filename)}`, { method: 'DELETE' })
            .then(r => r.ok)
            .catch(() => false);
        if (ok) setNotes(prev => prev.filter(n => n.filename !== filename));
        setDeletingNote(null);
    };

    return (
        <section className="premium-card p-6">
            <button
                type="button"
                aria-expanded={notesOpen}
                onClick={() => setNotesOpen(o => !o)}
                className="w-full flex items-center justify-between rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-purple-500/40"
            >
                <div className="flex items-center gap-3">
                    <FileText className="w-5 h-5 text-blue-500" />
                    <div className="text-left">
                        <h2 className="text-[15px] font-semibold text-zinc-900 dark:text-white">Saved Notes</h2>
                        <p className="text-[12px] text-zinc-500 dark:text-zinc-400">Notes written by the AI using the note_save tool.</p>
                    </div>
                </div>
                {notesOpen ? <ChevronDown className="w-4 h-4 text-zinc-400" /> : <ChevronRight className="w-4 h-4 text-zinc-400" />}
            </button>
            {notesOpen && (
                <div className="mt-5">
                    {notes.length === 0 ? (
                        <p className="text-sm text-zinc-500 dark:text-zinc-400 text-center py-6">No notes saved yet. Ask the AI to "save a note about..."</p>
                    ) : (
                        <div className="space-y-2">
                            {notes.map(note => (
                                <div key={note.filename} className="flex items-start justify-between gap-3 p-3 rounded-xl bg-zinc-50 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800">
                                    <div className="min-w-0 flex-1">
                                        <p className="text-[13px] font-semibold text-zinc-900 dark:text-zinc-100 truncate">{note.title}</p>
                                        <p className="text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5 line-clamp-2">{note.preview}</p>
                                        <p className="text-[10px] text-zinc-400 dark:text-zinc-500 mt-1 tabular-nums">{new Date(note.modifiedAt).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })} · {(note.sizeBytes / 1024).toFixed(1)} KB</p>
                                    </div>
                                    <button
                                        onClick={() => handleDeleteNote(note.filename)}
                                        disabled={deletingNote === note.filename}
                                        className="flex-shrink-0 p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-lg transition-colors disabled:opacity-40"
                                    >
                                        <Trash2 className="w-3.5 h-3.5" />
                                    </button>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}
        </section>
    );
}
