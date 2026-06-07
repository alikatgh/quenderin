# Contributing to Quenderin

Thanks for your interest! Quenderin is MIT-licensed and we welcome contributions.
Be respectful, be constructive, be collaborative.

## Getting started

```bash
git clone https://github.com/alikatgh/quenderin
cd quenderin
npm install && (cd ui && npm install)
npm run dashboard        # http://localhost:3000
```

New to the codebase? Read **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** first,
then the area you're touching: [BACKEND](docs/BACKEND.md), [API](docs/API.md),
[FRONTEND](docs/FRONTEND.md), or [DEVELOPMENT](docs/DEVELOPMENT.md).

## Workflow

1. For major changes, open an issue first to discuss the approach.
2. Branch off `main`: `git checkout -b feature/your-feature`.
3. Make a **focused** change — one logical feature/fix per PR.
4. Run the quality gate: **`npm run check`** (typecheck + lint + tests) must pass.
5. Update docs in the same PR if you changed behavior, routes, or the WebSocket
   protocol.
6. Open a PR: clear title, what changed and why, related issues, screenshots for
   UI changes.

### Commit messages (conventional commits)
`feat:` · `fix:` · `docs:` · `test:` · `refactor:` · `chore:`

## Ground rules

Enforced — for safety, privacy, and maintainability:

- **TypeScript discipline** — no `any` in shared types and no `@ts-ignore`
  without a comment. `npm run typecheck` stays green.
- **Never remove safety-blocklist entries** (Pay, Delete, Password, …). Add to it
  when a new dangerous action class appears.
- **Never hardcode model paths** — use the catalog + discovery logic.
- **Privacy is the product** — no telemetry, no analytics, no runtime network
  calls beyond the one-time model download. Don't add any.
- **Errors surface to the UI** (WebSocket `error` events) — never silently swallow.
- **Electron** — `contextBridge` only, never `nodeIntegration: true`. IPC typed both ways.
- **New WebSocket message types** — add to the TypeScript interfaces in both
  directions and update [docs/API.md](docs/API.md).

## UI changes

Follow the design system: interactive state never changes geometry; hairline
borders (no shadows); hierarchy in weight + size; tabular numbers; monospace for
codes/metrics. Density over decoration — this is a developer power tool.

## Native mobile (`apple/`)

The Swift package unit-tests on a Mac with `swift test` (Swift 6 / Xcode 16+).
See [apple/QuenderinKit/README.md](apple/QuenderinKit/README.md) and
[apple/QuenderinKit/INTEGRATION.md](apple/QuenderinKit/INTEGRATION.md).

## Review process

A maintainer reviews each PR for: does it work, do tests pass, does it follow
conventions, are docs updated, no undiscussed breaking changes. Make requested
changes by pushing to your branch; once approved, a maintainer merges.

## Getting help

- **Questions:** GitHub Discussions
- **Bugs:** GitHub Issues (include OS + Node version + repro steps)
- **Security:** see `SECURITY.md`

## License

By contributing, you agree your contributions are licensed under the MIT License.
