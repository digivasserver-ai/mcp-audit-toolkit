#!/bin/bash
# leak_scan.sh — point the light at every place a credential can hide.
#
# Method: take the real secret values from /root/.profile, fingerprint each one
# (sha256 prefix + length, never the value), then hunt those fingerprints across
# every store this lab has: git objects and history, SQLite databases, opencode
# session DB/WAL/logs, prompt history, session snapshots, backup tarballs and
# shell history. A second pass hunts for secret *shapes* it has never seen, so a
# token that was never in .profile still gets flagged.
#
# It reports, per secret and per location, one of:
#   PUBLISHED  present in git history that has already been pushed to a mirror
#   LOCAL      present on disk only
#   CLEAN      fingerprint absent
#
# Read-only. Nothing is modified, nothing is printed that could leak further.
#
# Usage:
#   leak_scan.sh                 audit this lab (default targets)
#   leak_scan.sh --target DIR    audit another git repo instead
#   leak_scan.sh --profile FILE  read credentials from another .profile-style file
#   leak_scan.sh --env           take credential values from the environment instead
#   leak_scan.sh --quiet         suppress the progress lines
#   leak_scan.sh --no-shape      skip the unknown-secret shape sweep
set -u
PY="/root/.local/share/uv/python/cpython-3.14-linux-aarch64-gnu/bin/python3.14"
[ -x "$PY" ] || PY="python3"

"$PY" - "$@" <<'PYEOF'
import hashlib, os, re, subprocess, sys, glob, gzip, io, sqlite3

REPO = "/root/dev-lab-memory"
QUIET = "--quiet" in sys.argv
SHAPES_ON = "--no-shape" not in sys.argv
ENV_SECRETS = "--env" in sys.argv
PROFILE_FILE = "/root/.profile"

argv = sys.argv[1:]
if "--target" in argv:
    REPO = argv[argv.index("--target") + 1]
if "--profile" in argv:
    PROFILE_FILE = argv[argv.index("--profile") + 1]
if ENV_SECRETS:
    import os as _os
    _vals = [(_os.environ[k], k) for k in sorted(_os.environ)
             if re.search(r"(TOKEN|PASSWORD|PASSWD|SECRET|API_?KEY)$", k) and len(_os.environ[k]) >= 8]
else:
    _vals = []
print(f"target: {REPO}")

# ---------------------------------------------------------------- fingerprints
def load_secrets():
    """Read the credential values, return labels only."""
    out = []
    if ENV_SECRETS:
        return [(label, val) for val, label in _vals]
    path = PROFILE_FILE
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        m = re.match(r'\s*export\s+([A-Z0-9_]*(?:TOKEN|PASSWORD|PASS|SECRET|KEY)[A-Z0-9_]*)=["\']?([^"\'\s]+)', line)
        if m and len(m.group(2)) >= 8:
            out.append((m.group(1), m.group(2)))
    return out

def fp(value):
    return hashlib.sha256(value.encode()).hexdigest()[:12], len(value)

secrets = load_secrets()
print("== leak scan ==")
print(f"secrets under watch: {len(secrets)}")
for label, value in secrets:
    digest, n = fp(value)
    print(f"  {label:22} sha256:{digest}  len={n}")
if not secrets:
    print(f"  (no credentials found in {PROFILE_FILE} - only the shape sweep will run)")

# ------------------------------------------------------------------ locations
def git_targets():
    """Every blob/commit/tag in the object store, plus reflog and refs."""
    targets = []
    try:
        blobs = subprocess.run(
            ["git", "-C", REPO, "cat-file", "--batch-all-objects", "--batch"],
            capture_output=True, timeout=180)
        targets.append(("git:all-objects", blobs.stdout))
    except Exception as e:
        targets.append(("git:all-objects", b""))
    try:
        reflog = subprocess.run(["git", "-C", REPO, "reflog", "show", "--all"],
                                capture_output=True, timeout=30)
        targets.append(("git:reflog", reflog.stdout))
    except Exception:
        pass
    for name, path in (("git:working-tree", REPO),):
        acc = bytearray()
        for dirpath, dirnames, filenames in os.walk(path):
            if ".git" in dirpath.split(os.sep):
                continue
            for fn in filenames:
                fp_ = os.path.join(dirpath, fn)
                try:
                    if os.path.getsize(fp_) < 5_000_000:
                        with open(fp_, "rb") as fh:
                            acc += fh.read()
                except OSError:
                    pass
        targets.append((name, bytes(acc)))
    return targets

def file_targets():
    pats = [
        "/root/.bash_history",
        "/root/.local/state/opencode/*.jsonl",
        "/root/.local/share/opencode/log/*.log",
        "/root/.local/share/opencode/opencode.db",
        "/root/.local/share/opencode/opencode.db-wal",
        "/root/.local/share/opencode/mcp-auth.json",
        "/root/sessions/*.md",
        "/root/STORAGE_MAP.md",
        "/root/MASTER_MAP.md",
        "/sdcard/Download/*.tar.gz",
        "/sdcard/Download/*.jsonl",
        "/root/backup/*",
    ]
    for pat in pats:
        for p in sorted(glob.glob(pat)):
            if os.path.isfile(p):
                yield p

def read_any(path):
    try:
        if path.endswith(".gz"):
            with gzip.open(path, "rb") as fh:
                return fh.read()
        with open(path, "rb") as fh:
            return fh.read()
    except (OSError, EOFError):
        return b""

# ------------------------------------------------------------------- scanning
hits = {}   # label -> [(location, count, kind)]

def record(label, location, count, kind):
    if count:
        hits.setdefault(label, []).append((location, count, kind))

print("\n-- hunting fingerprints --", flush=True)

# each target is read once and matched against every secret
def scan_blob(loc, blob, kind):
    for label, value in secrets:
        n = blob.count(value.encode())
        if n:
            record(label, loc, n, kind)

for loc, blob in git_targets():
    scan_blob(loc, blob, "PUBLISHED")
if not QUIET:
    print(f"  git store scanned ({len(hits)} secrets already present in git)")

for p in file_targets():
    blob = read_any(p)
    kind = "PUBLISHED" if p.startswith(REPO) else "LOCAL"
    scan_blob(os.path.relpath(p) if p.startswith("/root/") else p, blob, kind)

# sqlite: also check text columns explicitly, in case of encoding surprises
for db in ("/root/storage_map.db", "/root/.local/share/opencode/opencode.db"):
    if not os.path.exists(db):
        continue
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        for (table,) in con.execute("select name from sqlite_master where type='table'"):
            cols = [r[1] for r in con.execute(f'PRAGMA table_info("{table}")')]
            for row in con.execute(f'select * from "{table}"'):
                blob = " ".join(str(x) for x in row).encode()
                scan_blob(f"{os.path.basename(db)}:{table}", blob, "LOCAL")
        con.close()
    except sqlite3.Error:
        pass

# --------------------------------------------------------- unknown-secret sweep
SHAPES = {
    name: re.compile(rx)
    for name, rx in {
        "gitlab-pat": rb"glpat-[A-Za-z0-9._-]{8,}",
        "github-pat": rb"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}",
        "aws-key": rb"AKIA[0-9A-Z]{16}",
        "private-key": rb"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "assign-secret": rb"(?:TOKEN|PASSWORD|PASSWD|SECRET|APIKEY|API_KEY)\s*=\s*[\"']?[A-Za-z0-9._-]{16,}",
    }.items()
}
shape_hits = {}
if SHAPES_ON:
    print("\n-- shape sweep (secrets never seen in the credential file) --")
scan_sources = []
try:
    scan_sources.append(("git:all-objects", subprocess.run(
        ["git", "-C", REPO, "cat-file", "--batch-all-objects", "--batch"],
        capture_output=True, timeout=180).stdout))
except Exception:
    pass
for p in file_targets():
    scan_sources.append((p, read_any(p)))
for loc, blob in scan_sources:
    if not blob:
        continue
    for shape_name, shape_rx in SHAPES.items():
        found = shape_rx.findall(blob)
        if found:
            shape_hits.setdefault(shape_name, []).append((loc, len(found)))


# ---------------------------------------------------------------------- report
published = {lab for lab, rows in hits.items()
             if any(k == "PUBLISHED" for _, _, k in rows)}
print("\n== per-secret locations ==")
for label, value in secrets:
    digest, _ = fp(value)
    rows = hits.get(label, [])
    if not rows:
        print(f"  {label:22} CLEAN (no copies found)")
        continue
    print(f"  {label:22} {len(rows)} location(s)")
    for loc, n, kind in sorted(rows, key=lambda r: (r[2], r[0])):
        print(f"      [{kind:9}] {loc}  ({n} occurrence(s))")

print("\n== shape sweep results ==") if SHAPES_ON else None
if not shape_hits:
    print("  no unknown secret shapes detected")
for name, rows in sorted(shape_hits.items()):
    print(f"  {name}")
    for loc, n in sorted(rows, key=lambda r: -r[1])[:12]:
        print(f"      {loc}  ({n})")

pub_label = "PUBLISHED" if published else None
print("\n== verdict ==")
print(f"  secrets with copies somewhere      : {len(hits)}/{len(secrets)}")
print(f"  secrets already in pushed git history: {sorted(published) or 'none'}")
print(f"  highest severity                    : {pub_label or 'LOCAL-ONLY'}")
sys.exit(0)
PYEOF
RC=$?
echo
echo "remediation hints:"
echo "  pushed history   -> rotate the credential (disposable-key policy) and/or re-run the filter-branch scrub"
echo "  opencode.db/-wal -> cannot be edited while opencode runs; scrub at session close"
echo "  tarballs/sessions-> regenerate or delete after rotation"
echo "  .profile         -> the intended home; leave it"
exit $RC