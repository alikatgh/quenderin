import { IDeviceProvider } from '../../types/index.js';
import { UiParserService } from '../uiParser.service.js';
import {
    Capability, ConsentStore, AuditLedger, RunSession,
    InMemoryConsentStore, InMemoryAuditLedger,
} from './capability.js';
import { CapabilityRunner, Approver } from './runner.js';
import { CapabilityAgent, Planner } from './capabilityAgent.js';
import { appCapabilities } from './appCapabilities.js';
import { MacAutomation } from './macAutomation.js';
import { macCapabilities } from './macCapabilities.js';

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
}

export interface GovernedAgent {
    /** Run a goal to completion, governed the whole way. */
    run(goal: string): ReturnType<CapabilityAgent['run']>;
    /** Reverse everything this run changed (the "undo this task" button). */
    undoAll(): Promise<string>;
    /** The capabilities this agent was assembled with (for a Settings pane). */
    readonly capabilities: Capability[];
    readonly ledger: AuditLedger;
}

/** Assemble the full governed desktop agent from injected seams. */
export function createGovernedAgent(deps: GovernedAgentDeps): GovernedAgent {
    const parser = deps.parser ?? new UiParserService();
    const capabilities: Capability[] = [
        ...(deps.mac ? macCapabilities(deps.mac) : []),
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
    const agent = new CapabilityAgent(llmPlanner(deps.llm), capabilities, runner, deps.maxSteps ?? 8);
    return {
        run: (goal: string) => agent.run(goal, deps.signal),
        undoAll: () => session.undoAll(),
        capabilities,
        ledger,
    };
}
