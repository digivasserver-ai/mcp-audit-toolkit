#!/bin/bash
# suse_mcp_check.sh — probe the SUSE MCP server exactly the way opencode talks to it,
# and report which tools actually work. Use after an opencode restart ("suse check").
# Read-only calls only: never exercises install/remove tools.
set -u
export PATH="/root/local/bin:/usr/local/bin:/root/bin:/usr/bin:/bin"
PY="/root/.local/share/uv/python/cpython-3.14-linux-aarch64-gnu/bin/python3.14"
[ -x "$PY" ] || PY="python3"
PROJ="/root/mcp/suse-mcp"

echo "== suse MCP check =="
echo "-- code under test --"
echo "branch: $(git -C "$PROJ" branch --show-current 2>/dev/null) @ $(git -C "$PROJ" log --oneline -1 2>/dev/null)"
echo "fixes:  shutil.which=$(grep -c 'shutil.which' "$PROJ/src/suse_ops_server/utils.py") mode_dispatch=$(grep -c 'file_to_package' "$PROJ/src/suse_ops_server/server.py") suse_zypper_path=$(grep -c 'etc/zypp/zypper.conf' "$PROJ/src/suse_ops_server/config.py")"

"$PY" - "$PROJ" <<'PYEOF'
import json, subprocess, sys
proj = sys.argv[1]
p = subprocess.Popen(
    ["/root/.local/bin/uv", "run", "--quiet", "--python", "3.14", "--project", proj, "suse-ops-server"],
    cwd=proj, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()

def read():
    return json.loads(p.stdout.readline())

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                 "clientInfo": {"name": "suse_mcp_check", "version": "0"}}})
init = read()
if "error" in init:
    print("initialize failed:", init)
    p.terminate(); sys.exit(2)
print("-- server --", init["result"]["serverInfo"])
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
tools = read().get("result", {}).get("tools", [])
print(f"-- tools: {len(tools)} exposed --")

CASES = [
    ("get_system_info", {}, "uptime+kernel"),
    ("analyze_zypper_conf", {}, "PR1 suse path"),
    ("analyze_rpm_macros", {}, "PR1 macro merge"),
    ("analyze_storage", {"action": "disk_usage"}, "disk"),
    ("check_database_freshness", {}, "repos"),
    ("manage_patterns", {"action": "list_patterns"}, "patterns"),
    ("query_file_ownership", {"query": "/usr/bin/zypper", "mode": "file_to_package"}, "PR2 mode dispatch"),
    ("optimize_mirrors", {"action": "status"}, "PR2 arg map"),
    ("query_package_history", {"query_type": "all", "limit": 3}, "PR2 query_type"),
    ("manage_orphans", {"action": "list"}, "PR2+PR3"),
    ("manage_install_reason", {"action": "list"}, "PR2 list branch"),
]
bad = 0
for i, (name, args, label) in enumerate(CASES, start=3):
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call",
          "params": {"name": name, "arguments": args}})
    text = "".join(c.get("text", "") for c in read().get("result", {}).get("content", []))
    detail = ""
    try:
        d = json.loads(text)
        if d.get("error"):
            bad += 1
            detail = f"FAIL {d.get('type')}: {str(d.get('message'))[:70]}"
        else:
            keys = [k for k in ("package", "config_path", "sources", "build_arch", "orphan_count",
                                "package_count", "database_count", "total_patterns", "paths_checked")
                    if k in d]
            detail = "ok   " + json.dumps({k: d[k] for k in keys})[:90]
    except Exception:
        bad += 1
        detail = f"FAIL non-json: {text[:70]}"
    print(f"  {name:26} {label:17} {detail}")
p.terminate()
print(f"-- result: {len(CASES) - bad}/{len(CASES)} healthy --")
sys.exit(1 if bad else 0)
PYEOF
RC=$?
if [ $RC -eq 0 ]; then
  echo "== suse MCP healthy =="
else
  echo "== suse MCP degraded (rc=$RC): restart opencode, then re-run 'suse check' =="
fi
exit $RC