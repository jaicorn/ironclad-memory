#!/usr/bin/env bash
set -euo pipefail

# ledger.sh — Commitment ledger with full lifecycle tracking.
# JSONL backend with atomic writes, file locking, and history.
#
# Status flow:
#   captured → in_flight → done_unverified → verified_done
#   (or blocked, awaiting_user, deferred, dropped at any point)

IRONCLAD_VERSION="1.0.0"

# Workspace detection
detect_workspace() {
  if [[ -n "${IRONCLAD_WORKSPACE:-}" ]]; then
    echo "$IRONCLAD_WORKSPACE"
    return
  fi
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -d "$dir/.ironclad" ]]; then
    echo "$dir"
    return
  fi
  # Walk up from script location
  local check="$dir"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then
      echo "$check"
      return
    fi
    check="$(dirname "$check")"
  done
  # Walk up from cwd
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
LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"

mkdir -p "$(dirname "$LEDGER")"
touch "$LEDGER"

VALID_TYPES="commitment question blocker action"
VALID_STATUSES="captured in_flight blocked awaiting_user deferred dropped done_unverified verified_done archived"
VALID_PRIORITIES="p0 p1 p2 p3"

usage() {
  cat <<'EOF'
Usage:
  ledger.sh <command> [options]

Commitment ledger with full lifecycle tracking.

Commands:
  add       Create a new ledger entry
  update    Update status/priority of an existing entry
  close     Close an entry; proof => verified_done, otherwise done_unverified
  verify    Add verification proof to an existing entry
  list      List entries (default: open items only)
  search    Search entries by text
  history   Show full history of a specific entry
  gc        Archive old closed entries

Add options:
  --type TYPE           commitment|question|blocker|action (required)
  --priority PRIORITY   p0|p1|p2|p3 (required)
  --summary TEXT        One-line description (required)
  --owner OWNER         agent|user|<custom> (required)
  --source SOURCE       conversation|voice_note|memory|proactive|flush
  --due-date DATE       YYYY-MM-DD
  --tag TAG             Freeform tag (repeatable)

Update options:
  --id ID               Entry ID (required)
  --status STATUS       New status
  --priority PRIORITY   New priority
  --due-date DATE       Set or clear due date (YYYY-MM-DD or none)
  --note TEXT           Transition note

Close options:
  --id ID               Entry ID (required)
  --artifact-path PATH  Path to result artifact
  --message-id ID       Message ID for verification
  --note TEXT           What was verified and how (required)

Verify options:
  --id ID               Entry ID (required)
  --artifact-path PATH  Path to result artifact
  --message-id ID       Message ID for verification
  --note TEXT           Verification details (required)

List options:
  --status STATUS       Filter by status
  --priority PRIORITY   Filter by priority
  --owner OWNER         Filter by owner
  --tag TAG             Filter by tag
  --all                 Include closed/archived entries
  --json                Output raw JSON lines

Search options:
  --query TEXT          Search text (required)
  --json                Output raw JSON lines

History options:
  --id ID               Entry ID (required)
  --json                Output raw JSON

GC options:
  --days N              Archive entries closed more than N days ago (default: 30)
  --dry-run             Show what would be archived without writing

  -h, --help            Show this help
EOF
}

now_iso() {
  python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

generate_id() {
  python3 -c "
import secrets
from datetime import datetime, timezone
prefix = datetime.now(timezone.utc).strftime('c-%Y%m%d%H%M%S')
print(f'{prefix}-{secrets.token_hex(8)}')
"
}

validate_enum() {
  local value="$1" name="$2" valid="$3"
  for v in $valid; do
    [[ "$v" == "$value" ]] && return 0
  done
  echo "Error: --$name must be one of: $valid" >&2
  exit 1
}

cmd_add() {
  local entry_type="" priority="" summary="" owner="" source="" due_date=""
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) entry_type="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --due-date) due_date="$2"; shift 2 ;;
      --tag) tags+=("$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown add option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$entry_type" ]] || { echo "Error: --type is required" >&2; exit 1; }
  [[ -n "$priority" ]] || { echo "Error: --priority is required" >&2; exit 1; }
  [[ -n "$summary" ]] || { echo "Error: --summary is required" >&2; exit 1; }
  [[ -n "$owner" ]] || { echo "Error: --owner is required" >&2; exit 1; }

  validate_enum "$entry_type" "type" "$VALID_TYPES"
  validate_enum "$priority" "priority" "$VALID_PRIORITIES"

  local id ts tags_json
  id="$(generate_id)"
  ts="$(now_iso)"
  tags_json="[]"
  if [[ ${#tags[@]} -gt 0 ]]; then
    tags_json="$(printf '%s\n' "${tags[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")"
  fi

  python3 - "$LEDGER" "$id" "$entry_type" "$priority" "$summary" "$owner" "$source" "$due_date" "$tags_json" "$ts" <<'PY'
import json, os, sys, fcntl

ledger_path, entry_id, entry_type, priority, summary, owner, source, due_date, tags_json, ts = sys.argv[1:11]
entry = {
    'id': entry_id,
    'type': entry_type,
    'status': 'captured',
    'priority': priority,
    'summary': summary,
    'owner': owner,
    'created_at': ts,
    'updated_at': ts,
    'source': source or None,
    'due_date': due_date or None,
    'tags': json.loads(tags_json),
    'history': [{'ts': ts, 'from_status': None, 'to_status': 'captured', 'note': 'Created'}],
    'closure': None,
}
with open(ledger_path, 'a+', encoding='utf-8') as f:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    f.seek(0)
    for existing_line in f:
        existing_line = existing_line.strip()
        if not existing_line:
            continue
        try:
            if json.loads(existing_line).get('id') == entry_id:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                print(f"Error: ID collision for {entry_id}, retry", file=sys.stderr)
                sys.exit(1)
        except json.JSONDecodeError:
            continue
    f.seek(0, 2)
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    f.flush()
    os.fsync(f.fileno())
    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
print(f"Created: {entry_id}")
PY
}

cmd_update() {
  local target_id="" new_status="" new_priority="" new_due_date="" note=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) target_id="$2"; shift 2 ;;
      --status) new_status="$2"; shift 2 ;;
      --priority) new_priority="$2"; shift 2 ;;
      --due-date) new_due_date="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown update option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$target_id" ]] || { echo "Error: --id is required" >&2; exit 1; }
  [[ -n "$new_status" || -n "$new_priority" || -n "$new_due_date" ]] || { echo "Error: --status, --priority, or --due-date required" >&2; exit 1; }

  [[ -z "$new_status" ]] || validate_enum "$new_status" "status" "$VALID_STATUSES"
  [[ -z "$new_priority" ]] || validate_enum "$new_priority" "priority" "$VALID_PRIORITIES"

  local ts
  ts="$(now_iso)"

  python3 - "$LEDGER" "$target_id" "$new_status" "$new_priority" "$new_due_date" "$note" "$ts" <<'PY'
import json, os, sys, tempfile, fcntl

ledger_path, target_id, new_status, new_priority, new_due_date, note, ts = sys.argv[1:8]

with open(ledger_path, 'a+', encoding='utf-8') as lockf:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
    lockf.seek(0)
    lines = []
    found = False
    for line in lockf:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if entry['id'] == target_id:
            found = True
            old_status = entry['status']
            if new_status:
                entry['status'] = new_status
                entry.setdefault('history', [])
                entry['history'].append({
                    'ts': ts,
                    'from_status': old_status,
                    'to_status': new_status,
                    'note': note or f'Status changed to {new_status}',
                })
            if new_priority:
                entry['priority'] = new_priority
            if new_due_date:
                entry['due_date'] = None if new_due_date == 'none' else new_due_date
            entry['updated_at'] = ts
        lines.append(json.dumps(entry, ensure_ascii=False))

    if not found:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        print(f"Error: entry {target_id} not found", file=sys.stderr)
        sys.exit(1)

    dirpath = os.path.dirname(os.path.abspath(ledger_path)) or '.'
    fd, tmp_path = tempfile.mkstemp(prefix='.ledger.', suffix='.jsonl.tmp', dir=dirpath)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as tmp:
            for line in lines:
                tmp.write(line + '\n')
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, ledger_path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)

print(f"Updated: {target_id}")
PY
}

cmd_close() {
  local target_id="" artifact_path="" message_id="" note=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) target_id="$2"; shift 2 ;;
      --artifact-path) artifact_path="$2"; shift 2 ;;
      --message-id) message_id="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown close option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$target_id" ]] || { echo "Error: --id is required" >&2; exit 1; }
  [[ -n "$note" ]] || { echo "Error: --note is required for closure" >&2; exit 1; }

  local ts close_status
  ts="$(now_iso)"
  if [[ -n "$artifact_path" || -n "$message_id" ]]; then
    close_status="verified_done"
  else
    close_status="done_unverified"
  fi

  python3 - "$LEDGER" "$target_id" "$artifact_path" "$message_id" "$note" "$ts" "$close_status" <<'PY'
import json, os, sys, tempfile, fcntl

ledger_path, target_id, artifact_path, message_id, note, ts, close_status = sys.argv[1:8]

with open(ledger_path, 'a+', encoding='utf-8') as lockf:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
    lockf.seek(0)
    lines = []
    found = False
    for line in lockf:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if entry['id'] == target_id:
            found = True
            old_status = entry['status']
            entry['status'] = close_status
            entry['updated_at'] = ts
            entry['closure'] = {
                'artifact_path': artifact_path or None,
                'message_id': message_id or None,
                'verification_ts': ts if close_status == 'verified_done' else None,
                'note': note,
            }
            entry.setdefault('history', [])
            entry['history'].append({
                'ts': ts,
                'from_status': old_status,
                'to_status': close_status,
                'note': note,
            })
        lines.append(json.dumps(entry, ensure_ascii=False))

    if not found:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        print(f"Error: entry {target_id} not found", file=sys.stderr)
        sys.exit(1)

    dirpath = os.path.dirname(os.path.abspath(ledger_path)) or '.'
    fd, tmp_path = tempfile.mkstemp(prefix='.ledger.', suffix='.jsonl.tmp', dir=dirpath)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as tmp:
            for line in lines:
                tmp.write(line + '\n')
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, ledger_path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)

print(f"Closed: {target_id} ({close_status})")
PY
}

cmd_verify() {
  local target_id="" artifact_path="" message_id="" note=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) target_id="$2"; shift 2 ;;
      --artifact-path) artifact_path="$2"; shift 2 ;;
      --message-id) message_id="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown verify option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$target_id" ]] || { echo "Error: --id is required" >&2; exit 1; }
  [[ -n "$note" ]] || { echo "Error: --note is required for verification" >&2; exit 1; }
  [[ -n "$artifact_path" || -n "$message_id" ]] || { echo "Error: --artifact-path or --message-id required as proof" >&2; exit 1; }

  local ts
  ts="$(now_iso)"

  python3 - "$LEDGER" "$target_id" "$artifact_path" "$message_id" "$note" "$ts" <<'PY'
import json, os, sys, tempfile, fcntl

ledger_path, target_id, artifact_path, message_id, note, ts = sys.argv[1:7]

with open(ledger_path, 'a+', encoding='utf-8') as lockf:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
    lockf.seek(0)
    lines = []
    found = False
    for line in lockf:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if entry['id'] == target_id:
            found = True
            old_status = entry['status']
            entry['status'] = 'verified_done'
            entry['updated_at'] = ts
            entry['closure'] = {
                'artifact_path': artifact_path or None,
                'message_id': message_id or None,
                'verification_ts': ts,
                'note': note,
            }
            entry.setdefault('history', [])
            entry['history'].append({
                'ts': ts,
                'from_status': old_status,
                'to_status': 'verified_done',
                'note': note,
            })
        lines.append(json.dumps(entry, ensure_ascii=False))

    if not found:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        print(f"Error: entry {target_id} not found", file=sys.stderr)
        sys.exit(1)

    dirpath = os.path.dirname(os.path.abspath(ledger_path)) or '.'
    fd, tmp_path = tempfile.mkstemp(prefix='.ledger.', suffix='.jsonl.tmp', dir=dirpath)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as tmp:
            for line in lines:
                tmp.write(line + '\n')
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, ledger_path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)

print(f"Verified: {target_id}")
PY
}

cmd_list() {
  local filter_status="" filter_priority="" filter_owner="" filter_tag="" show_all=0 json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) filter_status="$2"; shift 2 ;;
      --priority) filter_priority="$2"; shift 2 ;;
      --owner) filter_owner="$2"; shift 2 ;;
      --tag) filter_tag="$2"; shift 2 ;;
      --all) show_all=1; shift ;;
      --json) json_output=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown list option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ ! -s "$LEDGER" ]]; then
    if [[ $json_output -eq 1 ]]; then
      echo "[]"
    else
      echo "Ledger is empty."
    fi
    return 0
  fi

  python3 - "$LEDGER" "$filter_status" "$filter_priority" "$filter_owner" "$filter_tag" "$show_all" "$json_output" <<'PY'
import json, sys

ledger_path, filter_status, filter_priority, filter_owner, filter_tag, show_all, json_output = sys.argv[1:8]
show_all = show_all == "1"
json_output = json_output == "1"

entries = []
with open(ledger_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

filtered = []
for e in entries:
    if not show_all and e['status'] in ('done_unverified', 'verified_done', 'archived', 'deferred', 'dropped'):
        continue
    if filter_status and e['status'] != filter_status:
        continue
    if filter_priority and e['priority'] != filter_priority:
        continue
    if filter_owner and e.get('owner') != filter_owner:
        continue
    if filter_tag and filter_tag not in (e.get('tags') or []):
        continue
    filtered.append(e)

if json_output:
    for e in filtered:
        print(json.dumps(e, ensure_ascii=False))
else:
    if not filtered:
        print("No matching entries.")
    else:
        priority_order = {'p0': 0, 'p1': 1, 'p2': 2, 'p3': 3}
        filtered.sort(key=lambda e: (priority_order.get(e['priority'], 9), e.get('updated_at', '')))
        fmt = "%-26s %-12s %-16s %-4s %-12s %s"
        print(fmt % ("ID", "TYPE", "STATUS", "PRI", "OWNER", "SUMMARY"))
        print("-" * 110)
        for e in filtered:
            due = f" [due {e['due_date']}]" if e.get('due_date') else ""
            print(fmt % (
                e['id'],
                e['type'],
                e['status'],
                e['priority'],
                e['owner'],
                e['summary'][:60] + due,
            ))
PY
}

cmd_search() {
  local query="" json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --query) query="$2"; shift 2 ;;
      --json) json_output=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown search option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$query" ]] || { echo "Error: --query is required" >&2; exit 1; }

  if [[ ! -s "$LEDGER" ]]; then
    if [[ $json_output -eq 1 ]]; then
      echo "[]"
    else
      echo "No entries found."
    fi
    return 0
  fi

  python3 - "$LEDGER" "$query" "$json_output" <<'PY'
import json, sys

ledger_path, query, json_output = sys.argv[1:4]
json_output = json_output == "1"
query_lower = query.lower()

hits = []
with open(ledger_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = json.dumps(entry).lower()
        if query_lower in text:
            hits.append(entry)

if json_output:
    for e in hits:
        print(json.dumps(e, ensure_ascii=False))
else:
    if not hits:
        print("No entries matching query.")
    else:
        fmt = "%-26s %-12s %-16s %-4s %-12s %s"
        print(fmt % ("ID", "TYPE", "STATUS", "PRI", "OWNER", "SUMMARY"))
        print("-" * 110)
        for e in hits:
            print(fmt % (e['id'], e['type'], e['status'], e['priority'], e['owner'], e['summary'][:60]))
PY
}

cmd_history() {
  local target_id="" json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) target_id="$2"; shift 2 ;;
      --json) json_output=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown history option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$target_id" ]] || { echo "Error: --id is required" >&2; exit 1; }

  if [[ ! -s "$LEDGER" ]]; then
    echo "Ledger is empty."
    return 0
  fi

  python3 - "$LEDGER" "$target_id" "$json_output" <<'PY'
import json, sys

ledger_path, target_id, json_output = sys.argv[1:4]
json_output = json_output == "1"

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
            if json_output:
                print(json.dumps(entry, ensure_ascii=False, indent=2))
            else:
                print(f"Entry: {entry['id']}")
                print(f"Type: {entry['type']}  Status: {entry['status']}  Priority: {entry['priority']}")
                print(f"Owner: {entry['owner']}  Created: {entry['created_at']}")
                print(f"Summary: {entry['summary']}")
                if entry.get('due_date'):
                    print(f"Due: {entry['due_date']}")
                if entry.get('tags'):
                    print(f"Tags: {', '.join(entry['tags'])}")
                if entry.get('closure'):
                    c = entry['closure']
                    print(f"\nClosure:")
                    if c.get('artifact_path'):
                        print(f"  Artifact: {c['artifact_path']}")
                    if c.get('message_id'):
                        print(f"  Message: {c['message_id']}")
                    if c.get('note'):
                        print(f"  Note: {c['note']}")
                history = entry.get('history', [])
                if history:
                    print(f"\nHistory ({len(history)} transitions):")
                    for h in history:
                        fr = h.get('from_status', 'None')
                        to = h.get('to_status', '?')
                        print(f"  {h['ts']}: {fr} → {to} — {h.get('note','')}")
            sys.exit(0)
    print(f"Error: entry {target_id} not found", file=sys.stderr)
    sys.exit(1)
PY
}

cmd_gc() {
  local days=30 dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown gc option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ ! -s "$LEDGER" ]]; then
    echo "Ledger is empty. Nothing to gc."
    return 0
  fi

  python3 - "$LEDGER" "$days" "$dry_run" <<'PY'
import json, os, sys, tempfile, fcntl
from datetime import datetime, timezone, timedelta

ledger_path, days_str, dry_run_str = sys.argv[1:4]
days = int(days_str)
dry_run = dry_run_str == "1"
cutoff = datetime.now(timezone.utc) - timedelta(days=days)

closed_statuses = {'done_unverified', 'verified_done', 'dropped'}
archived = 0
kept = 0

with open(ledger_path, 'a+', encoding='utf-8') as lockf:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
    lockf.seek(0)
    lines = []
    for line in lockf:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            lines.append(line)
            continue
        if entry['status'] in closed_statuses:
            updated = entry.get('updated_at', entry.get('created_at', ''))
            try:
                dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
                if dt < cutoff:
                    if dry_run:
                        print(f"Would archive: {entry['id']} ({entry['status']}) — {entry['summary'][:60]}")
                    else:
                        entry['status'] = 'archived'
                        entry['updated_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                    archived += 1
            except (ValueError, AttributeError):
                pass
        else:
            kept += 1
        lines.append(json.dumps(entry, ensure_ascii=False))

    if not dry_run and archived > 0:
        dirpath = os.path.dirname(os.path.abspath(ledger_path)) or '.'
        fd, tmp_path = tempfile.mkstemp(prefix='.ledger.', suffix='.jsonl.tmp', dir=dirpath)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as tmp:
                for line in lines:
                    tmp.write(line + '\n')
                tmp.flush()
                os.fsync(tmp.fileno())
            os.replace(tmp_path, ledger_path)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
    fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)

action = "Would archive" if dry_run else "Archived"
print(f"{action}: {archived} entries (kept {kept} open)")
PY
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

command="$1"
shift

case "$command" in
  add) cmd_add "$@" ;;
  update) cmd_update "$@" ;;
  close) cmd_close "$@" ;;
  verify) cmd_verify "$@" ;;
  list) cmd_list "$@" ;;
  search) cmd_search "$@" ;;
  history) cmd_history "$@" ;;
  gc) cmd_gc "$@" ;;
  -h|--help) usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 1 ;;
esac
