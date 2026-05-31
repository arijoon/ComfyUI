---
name: audit-deps
description: Audit Python dependencies for known vulnerabilities (CVEs) using the OSV database
user-invocable: true
---

# Audit Dependencies

Run a security audit of all locked Python packages against the OSV (Open Source Vulnerabilities) database.

## Steps

1. Run the audit via nix:

```bash
nix run .#audit-deps
```

Or from inside the devshell: `audit-deps`

2. If vulnerabilities are found, report findings to the user with package name, version, CVE ID, summary, severity, and fixed version.

3. If the user wants to fix them, update the version pin in `requirements.local.txt` and run `sync-deps`.
