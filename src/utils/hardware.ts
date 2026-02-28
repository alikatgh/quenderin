/**
 * hardware.ts — Auto-detect hardware class and derive all runtime tuning.
 *
 * Instead of scattering `if (isArm)` everywhere, we detect once at startup
 * and expose a single `HardwareProfile` that every service reads from.
 *
 * Profiles:
 *   embedded    — ARM + ≤2 GB   (Raspberry Pi Zero/3/4 1-2GB)
 *   constrained — ARM + ≤4 GB   or x86 + ≤4 GB  (Pi 4GB, cheap laptops)
 *   standard    — 4-16 GB typical desktop/laptop
 *   powerful    — 16 GB+ or Apple Silicon
 */
import os from 'os';

export type HardwareTier = 'embedded' | 'constrained' | 'standard' | 'powerful';

export interface HardwareProfile {
    tier: HardwareTier;
    arch: string;
    isArm: boolean;
    cpuCores: number;
    totalRamGb: number;

    // ─── Derived tuning knobs ──────────────────────────────────────────
    /** Multiplier applied to all timeout durations (init, prompt, context) */
    timeoutMultiplier: number;
    /** Max tokens for chat responses */
    chatMaxTokens: number;
    /** Max tokens for code generation */
    codeMaxTokens: number;
    /** Max tokens for agent actions */
    actionMaxTokens: number;
    /** Default idle-unload minutes (RAM is precious on small devices) */
    defaultIdleMinutes: number;
    /** Context floor — minimum usable context size */
    contextFloor: number;
    /** Whether GPU offload should be attempted */
    tryGpuOffload: boolean;
    /** Memory budget hard cap (fraction of total RAM) */
    memoryBudgetHard: number;
}

/** Cache the profile — hardware doesn't change at runtime */
let _cached: HardwareProfile | null = null;

export function getHardwareProfile(): HardwareProfile {
    if (_cached) return _cached;
    _cached = detectHardwareProfile();
    return _cached;
}

function detectHardwareProfile(): HardwareProfile {
    const arch = os.arch();              // 'arm', 'arm64', 'x64', etc.
    const isArm = arch === 'arm' || arch === 'arm64';
    const cpuCores = os.cpus().length;
    const totalRamGb = os.totalmem() / (1024 ** 3);

    // Apple Silicon is ARM but powerful — detect via platform + large RAM
    const isAppleSilicon = isArm && process.platform === 'darwin';

    let tier: HardwareTier;
    if (isAppleSilicon && totalRamGb >= 8) {
        tier = 'powerful';
    } else if (isArm && totalRamGb <= 2) {
        tier = 'embedded';
    } else if (totalRamGb <= 4 || (isArm && totalRamGb <= 8)) {
        tier = 'constrained';
    } else if (totalRamGb >= 16) {
        tier = 'powerful';
    } else {
        tier = 'standard';
    }

    const profile = buildProfile(tier, arch, isArm, cpuCores, totalRamGb);
    return profile;
}

function buildProfile(
    tier: HardwareTier,
    arch: string,
    isArm: boolean,
    cpuCores: number,
    totalRamGb: number
): HardwareProfile {
    switch (tier) {
        case 'embedded':
            return {
                tier, arch, isArm, cpuCores, totalRamGb,
                timeoutMultiplier: 5,       // 45s → 225s init, Pi needs minutes
                chatMaxTokens: 128,         // at 1-2 tok/s → ~1 min max
                codeMaxTokens: 256,         // at 1-2 tok/s → ~2-4 min
                actionMaxTokens: 64,
                defaultIdleMinutes: 3,      // RAM is life on Pi
                contextFloor: 256,          // bare minimum usable
                tryGpuOffload: false,       // Pi has no GPU
                memoryBudgetHard: 0.92,     // let it swap — better slow than dead
            };
        case 'constrained':
            return {
                tier, arch, isArm, cpuCores, totalRamGb,
                timeoutMultiplier: 3,       // 45s → 135s
                chatMaxTokens: 256,
                codeMaxTokens: 512,
                actionMaxTokens: 100,
                defaultIdleMinutes: 5,
                contextFloor: 512,
                tryGpuOffload: !isArm,      // try GPU on x86, skip on ARM boards
                memoryBudgetHard: 0.90,
            };
        case 'powerful':
            return {
                tier, arch, isArm, cpuCores, totalRamGb,
                timeoutMultiplier: 1,
                chatMaxTokens: 512,
                codeMaxTokens: 2048,
                actionMaxTokens: 256,
                defaultIdleMinutes: 15,
                contextFloor: 512,
                tryGpuOffload: true,
                memoryBudgetHard: 0.85,
            };
        case 'standard':
        default:
            return {
                tier, arch, isArm, cpuCores, totalRamGb,
                timeoutMultiplier: 1,
                chatMaxTokens: 384,
                codeMaxTokens: 1024,
                actionMaxTokens: 150,
                defaultIdleMinutes: 10,
                contextFloor: 512,
                tryGpuOffload: true,
                memoryBudgetHard: 0.85,
            };
    }
}
