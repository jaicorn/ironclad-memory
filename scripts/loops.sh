#!/usr/bin/env bash
set -euo pipefail

# loops.sh — Quick summary of open ledger items.
# Fast, deterministic, safe to call frequently.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_workspace() {
  if [[ -n "${IRONCLAD_WORKSPACE:-}" ]]; then
    echo "$IRONCLAD_WORKSPACE"
    return
  fi
  local dir
  dir="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [[ -d "$dir/.ironclad" ]]; then echo "$dir"; return; fi
  local check="$dir"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then echo "$check"; return; fi
    check="$(dirname "$check")"
  done
  check="$(pwd)"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then echo "$check"; return; fi
    check="$(dirname "$check")"
  done
  echo "$dir"
}

WORKSPACE="$(detect_workspace)"
LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"

format="text"
priority_filter=""
owner_filter=""
status_filter=""
max_items=20
counts_only=0

usage() {
  cat <<'EOF'
Usage:
  loops.sh [options]

Show a compact summary of open commitment ledger items.

Options:
  --json              Output as JSON array
  --priority P        Filter by priority (p0, p1, p2, p3)
  --owner OWNER       Filter by owner
  --status STATUS     Filter by status
  --max N             Max items to show (default: 20)
  --counts-only       Just print counts by priority and status
  -h, --help          Show help

Examples:
  loops.sh                     # compact text summary
  loops.sh --counts-only       # just counts
  loops.sh --priority p0       # fires only
  loops.sh --json              # machine-readable
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        format="json"; shift ;;
    --priority)    priority_filter="$2"; shift 2 ;;
    --owner)       owner_filter="$2"; shift 2 ;;
    --status)      status_filter="$2"; shift 2 ;;
    --max)         max_items="$2"; shift 2 ;;
    --counts-only) counts_only=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -s "$LEDGER" ]]; then
  if [[ "$format" == "json" ]]; then
    echo '{"open_count":0,"items":[]}'
  else
    echo "No open loops. Ledger is empty."
  fi
  exit 0
fi

python3 - "$LEDGER" "$format" "$priority_filter" "$owner_filter" "$status_filter" "$max_items" "$counts_only" <<'PY'
import json
import sys
from collections import Counter

ledger_path, fmt, priority_filter, owner_filter, status_filter, max_items_str, counts_only_str = sys.argv[1:8]
max_items = int(max_items_str)
counts_only = counts_only_str == "1"

closed_statuses = {"done_unverified", "verified_done", "archived", "deferred", "dropped"}

entries = []
with open(ledger_path, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("status") in closed_statuses:
            continue
        if priority_filter and entry.get("priority") != priority_filter:
            continue
        if owner_filter and entry.get("owner") != owner_filter:
            continue
        if status_filter and entry.get("status") != status_filter:
            continue
        entries.append(entry)

priority_order = {"p0": 0, "p1": 1, "p2": 2, "p3": 3}
entries.sort(key=lambda e: (priority_order.get(e.get("priority", "p3"), 9), e.get("updated_at", "")))

by_priority = Counter(e["priority"] for e in entries)
by_status = Counter(e["status"] for e in entries)

if counts_only:
    if fmt == "json":
        print(json.dumps({
            "open_count": len(entries),
            "by_priority": dict(by_priority),
            "by_status": dict(by_status),
        }))
    else:
        print(f"Open loops: {len(entries)}")
        if by_priority:
            print(f"  By priority: {', '.join(f'{k}={v}' for k, v in sorted(by_priority.items()))}")
        if by_status:
            print(f"  By status:   {', '.join(f'{k}={v}' for k, v in sorted(by_status.items()))}")
    sys.exit(0)

display = entries[:max_items]

if fmt == "json":
    result = {
        "open_count": len(entries),
        "by_priority": dict(by_priority),
        "by_status": dict(by_status),
        "items": [{
            "id": e["id"],
            "type": e["type"],
            "status": e["status"],
            "priority": e["priority"],
            "owner": e["owner"],
            "summary": e["summary"],
            "due_date": e.get("due_date"),
            "updated_at": e.get("updated_at"),
            "age_transitions": len(e.get("history", []) or []),
        } for e in display],
    }
    if len(entries) > max_items:
        result["truncated"] = len(entries) - max_items
    print(json.dumps(result, ensure_ascii=False))
else:
    print(f"Open loops: {len(entries)}")
    if by_priority:
        parts = []
        for p in ("p0", "p1", "p2", "p3"):
            if by_priority.get(p):
                parts.append(f"{p}={by_priority[p]}")
        print(f"  Priority: {', '.join(parts)}")
    if by_status:
        print(f"  Status:   {', '.join(f'{k}={v}' for k, v in sorted(by_status.items()))}")
    print()

    for e in display:
        due = f" due={e['due_date']}" if e.get("due_date") else ""
        status_marker = ""
        if e["status"] == "blocked":
            status_marker = " [BLOCKED]"
        elif e["status"] == "awaiting_user":
            status_marker = " [AWAITING USER]"
        print(f"  {e['priority']} {e['id']} {e['type']}/{e['status']}{status_marker} owner={e['owner']}{due}")
        print(f"     {e['summary']}")

    if len(entries) > max_items:
        print(f"\n  ... and {len(entries) - max_items} more")
PY
