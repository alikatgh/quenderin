import { describe, it, expect, vi, afterEach } from 'vitest';
import { classifyTier, buildProfile, type HardwareTier } from '../src/utils/hardware.js';

/**
 * r37/r50 backlog #2: the tier classifier decides every runtime knob (timeouts, token caps,
 * GPU offload, poll cadence) yet had no tests. These pin the band EDGES — the exact places the
 * journal says "two 'can this device run it?' sources diverge" — and the knob invariants the
 * services rely on.
 */
describe('classifyTier — the band edges', () => {
    const cases: Array<[string, Parameters<typeof classifyTier>[0], HardwareTier]> = [
        ['Pi Zero (arm, 0.5 GB)',            { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 0.5 }, 'embedded'],
        ['Pi 3 (arm, exactly 2 GB)',         { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 2 },   'embedded'],
        ['Pi 4 (arm, 4 GB)',                 { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 4 },   'constrained'],
        ['Pi 5 (arm, exactly 8 GB)',         { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 8 },   'constrained'],
        ['ARM server (arm, 16 GB)',          { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 16 },  'powerful'],
        ['cheap laptop (x86, exactly 4 GB)', { isAppleSilicon: false, isLowPowerArch: false, totalRamGb: 4 },   'constrained'],
        ['desktop (x86, 8 GB)',              { isAppleSilicon: false, isLowPowerArch: false, totalRamGb: 8 },   'standard'],
        ['desktop (x86, 15.9 GB)',           { isAppleSilicon: false, isLowPowerArch: false, totalRamGb: 15.9 },'standard'],
        ['workstation (x86, exactly 16 GB)', { isAppleSilicon: false, isLowPowerArch: false, totalRamGb: 16 },  'powerful'],
        ['M1 MacBook Air (8 GB)',            { isAppleSilicon: true,  isLowPowerArch: true,  totalRamGb: 8 },   'powerful'],
        ['M-series (32 GB)',                 { isAppleSilicon: true,  isLowPowerArch: true,  totalRamGb: 32 },  'powerful'],
        // Apple Silicon below 8 GB does not exist in the wild, but the classifier must not
        // accidentally call it powerful: it falls through to the low-power-arch band.
        ['hypothetical Apple arm 7 GB',      { isAppleSilicon: true,  isLowPowerArch: true,  totalRamGb: 7 },   'constrained'],
        ['RISC-V SBC (2 GB)',                { isAppleSilicon: false, isLowPowerArch: true,  totalRamGb: 2 },   'embedded'],
    ];

    for (const [label, input, expected] of cases) {
        it(`${label} → ${expected}`, () => {
            expect(classifyTier(input)).toBe(expected);
        });
    }
});

describe('buildProfile — knob invariants the services rely on', () => {
    const mk = (tier: HardwareTier, lowPower = false) =>
        buildProfile(tier, lowPower ? 'arm64' : 'x64', 'linux', lowPower, lowPower, true, false, 4, 8);
    const tiers: HardwareTier[] = ['embedded', 'constrained', 'standard', 'powerful'];

    it('slower tiers never get SHORTER timeouts or LARGER token caps than faster ones', () => {
        const [e, c, s, p] = tiers.map(t => mk(t));
        expect(e.timeoutMultiplier).toBeGreaterThanOrEqual(c.timeoutMultiplier);
        expect(c.timeoutMultiplier).toBeGreaterThanOrEqual(s.timeoutMultiplier);
        expect(s.timeoutMultiplier).toBeGreaterThanOrEqual(p.timeoutMultiplier);
        for (const key of ['chatMaxTokens', 'codeMaxTokens', 'actionMaxTokens'] as const) {
            expect(e[key]).toBeLessThanOrEqual(c[key]);
            expect(c[key]).toBeLessThanOrEqual(s[key]);
            expect(s[key]).toBeLessThanOrEqual(p[key]);
        }
    });

    it('every tier keeps a sane memory budget and a usable context floor', () => {
        for (const t of tiers) {
            const prof = mk(t);
            expect(prof.memoryBudgetHard).toBeGreaterThan(0.5);
            expect(prof.memoryBudgetHard).toBeLessThanOrEqual(0.95);
            expect(prof.contextFloor).toBeGreaterThanOrEqual(128);
            expect(prof.maxConcurrentHeavyOps).toBeGreaterThanOrEqual(1);
        }
    });

    it('embedded serializes heavy ops and never tries GPU; constrained tries GPU on x86 only', () => {
        expect(mk('embedded').maxConcurrentHeavyOps).toBe(1);
        expect(mk('embedded').tryGpuOffload).toBe(false);
        expect(mk('constrained', /* lowPower */ true).tryGpuOffload).toBe(false);  // ARM/RISC-V board
        expect(mk('constrained', /* lowPower */ false).tryGpuOffload).toBe(true);  // cheap x86 laptop
    });
});

describe('env overrides (fresh module per test — the profile memoizes)', () => {
    const ENV_KEYS = ['QUENDERIN_DISABLE_GPU', 'QUENDERIN_CONTEXT_FLOOR', 'QUENDERIN_TIMEOUT_MULTIPLIER'];
    afterEach(() => {
        for (const k of ENV_KEYS) delete process.env[k];
        vi.resetModules();
    });

    async function freshProfile() {
        vi.resetModules();
        const mod = await import('../src/utils/hardware.js');
        return mod.getHardwareProfile();
    }

    it('QUENDERIN_DISABLE_GPU=1 forces offload off', async () => {
        process.env.QUENDERIN_DISABLE_GPU = '1';
        expect((await freshProfile()).tryGpuOffload).toBe(false);
    });

    it('QUENDERIN_CONTEXT_FLOOR applies when ≥64 and is rejected below', async () => {
        process.env.QUENDERIN_CONTEXT_FLOOR = '1024';
        expect((await freshProfile()).contextFloor).toBe(1024);
        process.env.QUENDERIN_CONTEXT_FLOOR = '16'; // below the 64 floor-of-the-floor → ignored
        const prof = await freshProfile();
        expect(prof.contextFloor).toBeGreaterThanOrEqual(128);
    });

    it('QUENDERIN_TIMEOUT_MULTIPLIER clamps to [0.5, 20]', async () => {
        process.env.QUENDERIN_TIMEOUT_MULTIPLIER = '2.5';
        expect((await freshProfile()).timeoutMultiplier).toBe(2.5);
        process.env.QUENDERIN_TIMEOUT_MULTIPLIER = '99'; // out of range → tier default kept
        const prof = await freshProfile();
        expect(prof.timeoutMultiplier).not.toBe(99);
    });
});
