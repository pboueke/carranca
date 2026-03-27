# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in carranca, please report it through
[GitHub Security Advisories](https://github.com/pboueke/carranca/security/advisories/new).
This is the preferred channel because it allows private discussion before public disclosure.

Please include in your report:

- A description of the vulnerability
- Steps to reproduce
- Affected version (commit hash or release tag)
- Your assessment of impact and severity

Do not open a public issue for security vulnerabilities.

## Supported Versions

Only the latest release on the `main` branch receives security fixes.
Carranca does not maintain backport branches.

## Scope

### In scope

The following are considered carranca vulnerabilities:

- Container isolation bypass (agent escaping the container boundary)
- HMAC chain forgery or verification bypass
- Log tampering undetected by `carranca log --verify`
- Seccomp, capability, or AppArmor profile bypass
- Network policy bypass (beyond documented limitations)
- Privilege escalation within the runtime
- Information disclosure of operator config to the agent

### Out of scope

The following are **not** carranca vulnerabilities:

- Operator misconfiguration (e.g., adding `CAP_SYS_ADMIN` to `cap_add`, setting `runtime.network: true` when isolation is desired)
- Known limitations documented in the [threat table](doc/trust-model.md#threat-table) (e.g., DNS tunneling, HMAC key locality)
- Agent producing bad, insecure, or malicious code (carranca constrains behavior, it does not judge output)
- Attacks requiring host root access or physical access
- Vulnerabilities in the container runtime itself (Podman, Docker)

## Credit

Reporters receive credit in the changelog and security advisory unless they prefer anonymity.
