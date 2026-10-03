# MCP Audit Toolkit

Two scripts and a method for answering a question most MCP deployments never ask:
**"are these tools actually wired correctly, and is anything leaking?"**

Built after auditing a real MCP server ([`chrisjohntapp/suse-mcp`](https://github.com/chrisjohntapp/suse-mcp)) as a live MCP client, where three of its 22 advertised tools raised `TypeError` on every call and two more reported a missing binary that was installed.

| tool | what it does |
|---|---|
| `leak_scan.sh` | Fingerprints credential **values** (sha256 prefix; the value is never printed) and hunts them across git objects, reflog, working tree, SQLite DBs, logs, prompt history and backup archives. Second pass hunts secret *shapes* it has never seen. |
| `suse_mcp_check.sh` | Starts an MCP server over stdio exactly the way a client does and probes it with read-only calls, printing a healthy/degraded table. |

## Quick start

```bash
# audit a repo for leaked secrets (reads credential names from a .profile-style file)
./leak_scan.sh --target /path/to/repo --profile ~/.profile

# take credentials from the environment instead
export GITLAB_TOKEN=... GITHUB_TOKEN=...
./leak_scan.sh --target . --env

# health-probe a local MCP server over stdio
./suse_mcp_check.sh
```

Output classes: `PUBLISHED` (present in git history already pushed), `LOCAL` (on disk only), `CLEAN`.

## The method (see `docs/METHODOLOGY.md`)

1. Read the real credential values from a profile file or the environment; store only a sha256 prefix + length.
2. Hunt those fingerprints in every store that can retain them, including inside `.tar.gz` archives.
3. Sweep separately for secret *shapes* (`glpat-`, `gh[pousr]_`, `AKIA…`, `PRIVATE KEY`, `X=…`) so a token never seen in the profile still surfaces.
4. Classify by exposure: git history already pushed is a different problem from a local file.
5. Remediate value-first — scrub history from the credential values themselves, so the procedure keeps working after a key rotation.

## Why fingerprint rather than regex

Regex catches shapes and misses the value you actually rotated in. Fingerprinting catches *that* credential everywhere, including the places nobody thinks to grep: SQLite WAL files, session databases, and compressed backups.

## Audit service

The same work is available as a fixed-scope engagement: every advertised tool called over stdio the
way a client connects, schema↔signature diff, platform path and dependency validation against your
real target OS, and a credential fingerprint scan.

- **Sample report (redacted):** [`docs/SAMPLE-AUDIT.md`](docs/SAMPLE-AUDIT.md) — 9 of 22 tools broken
  or degraded in the audited server, all fixed upstream with regression tests.
- **Landing page:** [`docs/index.html`](docs/index.html) — servable as-is via GitHub Pages.
- Pricing adaptable per scope: pilot from $250, standard (one server) from $750, deep (multi-server + CI)
  from $2,000. Microsoft Marketplace customers via Private Offer. Direct: PayPal (USD) or invoice.
- Scope and contact: divivas.server@gmail.com

## Provenance

Developed and tested on an aarch64 openSUSE Tumbleweed proot terminal, against the live `suse-mcp` server. Findings were disclosed upstream as pull requests with fixes and regression tests; no vulnerability was claimed, because the issues found were correctness bugs rather than security issues. `docs/OPENSUSE-MCP-LANDSCAPE.md` is an independent inventory of the MCP work happening in the SUSE ecosystem, written so the project can see its own position clearly.

MIT licensed.

A note on scope: an earlier revision of this repository also contained a third-party inventory of MCP work in the SUSE/openSUSE ecosystem. It was removed at the author's request — analysis of a third party's positioning is not something to publish unprompted, and the tooling speaks for itself.