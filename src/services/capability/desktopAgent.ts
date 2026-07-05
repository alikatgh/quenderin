import { IDeviceProvider } from '../../types/index.js';
import { UiParserService } from '../uiParser.service.js';
import {
    Capability, ConsentStore, AuditLedger, RunSession,
    InMemoryConsentStore, InMemoryAuditLedger,
} from './capability.js';
import { CapabilityRunner, Approver } from './runner.js';
import { CapabilityAgent, Planner } from './capabilityAgent.js';
import { SkillMemory } from './skillMemory.js';
import { appCapabilities } from './appCapabilities.js';
import { MacAutomation } from './macAutomation.js';
import { macCapabilities } from './macCapabilities.js';
import { fileCapabilities } from './fileCapabilities.js';
import { MacUi } from './macUi.js';
import { macUiCapabilities } from './macUiCapabilities.js';

/**
 * The production assembly — this is where "the engine with tests" becomes "the thing that runs on
 * a real local model and operates the computer". The app wires:
 *   real LlmService (the on-device planner) + real OsascriptAutomation/AndroidProvider (the hands)
 *   + the Electron approval dialog (the approver) + a persisted consent store & ledger.
 * Everything else — the whole governed loop — is exactly what the tests exercise with fakes, so
 * the only production-only surface is the three injected seams. Swap fakes for reals; nothing else
 * changes. That's the point of the spine.
 */

/** The minimal shape the local model must provide — `LlmService.generalChat` satisfies it. */
export interface ChatCompleter {
    generalChat(prompt: string, onToken?: (t: string) => void, opts?: { plainChat?: boolean }): Promise<{ text: string }>;
}

/** Adapt a local model into the agent's `Planner` seam. `plainChat` drops the tool preamble so
 *  the model sees only the agent prompt (the capability list + the JSON contract). */
export function llmPlanner(llm: ChatCompleter): Planner {
    return async (prompt: string) => (await llm.generalChat(prompt, undefined, { plainChat: true })).text;
}

export interface GovernedAgentDeps {
    /** The on-device model. Required — this is the brain. */
    llm: ChatCompleter;
    /** ADB device/emulator for the app.* capabilities (BlueStacks etc.). Omit to exclude them. */
    device?: IDeviceProvider;
    parser?: UiParserService;
    /** macOS automation for the mac.* capabilities. Omit to exclude them (e.g. off darwin). */
    mac?: MacAutomation;
    /** macOS accessibility for the mac.ui.* GUI-driving capabilities (click/type into ANY app).
     *  Omit to exclude them — the most powerful surface, so it's opt-in (the CLI's `--gui`). */
    macUi?: MacUi;
    /** The granted workspace folder for the fs.* capabilities (organize/rename/trash/read/list).
     *  A function so the grant can change; returns null when none is granted. Omit to exclude fs.*. */
    workspace?: () => string | null;
    /** Persisted grants (the Settings toggles). Defaults to in-memory. */
    consent?: ConsentStore;
    /** The flight recorder. Defaults to in-memory. */
    ledger?: AuditLedger;
    /** The per-run approval dialog. Omit ⇒ mutating actions fail closed (safe default). */
    approve?: Approver;
    /** The kill switch — pass an AbortSignal to stop the run instantly. */
    signal?: AbortSignal;
    bulkThreshold?: number;
    maxSteps?: number;
    /** Skill memory — primes the model with proven sequences for similar past goals, and learns
     *  from each success. Pass a shared instance to make the agent improve across runs. */
    memory?: SkillMemory;
}

export interface GovernedAgent {
    /** Run a goal to completion, governed the whole way. */
    run(goal: string): ReturnType<CapabilityAgent['run']>;
    /** Reverse everything this run changed (the "undo this task" button). */
    undoAll(): Promise<string>;
    /** The undoable actions this run recorded (name + input, oldest-first) — persist for a
     *  cross-session `quenderin undo`. Empty if the run changed nothing reversible. */
    undoLog(): Array<{ capability: string; input: string }>;
    /** The capabilities this agent was assembled with (for a Settings pane). */
    readonly capabilities: Capability[];
    readonly ledger: AuditLedger;
}

/** Assemble the full governed desktop agent from injected seams. */
export function createGovernedAgent(deps: GovernedAgentDeps): GovernedAgent {
    const parser = deps.parser ?? new UiParserService();
    const capabilities: Capability[] = [
        ...(deps.workspace ? fileCapabilities(deps.workspace) : []),
        ...(deps.mac ? macCapabilities(deps.mac) : []),
        ...(deps.macUi ? macUiCapabilities(deps.macUi) : []),
        ...(deps.device ? appCapabilities(deps.device, parser) : []),
    ];
    const ledger = deps.ledger ?? new InMemoryAuditLedger();
    const session = new RunSession();
    const runner = new CapabilityRunner(
        deps.consent ?? new InMemoryConsentStore(),
        ledger,
        deps.approve,
        undefined,
        session,
        deps.bulkThreshold,
    );
    const agent = new CapabilityAgent(llmPlanner(deps.llm), capabilities, runner, deps.maxSteps ?? 8, deps.memory);
    return {
        run: (goal: string) => agent.run(goal, deps.signal),
        undoAll: () => session.undoAll(),
        undoLog: () => session.undoLog(),
        capabilities,
        ledger,
    };
}
