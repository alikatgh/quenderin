/**
 * session.service.ts — Persist and retrieve chat conversation history.
 *
 * Each session is a JSON file at ~/.quenderin/sessions/{id}.json
 * Sessions are created automatically on first message and closed
 * either explicitly or when a new session is started.
 *
 * Sessions contain: id, title (first user message), createdAt, updatedAt,
 * and an array of messages { role, content, timestamp }.
 */
import fs from 'fs';
import path from 'path';
import os from 'os';
import { randomUUID } from 'crypto';
import logger from '../utils/logger.js';
import { MAX_SESSIONS, MAX_MESSAGES_PER_SESSION, SESSION_FLUSH_INTERVAL_MS } from '../constants.js';

export interface SessionMessage {
    role: 'user' | 'assistant';
    content: string;
    timestamp: string;
}

export interface Session {
    id: string;
    title: string;
    createdAt: string;
    updatedAt: string;
    messages: SessionMessage[];
}

export interface SessionSummary {
    id: string;
    title: string;
    createdAt: string;
    updatedAt: string;
    messageCount: number;
}

const SESSIONS_DIR = path.join(os.homedir(), '.quenderin', 'sessions');

function ensureDir(): void {
    if (!fs.existsSync(SESSIONS_DIR)) {
        fs.mkdirSync(SESSIONS_DIR, { recursive: true });
    }
}

function sessionPath(id: string): string {
    // Sanitise id to prevent path traversal
    const safe = id.replace(/[^a-zA-Z0-9\-_]/g, '').slice(0, 64);
    return path.join(SESSIONS_DIR, `${safe}.json`);
}

export class SessionService {
    private currentSessionId: string | null = null;
    private currentSession: Session | null = null;
    private dirty = false;
    /** Flush writes on a lazy timer instead of every message */
    private flushTimer: NodeJS.Timeout | null = null;

    // ─── Public API ──────────────────────────────────────────────────────────

    /** Cancel any pending flush timer — call on cleanup to prevent leaks */
    public destroy(): void {
        this.flushNow();
        if (this.flushTimer) {
            clearTimeout(this.flushTimer);
            this.flushTimer = null;
        }
    }

    /** Start a fresh session (called when user begins a new conversation) */
    public startSession(): string {
        this.flushNow();
        // Q-598: prune here — the only place the persisted-session count grows — instead of on every
        // flushNow (a hot path). The outgoing session was just flushed above, so it's counted; the new
        // in-memory session isn't on disk yet, so it's never a prune target.
        this.pruneOldSessions();
        const id = randomUUID();
        const now = new Date().toISOString();
        this.currentSession = { id, title: 'New Conversation', createdAt: now, updatedAt: now, messages: [] };
        this.currentSessionId = id;
        this.dirty = false;
        return id;
    }

    /** Returns the active session id (creates one if none) */
    public activeSessionId(): string {
        if (!this.currentSessionId) return this.startSession();
        return this.currentSessionId;
    }

    /** Append a message to the current session */
    public addMessage(role: 'user' | 'assistant', content: string): void {
        if (!this.currentSession) this.startSession();
        const session = this.currentSession!;

        // Use first user message as session title (max 80 chars)
        if (role === 'user' && session.messages.filter(m => m.role === 'user').length === 0) {
            session.title = content.slice(0, 80).replace(/\n/g, ' ');
        }

        session.messages.push({ role, content, timestamp: new Date().toISOString() });
        session.updatedAt = new Date().toISOString();

        // Cap memory
        if (session.messages.length > MAX_MESSAGES_PER_SESSION) {
            session.messages = session.messages.slice(-MAX_MESSAGES_PER_SESSION);
        }

        this.dirty = true;
        this.scheduleFlush();
    }

    /** Retrieve a list of all session summaries, newest first */
    public listSessions(): SessionSummary[] {
        ensureDir();
        try {
            const files = fs.readdirSync(SESSIONS_DIR)
                .filter(f => f.endsWith('.json'))
                .map(f => {
                    try {
                        const raw = fs.readFileSync(path.join(SESSIONS_DIR, f), 'utf8');
                        const s = JSON.parse(raw) as Session;
                        return {
                            id: s.id,
                            title: s.title ?? 'Untitled',
                            createdAt: s.createdAt,
                            updatedAt: s.updatedAt,
                            messageCount: Array.isArray(s.messages) ? s.messages.length : 0,
                        } satisfies SessionSummary;
                    } catch (err) {
                        logger.debug(`[Session] Failed to parse session file ${f}:`, err);
                        return null;
                    }
                })
                .filter((s): s is SessionSummary => s !== null);

            // Sort newest first
            files.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
            return files;
        } catch (err) {
            logger.warn('[Session] Failed to list sessions:', err);
            return [];
        }
    }

    /** Load a specific session by ID */
    public loadSession(id: string): Session | null {
        // Q-297: the ACTIVE session lives in memory and only reaches disk on a debounced flush, so the
        // on-disk copy lags behind the live transcript. When the caller asks for the current session,
        // serve the fresh in-memory copy; otherwise read from disk.
        if (id === this.currentSessionId && this.currentSession) return this.currentSession;
        ensureDir();
        try {
            const raw = fs.readFileSync(sessionPath(id), 'utf8');
            return JSON.parse(raw) as Session;
        } catch (err) {
            logger.debug(`[Session] Failed to load session ${id}:`, err);
            return null;
        }
    }

    /** Q-597: make a SAVED session the active one, so subsequent addMessage() appends to IT — used when
     *  the user opens a past conversation from the sidebar. Rehydrating the UI alone left the server still
     *  pointed at the previous session, so the next message landed in the wrong conversation. Flushes the
     *  outgoing session first, then adopts the requested one. Returns null (active session unchanged) if
     *  the id isn't found on disk. No-op that returns the current session when it's already active. */
    public activateSession(id: string): Session | null {
        if (id === this.currentSessionId && this.currentSession) return this.currentSession;
        const loaded = this.loadSession(id);
        if (!loaded) return null;
        this.flushNow(); // persist the outgoing active session before switching away from it
        this.currentSession = loaded;
        this.currentSessionId = id;
        this.dirty = false;
        return loaded;
    }

    /** Delete a session by ID */
    public deleteSession(id: string): boolean {
        try {
            const p = sessionPath(id);
            if (fs.existsSync(p)) {
                fs.unlinkSync(p);
                if (this.currentSessionId === id) {
                    this.currentSessionId = null;
                    this.currentSession = null;
                }
                return true;
            }
        } catch (err) {
            logger.warn(`[Session] Failed to delete session ${id}:`, err);
        }
        return false;
    }

    /** Export session as Markdown string */
    public exportMarkdown(id: string): string | null {
        const session = id === this.currentSessionId ? this.currentSession : this.loadSession(id);
        if (!session) return null;
        const lines = [
            `# ${session.title}`,
            `_Created: ${new Date(session.createdAt).toLocaleString()}_`,
            '',
        ];
        for (const msg of session.messages) {
            lines.push(`**${msg.role === 'user' ? 'You' : 'Quenderin'}** · ${new Date(msg.timestamp).toLocaleTimeString()}`);
            lines.push('');
            lines.push(msg.content);
            lines.push('');
            lines.push('---');
            lines.push('');
        }
        return lines.join('\n');
    }

    // ─── Private flush logic ─────────────────────────────────────────────────

    private scheduleFlush(): void {
        if (this.flushTimer) return;
        this.flushTimer = setTimeout(() => {
            this.flushTimer = null;
            this.flushNow();
        }, SESSION_FLUSH_INTERVAL_MS);
        this.flushTimer.unref();
    }

    private flushNow(): void {
        if (!this.dirty || !this.currentSession) return;
        ensureDir();
        try {
            fs.writeFileSync(sessionPath(this.currentSession.id), JSON.stringify(this.currentSession, null, 2), 'utf8');
            this.dirty = false;
            // Q-598: do NOT prune here. flushNow runs on every debounced write (≈ every few seconds while
            // chatting), and pruneOldSessions → listSessions reads + JSON.parses EVERY session file — an
            // O(n) disk stall on a hot path. Re-writing the current session never grows the session count,
            // so pruning only needs to run when a NEW session is created (see startSession).
        } catch (err) {
            logger.error('[Session] Failed to persist session:', err);
        }
    }

    private pruneOldSessions(): void {
        try {
            const summaries = this.listSessions();
            if (summaries.length <= MAX_SESSIONS) return;
            // Delete the oldest sessions beyond the cap
            for (const s of summaries.slice(MAX_SESSIONS)) {
                this.deleteSession(s.id);
            }
        } catch (err) {
            logger.debug('[Session] Failed to prune old sessions:', err);
        }
    }
}
