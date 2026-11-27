export class SpeechError extends Error {
    constructor(
        readonly code: string,
        readonly status: number,
        message: string,
        readonly httpStatus: number | null = null,
        readonly retryable: boolean = true,
    ) {
        super(message);
        this.name = 'SpeechError';
    }
}
