# Security Policy

## Reporting a Vulnerability

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/alikatgh/quenderin/security/advisories/new).
Keep vulnerability details out of public issues and pull requests. Do not include
real credentials or personal data; use sanitized examples.

**Please include the following information:**

- Description of the vulnerability
- Affected platform and exact app version or source commit
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if any)

We assess reports privately and coordinate fixes and disclosure with the reporter.
Response and release timing depend on the impact and the verification required.

## Security Model

Desktop local-model inference uses local GGUF files executed via `node-llama-cpp`;
this inference path does not require a cloud LLM provider key. The local dashboard
uses a separate, per-launch authentication token.
Configuration is via environment variables and the in-app Settings UI.

### Local server binding

The dashboard/agent server binds to **loopback (`127.0.0.1`) by default** on port **3000**
(override with `--port`). Mutating API requests, protected user-data reads and
WebSocket connections require the per-launch token. Public readiness and catalog
routes remain accessible without it. Keep the server on loopback; the token does
not make a network-exposed server safe.

Defense-in-depth on the local server:
- CORS and WebSocket connections are restricted to localhost origins (a literal `null`
  origin is rejected); the WebSocket upgrade is pinned to `/ws`.
- A Content-Security-Policy header is set.
- JSON request bodies are capped at **256 KB**; attachment count/size are capped.
- `/api/docs` serves only an allowlist of public docs.
- Device-sourced UI XML is parsed with entity expansion disabled.

There is **no rate limiting**. Loopback binding, token authentication and origin
checks are separate controls; they do not replace supervision or protect against
every process running under the same user account.

### Autonomous device control — experimental

The agent issues real input to the host and any connected device. Action safety is gated by
an **experimental, English keyword blocklist** that is **not** a robust safety boundary — it
misses paraphrases, other languages, and prompt-injected instructions from on-screen content.
Treat the agent as experimental, supervise it, and do not point it at sensitive apps or
accounts.

### What stays local
- No telemetry or tracking; the agent's data lives under your home directory.
- Open source and auditable.
- After the one-time model download, normal operation needs no network.

## Security Updates

Security fixes are documented in the changelog and applicable GitHub releases or
security advisories. A merged source fix does not establish that updated native
apps have been published to their stores.

## Dependencies

- CI runs `npm audit --audit-level=high` for the root npm dependency tree.
- `.github/dependabot.yml` configures weekly version updates for the root and UI
  npm packages, GitHub Actions and Android Gradle dependencies, with separate
  security-update groups. Automatic security-update PR generation is controlled
  separately by repository settings.
- GitHub Dependabot alerts, secret scanning and push protection are enabled.
  Their coverage depends on recognized dependencies and supported secret patterns;
  they do not establish that the project is free of vulnerabilities or secrets.
- The Secret scan workflow checks tracked files with the project's bounded scanner.
- Review dependencies before updating.

## Responsible Disclosure

We follow responsible disclosure practices:
- Security researchers are credited in release notes (if desired)
- We aim to fix vulnerabilities before public disclosure
- Disclosure timing is coordinated with the reporter

Thank you for helping keep Quenderin and its users safe!
