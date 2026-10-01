# Methodology: auditing an MCP server as a client would

This is the process that produced the findings in `README.md`. It is deliberately cheap — an afternoon, no lab, no exploit tooling.

## Why the client is the right vantage point

Reading an MCP server's source tells you what it intends. Calling its tools tells you what it does. The gap between the two is where MCP servers break, because the tool schema is declared in one place and dispatched to functions in another, with nothing in between that keeps them in agreement.

Two patterns showed up immediately, on every server audited so far:

### 1. Dispatcher drift — the schema promises arguments the function never accepted

A tool declares `query`, `mode`, `filter_pattern`. The dispatcher passes all three to a function taking one parameter. Every call raises `TypeError`, regardless of platform:

```
query_file_ownership() takes 1 positional argument but 3 were given
optimize_mirrors() got an unexpected keyword argument 'country'
query_package_history() got an unexpected keyword argument 'query_type'
```

Silent variants are worse. `manage_orphans(action, dry_run, exclude)` bound to `(action, packages, dry_run)` — arguments land in the wrong slots, the tool returns plausible output, and nothing is obviously wrong. `remove_packages(packages, remove_dependencies, force)` bound to `(packages, orphan_check, cascade)` meant cascade removal was simply unreachable.

**How to detect it:** mechanically compare each tool's `inputSchema` properties against the signature of the function its dispatcher calls. Anything advertised but not accepted is a defect. This is a static check; it needs no running server.

**How to prevent it:** drive `call_tool` in tests with mocked backends and assert the exact argument mapping. That is what the upstream PR did — 16 tests that fail loudly the moment a signature drifts.

### 2. Platform path drift — paths hard-coded to the wrong distribution

Code written on one Linux tends to carry that distribution's filesystem layout. On openSUSE, two tools returned `NotFound` forever because they looked for:

| expected | openSUSE reality |
|---|---|
| `/etc/zypper/zypper.conf` | `/etc/zypp/zypper.conf` (owned by the `zypper` package) |
| `/etc/rpm/macros`, read as a file | `/etc/rpm/macros` is an empty **directory**; macros live in `/usr/lib/rpm/macros`, `/usr/lib/rpm/macros.d/` and `/usr/lib/rpm/platform/<triplet>/macros` |

**How to detect it:** run the tool on the platform you actually care about and compare the result against ground truth you can verify independently (`rpm -ql zypper`, `rpm --eval '%{_arch}'`).

### 3. Shell-dependency drift — assuming a binary exists

```python
result = os.system(f"which {command} > /dev/null 2>&1")   # no `which` on minimal images
return result == 0
```

On a minimal image — containers, proot, distroless-ish systems — `which` is absent, so every guarded tool reports the command as missing even when it is installed at an absolute path. `shutil.which` is pure Python and has no such dependency. Checked in nine places in the audited server, so the blast radius was wider than the single tool that exposed it.

## The playbook

1. **Enumerate.** `tools/list` over stdio. Count them. That count is your coverage target.
2. **Call every read-only tool once**, with arguments the schema suggests. Record the exact error, not just "failed".
3. **Cross-check the answers** against something independent (`rpm -ql`, `df`, `/proc/uptime`). A tool that returns data can still be wrong — one audit initially reported `build_arch: x86_64` on an aarch64 host because it globbed every architecture's macro directory and the last one won.
4. **Compare schema to signature, statically.** This finds the drift a smoke test misses.
5. **Assume the maintainer is right about scope, not about paths.** Configuration drift is a bug report; a design choice is a discussion.
6. **Fix with tests, red first.** A PR with a fix and no regression test will be reintroduced.
7. **Do not overclaim.** Correctness bugs are not CVEs. Filing them as security findings costs the maintainer goodwill and your credibility.

## Leak hunting as a companion discipline

The same instinct applies to data: a tool or pipeline is only as trustworthy as its blind spots, so enumerate where a secret *can* live and check each one, rather than grepping the obvious file.

Places that routinely hold credential values and are routinely forgotten:

- git object store and reflog — including objects only reachable through tags
- SQLite databases **and their `-wal` files**
- application session databases and logs (chat/assistant history stores anything pasted)
- "safe" backups of files that were already scrubbed — a backup can reintroduce a secret that the live file no longer has
- compressed backups, which defeat a plain `grep`

The failure this method catches most usefully: **a secret removed from a file but still present in git history.** Verifying only the working tree, or only the shapes you remember, will report clean. Fingerprint the actual value and search every object.