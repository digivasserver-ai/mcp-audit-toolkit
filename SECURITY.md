# Security policy

No security issues are currently known in this toolkit's own code
(two shell probes + docs). The audited server's findings were
correctness bugs, not vulnerabilities, and were disclosed upstream as
fix PRs with regression tests.

To report a genuine vulnerability in this repo:

- Email divivas.server@gmail.com with "SECURITY" in the subject.
- Include reproduction steps and `suse_mcp_check.sh` / `leak_scan.sh` output.
- Allow 48h for acknowledgement before any disclosure.

Scope: this repo only. Upstream `suse-mcp` issues belong upstream
(or on the maintained fork once published).
