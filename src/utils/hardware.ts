/**
 * hardware.ts — Auto-detect hardware class and derive all runtime tuning.
 *
 * Instead of scattering `if (isArm)` everywhere, we detect once at startup
 * and expose a single `HardwareProfile` that every service reads from.
 *
 * Profiles:
 *   embedded    — ARM/RISC-V/MIPS + ≤2 GB  (Raspberry Pi Zero/3, SBCs)
 *   constrained — ARM/RISC-V ≤8 GB or x86 ≤4 GB  (Pi 4GB, cheap laptops, Chromebooks)
 *   standard    — 4-16 GB typical desktop/laptop
 *   powerful    — 16 GB+ or Apple Silicon / discrete GPU systems
 */
import os from 'os';
import fs from 'fs';

export type HardwareTier = 'embedded' | 'constrained' | 'standard' | 'powerful';

export interface HardwareProfile {
    tier: HardwareTier;
    arch: string;
    platform: NodeJS.Platform;
    isArm: boolean;
    isLowPowerArch: boolean;
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
    /** Whether native addons (robotjs, screenshot-desktop) are likely available */
    nativeAddonsLikely: boolean;
    /** Whether running inside a container (Docker, LXC, etc.) */
    isContainerized: boolean;
    /** Recommended poll interval for background daemon (ms) */
    pollIntervalMs: number;
    /** Max concurrent heavy operations (LLM + OCR) — prevents OOM on low-end */
    maxConcurrentHeavyOps: number;
}

/** Cache the profile — hardware doesn't change at runtime */
let _cached: HardwareProfile | null = null;

export function getHardwareProfile(): HardwareProfile {
    if (_cached) return _cached;
    _cached = detectHardwareProfile();
    return _cached;
}

function detectHardwareProfile(): HardwareProfile {
    const arch = os.arch();              // 'arm', 'arm64', 'x64', 'riscv64', 'mips', 's390x', etc.
    const platform = process.platform;
    const isArm = arch === 'arm' || arch === 'arm64';
    // RISC-V, MIPS, s390x, ppc — non-x86/ARM architectures typically found on SBCs or mainframes
    const isLowPowerArch = isArm || ['riscv64', 'mips', 'mipsel', 'ppc', 'ppc64', 's390', 's390x'].includes(arch);
    const cpuCores = os.cpus().length;
    const totalRamGb = os.totalmem() / (1024 ** 3);

    // Apple Silicon is ARM but powerful — detect via platform + large RAM
    const isAppleSilicon = isArm && platform === 'darwin';

    // Detect if native C++ addons are likely to compile/load on this platform
    // Common x86_64 and arm64 on macOS/Linux/Windows are well-supported;
    // exotic arches (RISC-V, MIPS) or musl-based distros may lack prebuilds.
    const nativeAddonsLikely = ['x64', 'arm64'].includes(arch) &&
        ['darwin', 'linux', 'win32'].includes(platform);

    // Detect containerized environments (Docker, LXC, Kubernetes, etc.)
    const isContainerized = detectContainer();

    let tier: HardwareTier;
    if (isAppleSilicon && totalRamGb >= 8) {
        tier = 'powerful';
    } else if (isLowPowerArch && totalRamGb <= 2) {
        tier = 'embedded';
    } else if (totalRamGb <= 4 || (isLowPowerArch && totalRamGb <= 8)) {
        tier = 'constrained';
    } else if (totalRamGb >= 16) {
        tier = 'powerful';
    } else {
        tier = 'standard';
    }

    const profile = buildProfile(tier, arch, platform, isArm, isLowPowerArch, nativeAddonsLikely, isContainerized, cpuCores, totalRamGb);

    // ─── Environment Variable Overrides ─────────────────────────────────
    // Allow operators to force-tune specific knobs without code changes.
    if (process.env.QUENDERIN_DISABLE_GPU === '1') {
        profile.tryGpuOffload = false;
    }
    if (process.env.QUENDERIN_CONTEXT_FLOOR) {
        const floor = parseInt(process.env.QUENDERIN_CONTEXT_FLOOR, 10);
        if (Number.isFinite(floor) && floor >= 64) {
            profile.contextFloor = floor;
        }
    }
    if (process.env.QUENDERIN_TIMEOUT_MULTIPLIER) {
        const mult = parseFloat(process.env.QUENDERIN_TIMEOUT_MULTIPLIER);
        if (Number.isFinite(mult) && mult >= 0.5 && mult <= 20) {
            profile.timeoutMultiplier = mult;
        }
    }

    return profile;
}

/**
 * Detect if running inside a container (Docker, LXC, Kubernetes, WSL, etc.)
 * Uses multiple heuristics since no single method is universal.
 */
function detectContainer(): boolean {
    // Explicit env markers
    if (process.env.QUENDERIN_CONTAINER === '1') return true;
    if (process.env.container || process.env.DOCKER_CONTAINER) return true;
    if (process.env.KUBERNETES_SERVICE_HOST) return true;

    if (process.platform !== 'linux') return false;

    try {
        // Docker/containerd writes /.dockerenv
        if (fs.existsSync('/.dockerenv')) return true;
    } catch { /* ignore */ }

    try {
        // cgroup v1/v2: look for container runtime markers
        const cgroup = fs.readFileSync('/proc/1/cgroup', 'utf8');
        if (cgroup.includes('docker') || cgroup.includes('kubepods') ||
            cgroup.includes('lxc') || cgroup.includes('containerd')) {
            return true;
        }
    } catch { /* not on Linux or no access */ }

    return false;
}

function buildProfile(
    tier: HardwareTier,
    arch: string,
    platform: NodeJS.Platform,
    isArm: boolean,
    isLowPowerArch: boolean,
    nativeAddonsLikely: boolean,
    isContainerized: boolean,
    cpuCores: number,
    totalRamGb: number
): HardwareProfile {
    const base = { arch, platform, isArm, isLowPowerArch, nativeAddonsLikely, isContainerized, cpuCores, totalRamGb };
    switch (tier) {
        case 'embedded':
            return {
                tier, ...base,
                timeoutMultiplier: 5,       // 45s → 225s init, Pi needs minutes
                chatMaxTokens: 128,         // at 1-2 tok/s → ~1 min max
                codeMaxTokens: 256,         // at 1-2 tok/s → ~2-4 min
                actionMaxTokens: 64,
                defaultIdleMinutes: 3,      // RAM is life on Pi
                contextFloor: 128,          // bare minimum usable (lowered for sub-1GB)
                tryGpuOffload: false,       // SBCs typically have no GPU
                memoryBudgetHard: 0.92,     // let it swap — better slow than dead
                pollIntervalMs: 10_000,     // 10s — save CPU/battery on embedded
                maxConcurrentHeavyOps: 1,   // serialize everything
            };
        case 'constrained':
            return {
                tier, ...base,
                timeoutMultiplier: 3,       // 45s → 135s
                chatMaxTokens: 256,
                codeMaxTokens: 512,
                actionMaxTokens: 100,
                defaultIdleMinutes: 5,
                contextFloor: 256,
                tryGpuOffload: !isLowPowerArch,  // try GPU on x86, skip on ARM/RISC-V boards
                memoryBudgetHard: 0.90,
                pollIntervalMs: 5_000,      // 5s — reduce load on slow hardware
                maxConcurrentHeavyOps: 1,
            };
        case 'powerful':
            return {
                tier, ...base,
                timeoutMultiplier: 1,
                chatMaxTokens: 512,
                codeMaxTokens: 2048,
                actionMaxTokens: 256,
                defaultIdleMinutes: 15,
                contextFloor: 512,
                tryGpuOffload: true,
                memoryBudgetHard: 0.85,
                pollIntervalMs: 2_000,      // 2s — fast enough for responsive observation
                maxConcurrentHeavyOps: 3,
            };
        case 'standard':
        default:
            return {
                tier, ...base,
                timeoutMultiplier: 1,
                chatMaxTokens: 384,
                codeMaxTokens: 1024,
                actionMaxTokens: 150,
                defaultIdleMinutes: 10,
                contextFloor: 512,
                tryGpuOffload: true,
                memoryBudgetHard: 0.85,
                pollIntervalMs: 3_000,      // 3s — default
                maxConcurrentHeavyOps: 2,
            };
    }
}
