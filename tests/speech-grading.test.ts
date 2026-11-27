import { describe, it } from 'vitest';

/**
 * Stage 2 implements src/services/speech/grading.ts, then turns every todo
 * below into a real assertion. Reference values come from
 * @handy-computer/models@0.2.3, not from guessed bands.
 */
describe('speech grading (Handy port)', () => {
    it.todo('grades accuracy exactly like Handy: A <5, B <10, C <20, D <30, F otherwise');
    it.todo('adds Handy +/- modifiers at the cbrt(2) sub-grade steps');
    it.todo('grades English from results[id].accuracy.en');
    it.todo('returns "?" for an unmeasured language and "—" for an unsupported one');
    it.todo('computes wait seconds as 30 / results[id].performance[tier]');
    it.todo('maps wait seconds to 0–4 speed bars with SPEED_CUTOFFS [2, 3.5, 7.5, 20]');
    it.todo('matches Handy for a known table: Parakeet A (wait 1.19 s, 4 bars), Qwen3-ASR 1.7B A (7.34 s, 3 bars)');
    it.todo('compares engine versions numerically and gates minEngine > pinned as needs-newer-engine');
});
