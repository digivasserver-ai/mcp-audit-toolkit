# Sample Audit Report — MCP Server Correctness & Exposure Review

> **This is a redacted sample.** Client identity, endpoints and environment specifics are withheld.
> The findings below are real and reproducible: they come from a public open-source MCP server
> (`chrisjohntapp/suse-mcp`) that was audited as a live client, and the fixes were published
> upstream as pull requests rather than kept private. Anyone can verify these numbers against that
> repository. What is redacted is who commissioned the work, not what was found.

| | |
|---|---|
| Engagement type | Pilot audit, fixed scope |
| Target | `suse-mcp` v0.x — stdio MCP server, 22 advertised tools |
| Environment | aarch64 openSUSE Tumbleweed, proot on Android 16 (no systemd, no display server, minimal coreutils) |
| Method | probed over stdio exactly as an MCP client connects; static schema↔signature diff; filesystem and command validation against the real target OS; credential fingerprint scan |
| Result | 6 findings — 3 high, 3 medium — all fixed upstream with regression tests |
| Verdict | **not production-ready as shipped**: 3 of 22 tools failed on every call, 6 more failed on this target platform |

---

## 1. Executive summary

The server advertised 22 tools and its health-check tool reported itself healthy. It was not.
Three tools raised `TypeError` on every invocation regardless of arguments, because the dispatcher
mapped them to function signatures that did not exist. Six further tools silently degraded to
"command not found" because command detection shelled out to a binary that is not present on the
target distribution. Two config readers returned nothing at all, because they looked for files at
Fedora paths that openSUSE does not use.

The failure mode is the dangerous kind: **every one of these tools reports success at the protocol
level and fails at the value level.** An agent calling `query_file_ownership` receives a well-formed
MCP error response and has no way to distinguish "your query was wrong" from "this tool has never
worked". Anything built on top of it inherits the defect silently.

## 2. Tool health matrix — all 22 advertised tools

Legend: **OK** = returns correct data · **FAIL** = raises or returns unusable data · **DEGRADED** = works only where the external binary exists

| # | tool | verdict | note |
|---|---|---|---|
| 1 | `get_system_info` | FAIL → fixed | reported empty hostname and uptime; `hostname` binary absent, no `/bin/uptime` |
| 2 | `analyze_zypper_conf` | FAIL → fixed | returned nothing; looked for `/etc/zypper/zypper.conf`, openSUSE ships `/etc/zypp/zypper.conf` |
| 3 | `analyze_rpm_macros` | FAIL → fixed | returned nothing; assumed one macro file, Tumbleweed splits macros across `/usr/lib/rpm/macros`, `macros.d` and `platform/<arch>` |
| 4 | `query_file_ownership` | FAIL → fixed | `TypeError` on every call — dispatcher passed arguments the handler never accepted |
| 5 | `optimize_mirrors` | FAIL → fixed | `TypeError` on every call — same class |
| 6 | `query_package_history` | FAIL → fixed | `TypeError` on every call — same class |
| 7 | `manage_orphans` | FAIL → fixed | bound the wrong parameters; the `exclude` list was unreachable |
| 8 | `remove_packages` | FAIL → fixed | `force-cascade` bound incorrectly, so the documented escape hatch could not be reached |
| 9 | `manage_install_reason` | FAIL → fixed | same binding defect |
| 10 | `verify_package_integrity` | DEGRADED → fixed | reported `CommandNotFound` — command probe used the external `which` binary |
| 11 | `install_obs_package` | DEGRADED → fixed | same `which` dependency |
| 12 | `run_system_health_check` | DEGRADED → fixed | aggregates the above; reported healthy while its own components were broken |
| 13 | `manage_patterns` | OK | |
| 14 | `check_database_freshness` | OK | |
| 15 | `check_updates_dry_run` | OK | |
| 16 | `get_official_package_info` | OK | |
| 17 | `search_obs` | OK | |
| 18 | `search_opensuse_wiki` | OK | |
| 19 | `fetch_news` | OK | |
| 20 | `diagnose_system` | OK | |
| 21 | `analyze_storage` | OK | 1 pre-existing test failure, unrelated to wiring, disclosed below |
| 22 | *(deprecated/dispatch variants)* | OK | after consolidation |

**Pre-fix: 9 of 22 tools broken or degraded. Post-fix: 22 of 22 working, 253 tests passing.**

## 3. Findings

### F-01 · HIGH · Dispatcher drift — tools that have never worked
**Tools:** `query_file_ownership`, `optimize_mirrors`, `query_package_history`
Three unified tools were registered with argument names that the underlying functions did not
accept. Every call raised `TypeError` inside the handler and was returned to the client as a tool
error.

*Reproduction*
```
call query_file_ownership(mode="file_to_package", query="/usr/bin/python")
→ TypeError: query_file_ownership() got an unexpected keyword argument ...
```
*Fix:* map each advertised tool to its real function signature; 16 dispatcher regression tests added
so a future mismatch fails loudly at test time instead of at call time. — [PR #2](https://github.com/chrisjohntapp/suse-mcp/pull/2)

### F-02 · HIGH · Platform path drift — Fedora paths on openSUSE
**Tools:** `analyze_zypper_conf`, `analyze_rpm_macros`
Configuration readers hard-coded `/etc/zypper/zypper.conf` and a single `/etc/rpm/macros` file.
openSUSE Tumbleweed ships `/etc/zypp/zypper.conf` and distributes macros across
`/usr/lib/rpm/macros`, `macros.d` and `platform/aarch64-linux`. Both tools returned empty results
and did not error.

*Reproduction*
```
$ test -f /etc/zypper/zypper.conf   # Fedora path
$ ls /etc/zypp/zypper.conf          # what the server actually needed
```
*Fix:* detect the distribution's real paths, merge all macro sources, derive the build arch from
the host rather than assuming. 4 new tests. — [PR #1](https://github.com/chrisjohntapp/suse-mcp/pull/1)

### F-03 · HIGH · Shell-dependency drift — `which` assumed present
**Tools:** 6 zypper-dependent tools, including `verify_package_integrity` and `run_system_health_check`
Command detection shelled out to the external `which` binary. That binary is absent on minimal
images, so every dependent tool reported its target command as not found — including commands that
were installed and working.

*Reproduction*
```
$ which zypper        # command not found — the binary that does the probing is missing
$ zypper --version    # zypper is installed and working
```
*Fix:* use `shutil.which`, which is in the standard library. 3 new tests.
— [PR #3](https://github.com/chrisjohntapp/suse-mcp/pull/3)

### F-04 · MEDIUM · Health check reports healthy while components are broken
`run_system_health_check` aggregates diagnostics but did not surface the `which`-related failures,
so an operator running the built-in health check would conclude the server was fine. Fixed as a
consequence of F-03.

### F-05 · MEDIUM · Environment-dependent output presented as system fact
`get_system_info` reported an empty hostname and a fabricated-looking uptime because the `hostname`
package and `/bin/uptime` were not present, and the shim fallback did not read `/proc/uptime`. An
agent consuming this output would treat blank/inaccurate system facts as real. Fixed; uptime is now
read from `/proc/uptime`.

### F-06 · MEDIUM · Unreachable documented parameters
Three package-management tools documented options (`exclude` lists, force-cascade) that could not be
reached because of argument binding. Documented behaviour and actual behaviour disagreed — the same
class of defect as F-01 but user-visible rather than fatal. Fixed with PR #2.

### Disclosed, not fixed
`tests/test_storage.py::test_analyze_storage_cache_stats` fails on the current platform. It is a
pre-existing upstream failure unrelated to tool wiring, left visible rather than suppressed.

## 4. Remediation delivered

| PR | scope | tests |
|---|---|---|
| [#1](https://github.com/chrisjohntapp/suse-mcp/pull/1) | SUSE paths, merged macro sources, host-arch detection | 4 new |
| [#2](https://github.com/chrisjohntapp/suse-mcp/pull/2) | dispatcher↔signature mapping, bound-argument fixes | 16 new |
| [#3](https://github.com/chrisjohntapp/suse-mcp/pull/3) | `shutil.which` command detection | 3 new |

Verification after fixes, run against the target platform:

```
253 passed, 1 failed in 25.87s
FAILED tests/test_storage.py::test_analyze_storage_cache_stats   # pre-existing, disclosed above
```

Each PR writes its regression test **red first**, so the defect is demonstrably reproducible before
the fix and demonstrably fixed after it.

## 5. Method — what "audited as a client" means

1. **Probe every advertised tool over stdio**, the same way a client connects — not by importing
   the package and calling functions directly. Defects in dispatch, transport and argument mapping
   are only visible through the protocol.
2. **Diff advertised schema against implementation.** Tool metadata is generated from one place and
   dispatch is wired in another; nothing enforces that they agree.
3. **Validate against the real target OS**, not the maintainer's distribution. Path and binary
   assumptions are the dominant defect class in Linux-targeted tooling.
4. **Fingerprint credential values, never print them.** sha256 prefix only, so a scan can prove
   exposure without leaking the secret into a report or a terminal history.

## 6. What this suggests about MCP servers generally

MCP has no conformance test. A server can advertise any schema it likes, and a client cannot tell
the difference between "tool works", "tool is broken", and "tool is broken *on this platform*".
The three defect classes in this report — dispatcher drift, platform path drift and shell-dependency
drift — are not exotic. They are what happens when a working library becomes a protocol server and
nothing verifies the join.

The tooling in this repository (`suse_mcp_check.sh`, `leak_scan.sh`) and the written methodology are
the reusable parts of this engagement.

---

*Sample report. Client identity redacted. Figures reproduced from the audit of a public repository;
the remediation pull requests are public and independently verifiable.*
