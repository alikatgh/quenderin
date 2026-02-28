type ReadinessStage =
    | 'booting'
    | 'initializing-services'
    | 'starting-http-server'
    | 'serving'
    | 'server-error'
    | 'shutting-down';

interface ReadinessState {
    ready: boolean;
    stage: ReadinessStage;
    startedAt: string;
    updatedAt: string;
    details?: string;
}

interface ReadinessTransition {
    at: string;
    ready: boolean;
    stage: ReadinessStage;
    details?: string;
}

const nowIso = () => new Date().toISOString();
const READINESS_HISTORY_MAX = 10;

let state: ReadinessState = {
    ready: false,
    stage: 'booting',
    startedAt: nowIso(),
    updatedAt: nowIso(),
};

let history: ReadinessTransition[] = [
    {
        at: state.updatedAt,
        ready: state.ready,
        stage: state.stage,
        details: state.details,
    },
];

function pushTransition(transition: ReadinessTransition): void {
    const previous = history[history.length - 1];
    if (
        previous &&
        previous.ready === transition.ready &&
        previous.stage === transition.stage &&
        previous.details === transition.details
    ) {
        return;
    }
    history.push(transition);
    if (history.length > READINESS_HISTORY_MAX) {
        history = history.slice(history.length - READINESS_HISTORY_MAX);
    }
}

export function setReadiness(ready: boolean, stage: ReadinessStage, details?: string): void {
    state = {
        ...state,
        ready,
        stage,
        details,
        updatedAt: nowIso(),
    };
    pushTransition({
        at: state.updatedAt,
        ready,
        stage,
        details,
    });
}

export function getReadiness(): ReadinessState {
    return { ...state };
}

export function getReadinessHistory(limit: number = READINESS_HISTORY_MAX): ReadinessTransition[] {
    const boundedLimit = Math.min(READINESS_HISTORY_MAX, Math.max(1, Math.floor(limit)));
    return history.slice(-boundedLimit).map(entry => ({ ...entry }));
}

export function resetReadinessForStartup(details?: string): void {
    const stamp = nowIso();
    state = {
        ready: false,
        stage: 'booting',
        startedAt: stamp,
        updatedAt: stamp,
        details,
    };
    history = [{
        at: stamp,
        ready: false,
        stage: 'booting',
        details,
    }];
}
