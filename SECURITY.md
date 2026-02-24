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

## Security Considerations

### API Key Storage

**Important:** Quenderin stores API keys in plaintext in the `quenderin.json` configuration file.

**Best Practices:**
1. Never commit `quenderin.json` to version control (it's in `.gitignore` by default)
2. Use environment variables for API keys in production environments
3. Restrict file permissions on `quenderin.json`:
   ```bash
   chmod 600 quenderin.json
   ```
4. Regularly rotate your API keys
5. Use separate API keys for development and production

### Local-First Security

Quenderin prioritizes local-first operation:
- Works completely offline with Ollama
- No telemetry or tracking
- Your code stays on your machine
- Open source and auditable

### Network Security

When using cloud LLM providers:
- All API communications use HTTPS
- API keys are only sent to the configured provider
- No data is sent to third parties
- Rate limiting is enabled on the UI server

### UI Server Security

The web UI server (port 3777) includes:
- CORS restricted to localhost only
- Rate limiting (100 requests per 15 minutes)
- Input validation on all endpoints
- File upload size limits (1MB max)

**Note:** The UI server is designed for local development only and should not be exposed to the internet.

## Security Updates

We take security seriously and will:
- Patch critical vulnerabilities within 24-48 hours
- Release security updates as soon as they're ready
- Notify users through GitHub releases and security advisories
- Maintain a changelog of security fixes

## Dependencies

We regularly update dependencies to address security vulnerabilities:
- Run `npm audit` to check for known vulnerabilities
- Automated Dependabot updates are enabled
- All dependencies are reviewed before updates

## Responsible Disclosure

We follow responsible disclosure practices:
- Security researchers are credited in release notes (if desired)
- We aim to fix vulnerabilities before public disclosure
- Coordinated disclosure timeline of 90 days

Thank you for helping keep Quenderin and its users safe!
