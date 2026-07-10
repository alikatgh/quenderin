# r25 — Quenderin secrets audit (2026-07-11)

**Lens:** Committed keys, env drift, history leaks (50-round plan r25)
**Verdict: clean.**

## Checks run
1. **Tracked-content pattern scan** (api keys, private key blocks, `ghp_`/`sk-`/AKIA tokens):
   only hits are `tests/redaction.test.ts` fixtures — i.e., the tests that PROVE the redactor
   masks such strings in the capability ledger. No real material.
2. **Full-history filename scan** (`git log --all --diff-filter=A`): zero `.env`, `.pem`, `.p12`,
   `.keystore`, `_rsa` files ever added.
3. **.gitignore:** `.env` / `.env.*` ignored with `!.env.example` carve-out — correct shape.
4. **Runtime posture (re-verified):** per-launch token never persisted; `?token=` stripped from
   URL/history (Q-525) and logs (Q-355); passphrase hashed at persistence boundary (Q-530); goals
   redacted before logging (Q-644); ledger redacts secrets in input AND outcome.

## Notes
- The app's threat model keeps secrets out of the repo by construction (no cloud creds — it's an
  offline product). The redaction layer covers the realistic vector: a user pasting a credential
  into a goal/chat that then hits logs or the ledger.
