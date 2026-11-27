export type * from '../../../../shared/handy-speech-api.js';

export type MicrophonePermission = 'prompt' | 'granted' | 'denied' | 'no-device' | 'unsupported';

export interface MicrophoneState {
    readonly permission: MicrophonePermission;
    readonly error: string | null;
    readonly recording: boolean;
}
