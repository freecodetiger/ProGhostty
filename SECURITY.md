# Security Policy

## Supported Versions

ProGhostty supports the latest release and one prior minor version.

| Version | Supported |
|---------|-----------|
| Latest release (`v0.4.x`) | ✅ |
| One prior minor (`v0.3.x`) | ✅ |
| Earlier versions | ❌ |

If you're running an unsupported version, please update before reporting — the issue may already be fixed.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/freecodetiger/ProGhostty/security)
2. Click **Report a vulnerability**
3. Include as much detail as possible:
   - Affected version(s)
   - Steps to reproduce
   - Impact assessment
   - Suggested fix (if you have one)

### What to Include

A good security report helps us respond faster. Please describe:

- **What** — the vulnerability and its attack surface
- **How** — steps to reproduce or a proof of concept
- **Impact** — what an attacker could do (data access, code execution, denial of service, etc.)
- **Scope** — which component is affected (see below)

## Response Timeline

| Step | Target |
|------|--------|
| Acknowledge receipt | Within **48 hours** |
| Initial assessment | Within **7 days** |
| Fix for confirmed issues | Within **30 days** |
| Coordinated disclosure | After fix is released |

We may reach out for clarification during the assessment. If the issue is confirmed, we'll work on a fix and coordinate disclosure with you.

## Disclosure Policy

- We fix confirmed vulnerabilities and include the fix in the next release.
- After the fix is released, we publish a security advisory via GitHub Security Advisories.
- We credit reporters unless they prefer to remain anonymous.
- We ask that you **do not publicly disclose** the vulnerability until we've released the fix and coordinated the announcement.

## Scope

The following components are in scope for security reports:

| Component | Description |
|-----------|-------------|
| Terminal emulation | VT state handling, ANSI/OSC parsing via `libghostty-vt` |
| PTY handling | Process forking, I/O, signals, resize (`ProGhosttyPTY`, `PTYTerminalEngine`) |
| Rendering | Metal direct rendering, cell-grid fallback, frame pipeline |
| Settings persistence | UserDefaults, SQLite storage (`ProGhosttyCore/Persistence`) |
| Bundled dependencies | Vendored Ghostty (`Vendor/ghostty/`) — also report upstream if applicable |
| Build & release | CI workflows, code signing, DMG packaging |

### Out of Scope

- Issues in upstream Ghostty that do not affect ProGhostty's usage (report to [Ghostty](https://github.com/ghostty-org/ghostty) directly)
- Issues in user shell configurations (zsh, fish, etc.)
- General macOS vulnerabilities unrelated to ProGhostty

## Acknowledgments

We appreciate the security research community's efforts in responsibly disclosing vulnerabilities. Thank you for helping keep ProGhostty and its users safe.
