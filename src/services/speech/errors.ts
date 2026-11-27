export class SpeechError extends Error {
    constructor(
        readonly code: string,
        readonly status: number,
        message: string,
        readonly httpStatus: number | null = null,
    ) {
        super(message);
        this.name = 'SpeechError';
    }
}
