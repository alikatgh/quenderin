# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.0.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it by emailing the maintainers directly rather than opening a public issue.

**Please include the following information:**

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if any)

We will respond to security reports within 48 hours and will keep you informed throughout the process.

## Security Model

Quenderin runs **fully on-device**: models are local GGUF files executed via
`node-llama-cpp`. There are **no cloud LLM providers, no API keys, and no `quenderin.json`
config file** — so there is nothing to store a key in, and no key ever leaves the machine.
Configuration is via environment variables and the in-app Settings UI.

### Local server binding

The dashboard/agent server binds to **loopback (`127.0.0.1`) by default** on port **3000**
(override with `--port`). It is **unauthenticated**, so it must not be exposed to the
network. Set `QUENDERIN_HOST=0.0.0.0` only on a trusted network and at your own risk.

Defense-in-depth on the local server:
- CORS and WebSocket connections are restricted to localhost origins (a literal `null`
  origin is rejected); the WebSocket upgrade is pinned to `/ws`.
- A Content-Security-Policy header is set.
- JSON request bodies are capped at **256 KB**; attachment count/size are capped.
- `/api/docs` serves only an allowlist of public docs.
- Device-sourced UI XML is parsed with entity expansion disabled.

There is **no rate limiting** — the loopback-only binding is the intended control. If you
expose the server, put your own authentication and rate limiting in front of it.

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

We take security seriously and will:
- Patch critical vulnerabilities within 24-48 hours
- Release security updates as soon as they're ready
- Notify users through GitHub releases and security advisories
- Maintain a changelog of security fixes

## Dependencies

- Run `npm audit` to check for known vulnerabilities. There is currently **no CI audit gate
  and no Dependabot configuration** — the dependency-vulnerability backlog is tracked in
  `docs/audits/2026-06-14-CONSOLIDATED-open-findings.md`.
- Review dependencies before updating.

## Responsible Disclosure

We follow responsible disclosure practices:
- Security researchers are credited in release notes (if desired)
- We aim to fix vulnerabilities before public disclosure
- Coordinated disclosure timeline of 90 days

Thank you for helping keep Quenderin and its users safe!
