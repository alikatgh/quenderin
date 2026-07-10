# r26 — Quenderin rate-limiting audit (2026-07-11)

**Lens:** Throttles, brute force, abuse (50-round plan r26)
**Verdict: accepted posture for a loopback single-user app — no per-route throttle, deliberately.**

## Analysis
- **Token brute force:** the only credential is a 256-bit per-launch token compared timing-safe.
  At loopback-only reachability, an attacker with local code execution already outranks any rate
  limit; guessing 2^256 over HTTP is not a real vector. No lockout needed.
- **Flooding/abuse surfaces and their existing brakes:**
  - WS frames: `maxPayload` 16 MiB (r20) + heartbeat kill of dead sockets + send-buffer
    backpressure (1 MB `bufferedAmount` drop).
  - Model downloads: `isDownloading` single-flight — a spammed download endpoint refuses.
  - Inference: single-session engine; `INFERENCE_BUSY` refusals rather than queues that grow.
  - Agent actions: the bulk-brake pauses for human confirmation every N executed actions (Q-549).
  - JSON bodies: 256 kB cap.
- **What would change the verdict:** shipping `QUENDERIN_HOST=0.0.0.0` as a *supported* LAN mode
  (multi-client). That mode must add per-IP request throttling + WS connection caps before it is
  documented as supported. Recorded as the trigger condition, not scheduled work.
