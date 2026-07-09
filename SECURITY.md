# Security Policy

## Reporting a Vulnerability

We take security issues seriously. If you discover a security vulnerability in
Bishon V2, please report it responsibly.

**Do NOT open a public GitHub Issue for security vulnerabilities.**

Instead, use **GitHub's Private Vulnerability Reporting**:

1. Go to <https://github.com/dliting/Bishon/security/advisories/new>.
2. Click **"Report a vulnerability"**.
3. Fill in the advisory form with reproduction steps and impact assessment.

You should receive an initial response within 72 hours. We will coordinate
disclosure timing with you and credit your report (unless you prefer to remain
anonymous).

## Supported Versions

Only the latest minor release receives security fixes. Please upgrade before
reporting.

| Version | Supported |
|---------|-----------|
| 2.0.x   | Yes       |
| < 2.0   | No        |

## Scope

**In scope:**
- Remote code execution, SQL injection, path traversal, SSRF.
- Authentication/authorization bypass (when an auth layer is added).
- Data leakage from FAISS / SQLite stores.
- File upload handling issues (path traversal, MIME confusion, etc.).

**Out of scope (this is an internal-use tool by design):**
- Issues that require local filesystem access beyond the install directory.
- DoS via very large uploads (we already cap at typical document sizes).
- Self-XSS that requires the user to paste attacker-controlled content.

## Hardening Recommendations for Production Deployments

- Run the service as a non-root user.
- Put it behind a reverse proxy (nginx / Caddy) with TLS.
- Restrict network exposure to trusted users (no built-in authentication layer yet).
- Back up `BISHON_DB/` regularly.
- Avoid embedding real API keys in the public `.env` — keep `.env` private and never commit it.
