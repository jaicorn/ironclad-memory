#!/usr/bin/env bash
set -euo pipefail

# ironclad.sh — Main CLI entry point for Ironclad Memory.
# Unified interface for memory flush, retrieval, commitment tracking,
# escalation, and system validation.

IRONCLAD_VERSION="1.0.0"
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

usage() {
  cat <<EOF
Ironclad Memory v${IRONCLAD_VERSION}
Memory integrity system for AI agents.

Usage:
  ironclad <command> [options]

Memory commands:
  init                Create workspace dirs and print setup instructions
  flush               Append structured memory to daily file
  retrieve            Search memory and build evidence ledger

Commitment lifecycle:
  ask "<summary>"     Track a new request/commitment
  block "<summary>"   Mark something as blocked
  waiting "<summary>" Mark as waiting on user input
  start "<summary>"   Begin work on a tracked item
  done "<summary>"    Complete a tracked item
  defer "<summary>"   Intentionally pause until later
  drop "<summary>"    Kill a no-longer-relevant item

Review & monitoring:
  review              Daily review: stale items, blockers first
  status              Quick open-loop counts
  escalate            Run decay watchdog (stale item tiers)

Memory tiers:
  tier classify        Scan memory files, classify HOT/WARM/COLD
  tier show            Print current tier classifications
  tier get <file>      Get tier for a specific file
  tier read <file>     Read file with tier-appropriate depth

System:
  doctor              Validate installation
  version             Print version
  help                Show this help

Run 'ironclad <command> --help' for command-specific help.
EOF
}

cmd_init() {
  local workspace
  workspace="$(detect_workspace)"

  echo "Ironclad Memory — Init"
  echo "Workspace: $workspace"
  echo ""

  # Create directories
  local dirs=(
    "$workspace/.ironclad"
    "$workspace/memory"
    "$workspace/data/commitments"
    "$workspace/data/escalations"
  )
  for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      mkdir -p "$d"
      echo "  Created: $d"
    else
      echo "  Exists:  $d"
    fi
  done

  # Touch ledger
  local ledger="${IRONCLAD_LEDGER_PATH:-$workspace/data/commitments/ledger.jsonl}"
  if [[ ! -f "$ledger" ]]; then
    touch "$ledger"
    echo "  Created: $ledger"
  else
    echo "  Exists:  $ledger"
  fi

  echo ""
  echo "Setup complete. Next steps:"
  echo "  1. Add to your agent's system prompt / AGENTS.md:"
  echo "     - Run 'ironclad flush' before context compaction"
  echo "     - Run 'ironclad retrieve' before status-critical answers"
  echo "     - Use 'ironclad ask/done/block' for commitment tracking"
  echo "  2. Run 'ironclad doctor' to validate the installation"
  echo "  3. See references/integration-guide.md for full setup"
}

cmd_flush() {
  "$SCRIPT_DIR/flush.sh" "$@"
}

cmd_retrieve() {
  "$SCRIPT_DIR/retrieve.sh" "$@"
}

# Commitment lifecycle commands that go through capture
cmd_ask() {
  local summary="$1"; shift
  local owner="agent" source="conversation" priority="" quiet=0
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)    owner="$2"; shift 2 ;;
      --source)   source="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --tag)      tags+=("$2"); shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local tag_args=()
  for t in "${tags[@]+"${tags[@]}"}"; do
    tag_args+=(--tag "$t")
  done
  local pri_args=()
  [[ -n "$priority" ]] && pri_args=(--priority "$priority")

  local output
  output="$("$SCRIPT_DIR/capture.sh" from-event \
    --event-type user_ask \
    --summary "$summary" \
    --owner "$owner" \
    --source "$source" \
    "${pri_args[@]+"${pri_args[@]}"}" \
    "${tag_args[@]+"${tag_args[@]}"}" 2>&1)"
  echo "ask: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_block() {
  local summary="$1"; shift
  local owner="agent" source="conversation" priority="" quiet=0
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)    owner="$2"; shift 2 ;;
      --source)   source="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --tag)      tags+=("$2"); shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local tag_args=()
  for t in "${tags[@]+"${tags[@]}"}"; do
    tag_args+=(--tag "$t")
  done
  local pri_args=()
  [[ -n "$priority" ]] && pri_args=(--priority "$priority")

  local output
  output="$("$SCRIPT_DIR/capture.sh" from-event \
    --event-type blocker_raised \
    --summary "$summary" \
    --owner "$owner" \
    --source "$source" \
    "${pri_args[@]+"${pri_args[@]}"}" \
    "${tag_args[@]+"${tag_args[@]}"}" 2>&1)"

  # If newly created, transition to blocked
  local new_id
  new_id="$(echo "$output" | grep -o 'c-[0-9]*-[0-9a-f]*' || true)"
  if echo "$output" | grep -qF "Created:" 2>/dev/null; then
    "$SCRIPT_DIR/ledger.sh" update --id "$new_id" --status blocked --note "Created as blocker" >/dev/null 2>&1
  fi

  echo "block: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_waiting() {
  local summary="$1"; shift
  local owner="agent" source="conversation" priority="" quiet=0
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)    owner="$2"; shift 2 ;;
      --source)   source="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --tag)      tags+=("$2"); shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local tag_args=()
  for t in "${tags[@]+"${tags[@]}"}"; do
    tag_args+=(--tag "$t")
  done
  local pri_args=()
  [[ -n "$priority" ]] && pri_args=(--priority "$priority")

  local output
  output="$("$SCRIPT_DIR/capture.sh" from-event \
    --event-type awaiting_user \
    --summary "$summary" \
    --owner "$owner" \
    --source "$source" \
    "${pri_args[@]+"${pri_args[@]}"}" \
    "${tag_args[@]+"${tag_args[@]}"}" 2>&1)"

  local new_id
  new_id="$(echo "$output" | grep -o 'c-[0-9]*-[0-9a-f]*' || true)"
  if echo "$output" | grep -qF "Created:" 2>/dev/null; then
    "$SCRIPT_DIR/ledger.sh" update --id "$new_id" --status awaiting_user --note "Created as awaiting user" >/dev/null 2>&1
  fi

  echo "waiting: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_start() {
  local summary="$1"; shift
  local owner="agent" source="conversation" priority="p2" note="" quiet=0
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)    owner="$2"; shift 2 ;;
      --source)   source="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --tag)      tags+=("$2"); shift 2 ;;
      --note)     note="$2"; shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local entry_id
  entry_id="$(find_entry_id "$summary")"

  if [[ -n "$entry_id" ]]; then
    local output
    output="$("$SCRIPT_DIR/ledger.sh" update \
      --id "$entry_id" \
      --status in_flight \
      --note "${note:-Started work}" 2>&1)"
    echo "start: $output"
  else
    local tag_args=()
    for t in "${tags[@]+"${tags[@]}"}"; do
      tag_args+=(--tag "$t")
    done

    local add_output
    add_output="$("$SCRIPT_DIR/ledger.sh" add \
      --type action \
      --priority "$priority" \
      --summary "$summary" \
      --owner "$owner" \
      --source "$source" \
      "${tag_args[@]+"${tag_args[@]}"}" 2>&1)"
    local new_id
    new_id="$(echo "$add_output" | grep -o 'c-[0-9]*-[0-9a-f]*' || true)"
    if [[ -n "$new_id" ]]; then
      "$SCRIPT_DIR/ledger.sh" update \
        --id "$new_id" \
        --status in_flight \
        --note "${note:-Started work}" >/dev/null 2>&1
      echo "start: Created and started: $new_id"
    else
      echo "start: $add_output"
      return 1
    fi
  fi
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_defer() {
  local summary="$1"; shift
  local note="" until="" quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)     note="$2"; shift 2 ;;
      --until)    until="$2"; shift 2 ;;
      --owner|--source|--priority|--tag) shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local entry_id
  entry_id="$(find_entry_id "$summary")"

  if [[ -z "$entry_id" ]]; then
    echo "defer: Error: no matching open entry found for: $summary" >&2
    return 1
  fi

  if [[ -n "$until" ]]; then
    "$SCRIPT_DIR/ledger.sh" update --id "$entry_id" --due-date "$until" --note "${note:-Deferred until $until}" >/dev/null 2>&1
  fi

  local output
  output="$("$SCRIPT_DIR/ledger.sh" update \
    --id "$entry_id" \
    --status deferred \
    --note "${note:-Deferred${until:+ until $until}}" 2>&1)"

  echo "defer: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_drop() {
  local summary="$1"; shift
  local note="" quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)     note="$2"; shift 2 ;;
      --owner|--source|--priority|--tag|--until) shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local entry_id
  entry_id="$(find_entry_id "$summary")"

  if [[ -z "$entry_id" ]]; then
    echo "drop: Error: no matching open entry found for: $summary" >&2
    return 1
  fi

  local output
  output="$("$SCRIPT_DIR/ledger.sh" update \
    --id "$entry_id" \
    --status dropped \
    --note "${note:-Dropped: $summary}" 2>&1)"

  echo "drop: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_done() {
  local summary="$1"; shift
  local note="" quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)     note="$2"; shift 2 ;;
      --owner|--source|--priority|--tag) shift 2 ;;
      --quiet)    quiet=1; shift ;;
      *) shift ;;
    esac
  done

  local entry_id
  entry_id="$(find_entry_id "$summary")"

  if [[ -z "$entry_id" ]]; then
    echo "done: Error: no matching open entry found for: $summary" >&2
    return 1
  fi

  local output
  output="$("$SCRIPT_DIR/ledger.sh" close \
    --id "$entry_id" \
    --note "${note:-Completed: $summary}" 2>&1)"

  echo "done: $output"
  [[ $quiet -eq 0 ]] && print_snapshot
  return 0
}

cmd_review() {
  local workspace
  workspace="$(detect_workspace)"
  local ledger="${IRONCLAD_LEDGER_PATH:-$workspace/data/commitments/ledger.jsonl}"

  echo "=== Daily Review: $(date +%Y-%m-%d) ==="
  echo ""

  if [[ ! -s "$ledger" ]]; then
    echo "Ledger is empty. Nothing to review."
    return 0
  fi

  python3 - "$ledger" <<'PY'
import json, sys
from datetime import datetime, timezone
from collections import Counter

ledger_path = sys.argv[1]
now = datetime.now(timezone.utc)

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
        entries.append(entry)

if not entries:
    print("All loops closed. Nothing open.")
    sys.exit(0)

priority_order = {"p0": 0, "p1": 1, "p2": 2, "p3": 3}

for e in entries:
    updated = e.get("updated_at", e.get("created_at", ""))
    try:
        dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
        e["_age_days"] = (now - dt).days
    except (ValueError, AttributeError):
        e["_age_days"] = 0

status_urgency = {"blocked": 0, "awaiting_user": 1, "in_flight": 2, "captured": 3}
entries.sort(key=lambda e: (
    status_urgency.get(e["status"], 9),
    priority_order.get(e.get("priority", "p3"), 9),
    -e["_age_days"],
))

by_priority = Counter(e["priority"] for e in entries)
by_status = Counter(e["status"] for e in entries)

print(f"Open loops: {len(entries)}")
parts = [f"{p}={by_priority[p]}" for p in ("p0", "p1", "p2", "p3") if by_priority.get(p)]
print(f"  Priority: {', '.join(parts)}")
print(f"  Status:   {', '.join(f'{k}={v}' for k, v in sorted(by_status.items()))}")
print()

stale = [e for e in entries if e["_age_days"] >= 3]
if stale:
    print(f"STALE ({len(stale)} items not updated in 3+ days):")
    for e in stale:
        print(f"  {e['priority']} {e['id']} {e['status']} ({e['_age_days']}d) — {e['summary']}")
    print()

for label, status_key in [("BLOCKED", "blocked"), ("AWAITING USER", "awaiting_user")]:
    group = [e for e in entries if e["status"] == status_key]
    if group:
        print(f"{label} ({len(group)}):")
        for e in group:
            due = f" due={e['due_date']}" if e.get("due_date") else ""
            print(f"  {e['priority']} {e['id']}{due} — {e['summary']}")
        print()

in_flight = [e for e in entries if e["status"] == "in_flight"]
if in_flight:
    print(f"IN FLIGHT ({len(in_flight)}):")
    for e in in_flight:
        age = f" ({e['_age_days']}d)" if e["_age_days"] > 0 else ""
        due = f" due={e['due_date']}" if e.get("due_date") else ""
        print(f"  {e['priority']} {e['id']}{due}{age} — {e['summary']}")
    print()

captured = [e for e in entries if e["status"] == "captured"]
if captured:
    print(f"NOT STARTED ({len(captured)}):")
    for e in captured:
        age = f" ({e['_age_days']}d)" if e["_age_days"] > 0 else ""
        due = f" due={e['due_date']}" if e.get("due_date") else ""
        print(f"  {e['priority']} {e['id']}{due}{age} — {e['summary']}")
PY
}

cmd_status() {
  "$SCRIPT_DIR/loops.sh" --counts-only 2>/dev/null
}

cmd_escalate() {
  "$SCRIPT_DIR/escalate.sh" "$@"
}

cmd_doctor() {
  "$SCRIPT_DIR/doctor.sh" "$@"
}

cmd_tier() {
  "$SCRIPT_DIR/tier.sh" "$@"
}

# Helper functions
find_entry_id() {
  local summary="$1"
  local match_output
  match_output="$("$SCRIPT_DIR/capture.sh" match --summary "$summary" 2>/dev/null || true)"
  if [[ "$match_output" == match:* ]]; then
    echo "${match_output#match:}"
  fi
}

print_snapshot() {
  echo ""
  echo "--- open loops ---"
  "$SCRIPT_DIR/loops.sh" --max 8 2>/dev/null || true
}

# --- Main ---

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

verb="$1"
shift

case "$verb" in
  init)
    cmd_init ;;
  flush)
    cmd_flush "$@" ;;
  retrieve)
    cmd_retrieve "$@" ;;
  ask|block|waiting|start|defer|drop|cancel|done)
    if [[ $# -eq 0 ]]; then
      echo "Error: $verb requires a summary argument" >&2
      echo "Usage: ironclad $verb \"<summary>\" [options]" >&2
      exit 1
    fi
    summary="$1"
    shift
    [[ "$verb" == "cancel" ]] && verb="drop"
    "cmd_$verb" "$summary" "$@"
    ;;
  review)
    cmd_review ;;
  status)
    cmd_status ;;
  escalate)
    cmd_escalate "$@" ;;
  tier)
    cmd_tier "$@" ;;
  doctor)
    cmd_doctor "$@" ;;
  version)
    echo "Ironclad Memory v${IRONCLAD_VERSION}" ;;
  help|-h|--help)
    usage ;;
  *)
    echo "Unknown command: $verb" >&2
    echo "Run 'ironclad help' for available commands." >&2
    exit 1
    ;;
esac
