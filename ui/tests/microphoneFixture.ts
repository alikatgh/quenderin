import { vi } from 'vitest';

class FixtureRecorder extends EventTarget {
    state: RecordingState = 'inactive';
    mimeType = 'audio/webm';
    start = vi.fn(() => { this.state = 'recording'; });
    stop = vi.fn(() => {
        this.state = 'inactive';
        this.dispatchEvent(Object.assign(new Event('dataavailable'), { data: new Blob(['audio fixture']) }));
        this.dispatchEvent(new Event('stop'));
    });
    constructor(records: FixtureRecorder[]) { super(); records.push(this); }
}

export async function blobBytes(blob: Blob): Promise<ArrayBuffer> {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onerror = () => reject(reader.error);
        reader.onload = () => resolve(reader.result as ArrayBuffer);
        reader.readAsArrayBuffer(blob);
    });
}

export function setupMicrophone() {
    const stop = vi.fn();
    const stream = { getTracks: () => [{ stop }] } as unknown as MediaStream;
    const getUserMedia = vi.fn<() => Promise<MediaStream>>().mockResolvedValue(stream);
    const records: FixtureRecorder[] = [];
    const close = vi.fn(async () => {});
    const channels = [Float32Array.of(1, -1, 0.5), Float32Array.of(-1, -1, 0.5)];
    const decode = vi.fn(async () => ({
        sampleRate: 16000, length: 3, numberOfChannels: channels.length, getChannelData: (i: number) => channels[i],
    }));
    const audioOptions = vi.fn();
    vi.stubGlobal('AudioContext', class {
        decodeAudioData = decode;
        close = close;
        constructor(options: AudioContextOptions) { audioOptions(options); }
    });
    vi.stubGlobal('MediaRecorder', class extends FixtureRecorder { constructor() { super(records); } });
    vi.stubGlobal('PointerEvent', class extends MouseEvent {
        readonly pointerId: number;
        constructor(type: string, options: PointerEventInit) { super(type, options); this.pointerId = options.pointerId ?? 1; }
    });
    const audioBufferDescriptor = Object.getOwnPropertyDescriptor(Blob.prototype, 'arrayBuffer');
    Object.defineProperty(Blob.prototype, 'arrayBuffer', { configurable: true, value() { return blobBytes(this); } });
    const mediaDescriptor = Object.getOwnPropertyDescriptor(navigator, 'mediaDevices');
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } });
    function restore() {
        if (mediaDescriptor) Object.defineProperty(navigator, 'mediaDevices', mediaDescriptor);
        else Reflect.deleteProperty(navigator, 'mediaDevices');
        if (audioBufferDescriptor) Object.defineProperty(Blob.prototype, 'arrayBuffer', audioBufferDescriptor);
        else Reflect.deleteProperty(Blob.prototype, 'arrayBuffer');
    }
    return { getUserMedia, stream, stop, records, close, decode, audioOptions, restore };
}
