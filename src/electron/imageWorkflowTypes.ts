/** The renderer receives catalog metadata and opaque selections, never filesystem authority. */
export interface ImagePresetView {
    id: string;
    label: string;
    publisher: string;
    license: string;
    licenseUrl: string;
    requiresPublisherAccess: boolean;
    promptRequirement?: string;
    width: number;
    height: number;
    steps: number;
    totalBytes: number;
    components: { filename: string; role: string; bytes: number; license: string; access: string; repository: string }[];
}
export interface ImageFolderSelection { handle: string; label: string }
export interface ImageVerificationView { model: string; components: number; bytes: number }
export interface ImageGeneratedView { path: string; width: number; height: number; previewDataUrl: string }
export interface ImageGenerationProgress { requestId: string; step: number; steps: number }
export interface ImageWorkflowAPI {
    models(): Promise<ImagePresetView[]>;
    chooseFolder(): Promise<ImageFolderSelection | null>;
    verify(request: { modelId: string; folderHandle: string }): Promise<ImageVerificationView>;
    generate(request: { modelId: string; folderHandle: string; prompt: string; requestId: string }): Promise<ImageGeneratedView | null>;
    cancel(): Promise<void>;
    onProgress(callback: (progress: ImageGenerationProgress) => void): () => void;
}
