# r29 — Payments audit (2026-07-11)

**Verdict: N/A.** No payment processing, no Stripe/webhooks, no entitlements — distribution is
free binaries + app stores' own billing (none wired). The safety blocklist deliberately REFUSES
payment-shaped device actions (`pay`, `buy`, `checkout`, `transfer` … — 34-keyword shared list),
which is the only payments-adjacent surface and is parity-tested on all three platforms.
