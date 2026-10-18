export interface VisionModelView {
    id: string; label: string; minimumMemoryBytes: number;
    artifacts: readonly { role: string; filename: string; bytes: number; url: string }[];
}
export interface VisionSelection { handle: string; label: string }
export interface VisionWorkflowAPI {
    models(): Promise<VisionModelView[]>;
    status(modelId: string): Promise<{ installed: boolean; availableMemoryBytes: number }>;
    chooseImage(): Promise<VisionSelection | null>;
    install(modelId: string): Promise<void>;
    verify(modelId: string): Promise<void>;
    answer(request: { modelId: string; imageHandle: string; prompt: string }): Promise<{ text: string; tokens: number }>;
    chooseGraniteModel(): Promise<VisionSelection | null>;
    answerGranite(request: { modelHandle: string; messages: { role: 'user' | 'assistant'; content: string }[] }): Promise<{ text: string }>;
    cancel(): Promise<void>;
    onProgress(callback: (progress: { modelId: string; fraction: number }) => void): () => void;
}
