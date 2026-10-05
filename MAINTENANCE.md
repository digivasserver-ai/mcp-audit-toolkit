# Maintenance pledge — SUSE MCP gateway

This file declares what "maintained" means for the SUSE MCP work
audited by this toolkit, so a funder can verify it without asking.

## What is maintained

- Upstream: `chrisjohntapp/suse-mcp` (`suse-ops-server`, 22 tools over
  zypper / OBS / openSUSE Wiki / system info). Three fix PRs open since
  2026-09-30 (#1 SUSE paths + RPM macros, #2 tool-dispatch signatures,
  #3 `shutil.which`), all `mergeable: true`, untouched by upstream.
- Maintained branch (local, published as fork on maintainer decision):
  `local/tumbleweed-fixes` = upstream + all three PRs merged.
  Verified: suite 250 pass / 1 pre-existing fail, live on aarch64
  openSUSE Tumbleweed via `suse_mcp_check.sh`.

## Pledge

- Triage: new issues acknowledged within 48h, reproduction with
  `suse_mcp_check.sh` output or closed as needs-info.
- Releases: monthly while upstream is silent; versioned tags, changelog
  from `git log --oneline`.
- Health signal: weekly 22-tool matrix published to `docs/SAMPLE-AUDIT.md`
  (re-run, not recalled). Any regression opens an issue the same day.
- Security: correctness bugs fixed with regression tests (the three
  classes in `docs/METHODOLOGY.md`); credential leaks scanned with
  `leak_scan.sh` before every release.
- Scope boundary: this pledge covers the gateway staying installable,
  callable, and correct on Tumbleweed. It does not cover feature work.

## Roadmap funders pay for (not promises)

1. Backlog triage + CI on the maintained fork (done locally, needs publish).
2. Tumbleweed-native OBS package `mcp-server-suse` so `zypper install`
   works on a fresh system (unfilled gap, see toolkit README provenance).
3. Audit hardening: schema↔signature diff in CI, dependency reality check,
   secret-scan gate on every tag.

## Verify without trusting this file

```bash
./suse_mcp_check.sh            # 22-tool live probe, healthy/degraded table
./leak_scan.sh --target . --env # PUBLISHED / LOCAL / CLEAN
git log --oneline -5           # release cadence
```

Funding (user activates): GitHub Sponsors + Polar via `.github/FUNDING.yml`.
Grants target: NLnet NGI0 Commons (next deadline Nov 3 2026, €5k–50k),
Sovereign Tech Fund (min €50k costs), GitHub Secure OSS Fund ($10k rolling).
