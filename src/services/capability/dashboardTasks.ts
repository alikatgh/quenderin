import { EventEmitter } from 'events';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { ActionPreview } from './capability.js';
import { Approver } from './runner.js';
import { GovernedAgent } from './desktopAgent.js';
import { UndoAction } from './undo.js';
import { saveUndoJournal, clearUndoJournal } from './persistence.js';

/**
 * The dashboard's door onto the GOVERNED agent (`createGovernedAgent`) — the Electron/browser
 * twin of the CLI's `quenderin do`. The renderer talks to this over the WebSocket; this class
 * owns the run lifecycle so the socket layer stays a thin message router:
 *
 *   task_start → assemble a governed agent → stream steps → (approval_request ⇄ answer)* →
 *   task_done { answer | halt, undoable } → optional undoLast()
 *
 * Safety semantics (the load-bearing part):
 *  - ONE run at a time — a concurrent start is rejected loudly (the Q-539 lesson).
 *  - Approval is FAIL-CLOSED end to end: no renderer listening ⇒ declined; the socket closing
 *    mid-question ⇒ declined (declinePending); stop() ⇒ declined + the run aborts.
 *  - The runner's own fail-closed default still backstops all of this — we merely wire its
 *    `approve` seam to the renderer dialog.
 *  - Undo parity with the CLI: a finished run's reversible actions are persisted to the undo
 *    journal, so `quenderin undo` can reverse a dashboard task even after a relaunch; undoing
 *    from the dashboard clears the journal (it must never double-apply).
 *
 * The `assemble` factory is injected so tests drive the whole lifecycle with a scripted planner
 * and fake capabilities — the same seam-and-fake discipline as every other governed surface.
 */

export interface TaskStartOptions {
    /** The granted workspace folder for fs.* — validated to an existing directory. */
    workspace?: string | null;
    /** Opt into the mac.ui.* GUI-driving surface (the most powerful; default off). */
    gui?: boolean;
    /** Preview mutations instead of performing them. */
    dryRun?: boolean;
}

export interface AssembleDeps {
    approve: Approver;
    signal: AbortSignal;
    workspace: string | null;
    gui: boolean;
    dryRun: boolean;
}

export type AssembleAgent = (deps: AssembleDeps) => GovernedAgent;

export interface TaskApprovalRequest {
    id: string;
    summary: string;
    mutates: boolean;
    tier?: number;
}

export interface TaskResult {
    answer: string | null;
    halt: string;
    /** How many reversible actions the run left behind (drives the Undo button). */
    undoable: number;
}

/** Where a finished run's reversible tail is persisted (so `quenderin undo` works cross-session).
 *  A seam so tests never touch the real ~/.quenderin journal. */
export interface UndoJournal {
    save(actions: UndoAction[]): void;
    clear(): void;
}

/** Expand a leading `~` — a renderer-typed path isn't shell-expanded. */
export function expandTilde(p: string): string {
    return p === '~' ? os.homedir() : p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
}

export class DashboardTaskService extends EventEmitter {
    private running = false;
    private ac: AbortController | null = null;
    private pending = new Map<string, (approved: boolean) => void>();
    private seq = 0;
    /** The last finished run's agent, kept for undoLast() (its RunSession holds the inverses). */
    private lastAgent: GovernedAgent | null = null;

    constructor(
        private assemble: AssembleAgent,
        private journal: UndoJournal = { save: saveUndoJournal, clear: clearUndoJournal },
    ) {
        super();
    }

    get isRunning(): boolean {
        return this.running;
    }

    /**
     * Run one governed task. Emits 'step' (string), 'approval_request' (TaskApprovalRequest)
     * and resolves with the result — the socket layer forwards each to the renderer.
     * Throws on a concurrent start or an invalid workspace (surface as task_error).
     */
    async start(goal: string, opts: TaskStartOptions = {}): Promise<TaskResult> {
        if (this.running) throw new Error('A task is already running. Stop it before starting a new one.');
        let workspace: string | null = null;
        if (opts.workspace) {
            const resolved = path.resolve(expandTilde(opts.workspace));
            if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
                throw new Error(`Workspace "${opts.workspace}" is not a folder.`);
            }
            workspace = resolved;
        }
        this.running = true;
        this.ac = new AbortController();
        try {
            const agent = this.assemble({
                approve: this.rendererApprover(),
                signal: this.ac.signal,
                workspace,
                gui: opts.gui ?? false,
                dryRun: opts.dryRun ?? false,
            });
            const result = await agent.run(goal, (line) => this.emit('step', line));
            // Persist the reversible tail so `quenderin undo` works cross-session, exactly like
            // the CLI's "Later?" path. fs.* reversals need the workspace attached.
            const undoable = agent.undoLog();
            if (undoable.length > 0) {
                const actions: UndoAction[] = undoable.map((a) =>
                    a.capability.startsWith('fs.') && workspace ? { ...a, workspace } : a);
                this.journal.save(actions);
            }
            this.lastAgent = agent;
            return { answer: result.answer, halt: result.halt, undoable: undoable.length };
        } finally {
            this.running = false;
            this.ac = null;
            this.declinePending();   // a question outliving its run is answered NO
            this.emit('finished');   // e.g. the server persists shared skill memory here
        }
    }

    /** The renderer's answer to an approval_request. Unknown/stale ids are ignored. */
    answer(id: string, approved: boolean): void {
        const resolve = this.pending.get(id);
        if (!resolve) return;
        this.pending.delete(id);
        resolve(approved === true);
    }

    /** The kill switch: abort the run between steps and decline anything awaiting approval. */
    stop(): void {
        this.ac?.abort();
        this.declinePending();
    }

    /** FAIL-CLOSED on disconnect: the socket layer calls this when the renderer goes away, so a
     *  dangling approval dialog can never be answered by nobody and hang the run open. */
    declinePending(): void {
        for (const resolve of this.pending.values()) resolve(false);
        this.pending.clear();
    }

    /** Reverse everything the LAST finished task changed (LIFO), and clear the persisted
     *  journal so a later `quenderin undo` can't double-apply. */
    async undoLast(): Promise<string> {
        if (this.running) throw new Error('A task is still running.');
        if (!this.lastAgent) throw new Error('Nothing to undo.');
        const report = await this.lastAgent.undoAll();
        this.journal.clear();
        this.lastAgent = null;
        return report;
    }

    private rendererApprover(): Approver {
        return (preview: ActionPreview): Promise<boolean> => {
            // Nobody listening = nobody can say yes. Refuse rather than hang (fail-closed).
            if (this.listenerCount('approval_request') === 0) return Promise.resolve(false);
            const id = `apr-${++this.seq}`;
            return new Promise<boolean>((resolve) => {
                this.pending.set(id, resolve);
                const req: TaskApprovalRequest = {
                    id,
                    summary: preview.summary,
                    mutates: preview.mutates,
                    tier: preview.tier,
                };
                this.emit('approval_request', req);
            });
        };
    }
}
