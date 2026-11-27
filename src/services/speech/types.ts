import type { Catalog, CatalogModel } from '@handy-computer/models';

export type HandySpeechCatalog = Pick<Catalog, 'curatedModels' | 'methodology' | 'recommend' | 'languageAccuracyGrade' | 'modelWaitSeconds'>;
export type HandySpeechModel = CatalogModel;
export type * from '../../../shared/handy-speech-api.js';

export interface SpeechTranscriptionRequest {
    readonly modelId: string;
    readonly language?: string;
    readonly wav: Buffer;
    readonly autoSend?: boolean;
}
