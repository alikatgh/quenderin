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

const nowIso = () => new Date().toISOString();

let state: ReadinessState = {
    ready: false,
    stage: 'booting',
    startedAt: nowIso(),
    updatedAt: nowIso(),
};

export function setReadiness(ready: boolean, stage: ReadinessStage, details?: string): void {
    state = {
        ...state,
        ready,
        stage,
        details,
        updatedAt: nowIso(),
    };
}

export function getReadiness(): ReadinessState {
    return { ...state };
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
}
