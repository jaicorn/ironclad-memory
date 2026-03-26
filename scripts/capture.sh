#!/usr/bin/env bash
set -euo pipefail

# capture.sh — Deterministic helper to infer and upsert ledger entries
# from structured events. Rule-based, no AI magic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Workspace detection
detect_workspace() {
  if [[ -n "${IRONCLAD_WORKSPACE:-}" ]]; then
    echo "$IRONCLAD_WORKSPACE"
    return
  fi
  local dir
  dir="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [[ -d "$dir/.ironclad" ]]; then
    echo "$dir"
    return
  fi
  local check="$dir"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then
      echo "$check"
      return
    fi
    check="$(dirname "$check")"
  done
  check="$(pwd)"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then
      echo "$check"
      return
    fi
    check="$(dirname "$check")"
  done
  echo "$dir"
}

WORKSPACE="$(detect_workspace)"
LEDGER_SCRIPT="$SCRIPT_DIR/ledger.sh"
LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"

mkdir -p "$(dirname "$LEDGER")"

# Capture-level lock using mkdir (atomic on all POSIX)
CAPTURE_LOCKDIR="${LEDGER}.capture.lk"

acquire_capture_lock() {
  local tries=0
  while ! mkdir "$CAPTURE_LOCKDIR" 2>/dev/null; do
    if [[ -d "$CAPTURE_LOCKDIR" ]]; then
      local lock_age
      lock_age="$(python3 -c "import os,time; print(int(time.time()-os.path.getmtime('$CAPTURE_LOCKDIR')))" 2>/dev/null || echo 0)"
      if [[ "$lock_age" -gt 60 ]]; then
        rmdir "$CAPTURE_LOCKDIR" 2>/dev/null || true
        continue
      fi
    fi
    ((tries++)) || true
    if [[ $tries -ge 20 ]]; then
      echo "Error: capture lock timeout after 10s" >&2
      return 1
    fi
    sleep 0.5
  done
}

release_capture_lock() {
  rmdir "$CAPTURE_LOCKDIR" 2>/dev/null || true
}

trap 'release_capture_lock 2>/dev/null || true' EXIT

usage() {
  cat <<'EOF'
Usage:
  capture.sh <command> [options]

Deterministic event-to-ledger capture with dedup and reopening.

Commands:
  from-flush    Capture ledger entries from memory flush inputs
  from-event    Capture/update from a single structured event
  match         Check if a summary already exists in the ledger

from-flush options:
  --commitment TEXT    Creates type=commitment (repeatable)
  --blocker TEXT       Creates type=blocker (repeatable)
  --owner OWNER       Owner for new entries (default: agent)
  --source SOURCE     Source tag (default: memory)
  --dry-run           Print what would be created without writing

from-event options:
  --event-type TYPE   One of: user_ask, blocker_raised, awaiting_user, task_done
  --summary TEXT      One-line description (required)
  --owner OWNER       Owner (default: agent)
  --source SOURCE     Source tag (default: conversation)
  --priority PRIORITY Override priority (otherwise inferred)
  --tag TAG           Freeform tag (repeatable)
  --dry-run           Print what would be created without writing

match options:
  --summary TEXT      Summary to search for (required)
  --status STATUS     Only match entries with this status (optional)

  -h, --help          Show this help
EOF
}

find_matching_entry() {
  local search_summary="$1"
  local status_filter="${2:-}"

  [[ -s "$LEDGER" ]] || { echo ""; return 0; }

  python3 - "$LEDGER" "$search_summary" "$status_filter" <<'PY'
import json, sys

ledger_path, search_summary, status_filter = sys.argv[1:4]
search_lower = search_summary.lower().strip()

if len(search_lower) < 8:
    sys.exit(0)

with open(ledger_path, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if status_filter and entry.get('status') != status_filter:
            continue
        if entry.get('status') in ('verified_done', 'archived'):
            continue
        existing = entry.get('summary', '').lower().strip()
        if search_lower in existing or existing in search_lower:
            print(entry['id'])
            sys.exit(0)
PY
}

infer_priority() {
  local event_type="$1"
  case "$event_type" in
    blocker_raised) echo "p1" ;;
    user_ask)       echo "p1" ;;
    awaiting_user)  echo "p1" ;;
    task_done)      echo "p2" ;;
    *)              echo "p2" ;;
  esac
}

infer_entry_type() {
  local event_type="$1"
  case "$event_type" in
    blocker_raised)  echo "blocker" ;;
    user_ask)        echo "commitment" ;;
    awaiting_user)   echo "action" ;;
    task_done)       echo "action" ;;
    *)               echo "action" ;;
  esac
}

infer_status_transition() {
  local event_type="$1"
  case "$event_type" in
    blocker_raised)  echo "blocked" ;;
    awaiting_user)   echo "awaiting_user" ;;
    task_done)       echo "done_unverified" ;;
    user_ask)        echo "captured" ;;
    *)               echo "" ;;
  esac
}

get_entry_status() {
  local target_id="$1"
  [[ -s "$LEDGER" ]] || return 0

  python3 - "$LEDGER" "$target_id" <<'PY'
import json, sys
ledger_path, target_id = sys.argv[1:3]
with open(ledger_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get('id') == target_id:
            print(entry.get('status', ''))
            sys.exit(0)
PY
}

cmd_from_flush() {
  local owner="agent" source="memory" dry_run=0
  local -a commitments=() blockers=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --commitment) commitments+=("$2"); shift 2 ;;
      --blocker)    blockers+=("$2"); shift 2 ;;
      --owner)      owner="$2"; shift 2 ;;
      --source)     source="$2"; shift 2 ;;
      --dry-run)    dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown from-flush option: $1" >&2; exit 1 ;;
    esac
  done

  local created=0 skipped=0

  for summary in "${commitments[@]+"${commitments[@]}"}"; do
    local existing existing_status
    existing="$(find_matching_entry "$summary")"
    if [[ -n "$existing" ]]; then
      existing_status="$(get_entry_status "$existing")"
      if [[ "$existing_status" == "deferred" || "$existing_status" == "dropped" || "$existing_status" == "done_unverified" ]]; then
        if [[ $dry_run -eq 1 ]]; then
          echo "Would reopen $existing -> captured: $summary"
        else
          "$LEDGER_SCRIPT" update \
            --id "$existing" \
            --status captured \
            --note "Reopened via memory flush"
          echo "Reopened $existing -> captured"
        fi
      else
        echo "Skip (exists: $existing): $summary"
      fi
      ((skipped++)) || true
      continue
    fi
    if [[ $dry_run -eq 1 ]]; then
      echo "Would create: commitment p1 owner=$owner \"$summary\""
    else
      "$LEDGER_SCRIPT" add \
        --type commitment \
        --priority p1 \
        --summary "$summary" \
        --owner "$owner" \
        --source "$source"
      ((created++)) || true
    fi
  done

  for summary in "${blockers[@]+"${blockers[@]}"}"; do
    local existing
    existing="$(find_matching_entry "$summary")"
    if [[ -n "$existing" ]]; then
      if [[ $dry_run -eq 1 ]]; then
        echo "Would update $existing -> blocked: $summary"
      else
        "$LEDGER_SCRIPT" update \
          --id "$existing" \
          --status blocked \
          --note "Blocker re-raised via memory flush"
        echo "Updated $existing -> blocked"
      fi
      ((skipped++)) || true
      continue
    fi
    if [[ $dry_run -eq 1 ]]; then
      echo "Would create: blocker p1 owner=$owner \"$summary\""
    else
      "$LEDGER_SCRIPT" add \
        --type blocker \
        --priority p1 \
        --summary "$summary" \
        --owner "$owner" \
        --source "$source"
      ((created++)) || true
    fi
  done

  echo "Capture complete: $created created, $skipped skipped/updated"
}

cmd_from_event() {
  local event_type="" summary="" owner="agent" source="conversation" priority="" dry_run=0
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --event-type) event_type="$2"; shift 2 ;;
      --summary)    summary="$2"; shift 2 ;;
      --owner)      owner="$2"; shift 2 ;;
      --source)     source="$2"; shift 2 ;;
      --priority)   priority="$2"; shift 2 ;;
      --tag)        tags+=("$2"); shift 2 ;;
      --dry-run)    dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown from-event option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$event_type" ]] || { echo "Error: --event-type is required" >&2; exit 1; }
  [[ -n "$summary" ]] || { echo "Error: --summary is required" >&2; exit 1; }

  case "$event_type" in
    user_ask|blocker_raised|awaiting_user|task_done) ;;
    *) echo "Error: --event-type must be one of: user_ask, blocker_raised, awaiting_user, task_done" >&2; exit 1 ;;
  esac

  [[ -n "$priority" ]] || priority="$(infer_priority "$event_type")"

  local existing
  existing="$(find_matching_entry "$summary")"

  if [[ -n "$existing" ]]; then
    local new_status existing_status
    new_status="$(infer_status_transition "$event_type")"
    existing_status="$(get_entry_status "$existing")"

    if [[ "$existing_status" == "deferred" || "$existing_status" == "dropped" ]]; then
      local reactivate_status="${new_status:-captured}"
      if [[ "$event_type" == "task_done" ]]; then
        if [[ $dry_run -eq 1 ]]; then
          echo "Would close $existing (was $existing_status): $summary"
        else
          "$LEDGER_SCRIPT" close \
            --id "$existing" \
            --note "Completed (was $existing_status): $summary"
        fi
      else
        if [[ $dry_run -eq 1 ]]; then
          echo "Would reactivate $existing ($existing_status -> $reactivate_status): $summary"
        else
          "$LEDGER_SCRIPT" update \
            --id "$existing" \
            --status "$reactivate_status" \
            --note "Reactivated from $existing_status via $event_type"
          echo "Reactivated: $existing ($existing_status -> $reactivate_status)"
        fi
      fi
    elif [[ "$event_type" == "task_done" ]]; then
      if [[ $dry_run -eq 1 ]]; then
        echo "Would close $existing: $summary"
      else
        "$LEDGER_SCRIPT" close \
          --id "$existing" \
          --note "Completed: $summary"
      fi
    elif [[ -n "$new_status" ]]; then
      if [[ $dry_run -eq 1 ]]; then
        echo "Would update $existing -> $new_status: $summary"
      else
        "$LEDGER_SCRIPT" update \
          --id "$existing" \
          --status "$new_status" \
          --note "Event: $event_type"
      fi
    else
      echo "Exists ($existing), no status change for event $event_type"
    fi
  else
    local entry_type
    entry_type="$(infer_entry_type "$event_type")"

    local tag_args=()
    for t in "${tags[@]+"${tags[@]}"}"; do
      tag_args+=(--tag "$t")
    done

    if [[ $dry_run -eq 1 ]]; then
      echo "Would create: $entry_type $priority owner=$owner \"$summary\""
    else
      "$LEDGER_SCRIPT" add \
        --type "$entry_type" \
        --priority "$priority" \
        --summary "$summary" \
        --owner "$owner" \
        --source "$source" \
        "${tag_args[@]+"${tag_args[@]}"}"
    fi
  fi
}

cmd_match() {
  local summary="" status_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --summary) summary="$2"; shift 2 ;;
      --status)  status_filter="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown match option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$summary" ]] || { echo "Error: --summary is required" >&2; exit 1; }

  local match
  match="$(find_matching_entry "$summary" "$status_filter")"
  if [[ -n "$match" ]]; then
    echo "match:$match"
  else
    echo "no_match"
  fi
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

command="$1"
shift

case "$command" in
  from-flush)
    acquire_capture_lock
    cmd_from_flush "$@"
    release_capture_lock
    ;;
  from-event)
    acquire_capture_lock
    cmd_from_event "$@"
    release_capture_lock
    ;;
  match)      cmd_match "$@" ;;
  -h|--help)  usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 1 ;;
esac
