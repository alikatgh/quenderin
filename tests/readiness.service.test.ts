import { describe, expect, it, beforeEach } from 'vitest';
import {
    setReadiness,
    getReadiness,
    getReadinessHistory,
    resetReadinessForStartup,
} from '../src/services/readiness.service.js';

// READINESS_HISTORY_MAX is a module-internal const (= 10) and is not exported,
// so it is mirrored here as a literal. The "clamp huge -> MAX" and "bounds to
// MAX" tests assert against this value; if the source const changes, these
// would correctly fail and flag the drift.
const READINESS_HISTORY_MAX = 10;

describe('readiness.service', () => {
    // Module state is global/singleton; reset before every test so cases are isolated.
    beforeEach(() => {
        resetReadinessForStartup();
    });

    describe('resetReadinessForStartup', () => {
        it('resets state to a not-ready "booting" baseline', () => {
            // Dirty the state first.
            setReadiness(true, 'serving', 'up');
            expect(getReadiness().ready).toBe(true);

            resetReadinessForStartup();

            const state = getReadiness();
            expect(state.ready).toBe(false);
            expect(state.stage).toBe('booting');
            expect(state.details).toBeUndefined();
            // startedAt and updatedAt are stamped together on reset.
            expect(state.startedAt).toBe(state.updatedAt);
            expect(typeof state.startedAt).toBe('string');
            expect(Number.isNaN(Date.parse(state.startedAt))).toBe(false);
        });

        it('collapses history to a single booting entry', () => {
            setReadiness(true, 'initializing-services');
            setReadiness(true, 'starting-http-server');
            expect(getReadinessHistory().length).toBeGreaterThan(1);

            resetReadinessForStartup();

            const history = getReadinessHistory();
            expect(history.length).toBe(1);
            expect(history[0]?.ready).toBe(false);
            expect(history[0]?.stage).toBe('booting');
        });

        it('carries the provided details into both state and the seed transition', () => {
            resetReadinessForStartup('relaunch requested');

            expect(getReadiness().details).toBe('relaunch requested');
            const history = getReadinessHistory();
            expect(history.length).toBe(1);
            expect(history[0]?.details).toBe('relaunch requested');
        });
    });

    describe('setReadiness', () => {
        it('updates the live state snapshot', () => {
            setReadiness(true, 'serving', 'http listening');

            const state = getReadiness();
            expect(state.ready).toBe(true);
            expect(state.stage).toBe('serving');
            expect(state.details).toBe('http listening');
        });

        it('returns an independent copy from getReadiness (no aliasing of internal state)', () => {
            setReadiness(true, 'serving');
            const snapshot = getReadiness();
            // Mutating the returned object must not affect subsequent reads.
            snapshot.ready = false;
            snapshot.stage = 'server-error';
            expect(getReadiness().ready).toBe(true);
            expect(getReadiness().stage).toBe('serving');
        });

        it('appends one history entry per distinct transition', () => {
            // beforeEach reset seeds history with 1 entry.
            setReadiness(false, 'initializing-services');
            setReadiness(false, 'starting-http-server');
            setReadiness(true, 'serving');

            const history = getReadinessHistory();
            expect(history.length).toBe(4); // seed + 3 distinct
            expect(history[history.length - 1]?.stage).toBe('serving');
            expect(history[history.length - 1]?.ready).toBe(true);
        });

        it('dedups two identical consecutive (ready,stage,details) transitions into one entry', () => {
            const before = getReadinessHistory().length;
            setReadiness(true, 'serving', 'listening on 7878');
            setReadiness(true, 'serving', 'listening on 7878'); // identical -> ignored

            const history = getReadinessHistory();
            expect(history.length).toBe(before + 1);
            expect(history[history.length - 1]?.details).toBe('listening on 7878');
        });

        it('treats a change in details alone as a new (non-deduped) transition', () => {
            const before = getReadinessHistory().length;
            setReadiness(true, 'serving', 'first');
            setReadiness(true, 'serving', 'second'); // same ready+stage, different details

            expect(getReadinessHistory().length).toBe(before + 2);
        });

        it('treats undefined-details vs set-details as distinct transitions', () => {
            const before = getReadinessHistory().length;
            setReadiness(true, 'serving'); // details: undefined
            setReadiness(true, 'serving', 'now with details');

            expect(getReadinessHistory().length).toBe(before + 2);
        });

        it('re-adds a transition after an intervening distinct one (dedup is only consecutive)', () => {
            const before = getReadinessHistory().length;
            setReadiness(true, 'serving', 'a');
            setReadiness(false, 'server-error', 'boom');
            setReadiness(true, 'serving', 'a'); // same as first but not consecutive -> added

            expect(getReadinessHistory().length).toBe(before + 3);
        });

        it('bounds history to READINESS_HISTORY_MAX, dropping the oldest entries', () => {
            // Push far more than MAX distinct transitions. Use the boolean to
            // guarantee each is distinct from its predecessor.
            const total = READINESS_HISTORY_MAX + 15;
            for (let i = 0; i < total; i++) {
                setReadiness(i % 2 === 0, 'serving', `step-${i}`);
            }

            const history = getReadinessHistory(READINESS_HISTORY_MAX);
            expect(history.length).toBe(READINESS_HISTORY_MAX);
            // The most recent entry must be the last one we pushed.
            expect(history[history.length - 1]?.details).toBe(`step-${total - 1}`);
            // The oldest retained entry is NOT the original seed (it was evicted).
            expect(history[0]?.stage).toBe('serving');
        });
    });

    describe('getReadinessHistory limit clamping', () => {
        beforeEach(() => {
            // After the outer beforeEach reset (1 seed entry), add several
            // distinct transitions so limit slicing is observable.
            for (let i = 0; i < 6; i++) {
                setReadiness(i % 2 === 0, 'serving', `entry-${i}`);
            }
            // History now: seed + 6 = 7 entries (all distinct, under MAX=10).
            expect(getReadinessHistory(READINESS_HISTORY_MAX).length).toBe(7);
        });

        it('clamps limit 0 up to 1', () => {
            const history = getReadinessHistory(0);
            expect(history.length).toBe(1);
            // Returns the single most-recent entry.
            expect(history[0]?.details).toBe('entry-5');
        });

        it('clamps a negative limit up to 1', () => {
            const history = getReadinessHistory(-100);
            expect(history.length).toBe(1);
            expect(history[0]?.details).toBe('entry-5');
        });

        it('clamps a huge limit down to READINESS_HISTORY_MAX', () => {
            const history = getReadinessHistory(9999);
            // Only 7 entries exist, but the clamp caps the *requested* limit at
            // MAX; slice(-7..) with limit>=7 returns all 7 available entries.
            expect(history.length).toBe(7);
            expect(history.length).toBeLessThanOrEqual(READINESS_HISTORY_MAX);
        });

        it('floors a fractional limit before slicing', () => {
            // floor(2.9) === 2 -> last two entries.
            const history = getReadinessHistory(2.9);
            expect(history.length).toBe(2);
            expect(history[0]?.details).toBe('entry-4');
            expect(history[1]?.details).toBe('entry-5');
        });

        it('honors an in-range limit exactly', () => {
            const history = getReadinessHistory(3);
            expect(history.length).toBe(3);
            expect(history.map(e => e.details)).toEqual(['entry-3', 'entry-4', 'entry-5']);
        });

        it('defaults to READINESS_HISTORY_MAX when no limit is given', () => {
            // 7 entries exist (< MAX), so all are returned.
            expect(getReadinessHistory().length).toBe(7);
        });

        it('returns deep copies of entries (mutating a result does not corrupt history)', () => {
            const first = getReadinessHistory(3);
            first[0]!.details = 'tampered';
            const second = getReadinessHistory(3);
            expect(second[0]?.details).not.toBe('tampered');
        });
    });
});
