#!/usr/bin/env bash
set -euo pipefail

# tier.sh — Memory decay / temperature tier classifier.
# Classifies memory files as HOT (<24h), WARM (1-7d), COLD (>7d)
# based on last modification time. Stores classifications in a
# tracker JSON file. Used by retrieve.sh to control retrieval depth.

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
MEMORY_DIR="${IRONCLAD_MEMORY_DIR:-$WORKSPACE/memory}"
TRACKER="${IRONCLAD_TIER_TRACKER:-$WORKSPACE/.ironclad/tier-tracker.json}"

# Thresholds in seconds (configurable via env)
THRESHOLD_HOT="${IRONCLAD_TIER_HOT_SECONDS:-86400}"       # 24 hours
THRESHOLD_WARM="${IRONCLAD_TIER_WARM_SECONDS:-604800}"     # 7 days

# Retrieval limits
WARM_PREVIEW_CHARS="${IRONCLAD_TIER_WARM_CHARS:-500}"

action="classify"
show_json=0
query_file=""

usage() {
  cat <<'EOF'
Usage:
  tier.sh [command] [options]

Commands:
  classify              Scan memory files and update tier tracker (default)
  show                  Print current tier classifications
  get <file>            Get tier for a specific file
  read <file>           Output file content filtered by its tier:
                          HOT  → full content
                          WARM → first N chars + truncation notice
                          COLD → one-line reference (name, age, size)

Options:
  --memory-dir PATH     Memory directory (default: $WORKSPACE/memory)
  --tracker PATH        Tracker JSON path (default: $WORKSPACE/.ironclad/tier-tracker.json)
  --hot-seconds N       HOT threshold in seconds (default: 86400 = 24h)
  --warm-seconds N      WARM threshold in seconds (default: 604800 = 7d)
  --warm-chars N        Characters to show for WARM files (default: 500)
  --json                JSON output for show/get commands
  -h, --help            Show help

Environment:
  IRONCLAD_WORKSPACE           Base workspace directory
  IRONCLAD_MEMORY_DIR          Memory directory
  IRONCLAD_TIER_TRACKER        Tracker JSON path
  IRONCLAD_TIER_HOT_SECONDS    HOT threshold (default: 86400)
  IRONCLAD_TIER_WARM_SECONDS   WARM threshold (default: 604800)
  IRONCLAD_TIER_WARM_CHARS     WARM preview length (default: 500)

Examples:
  tier.sh classify                    # Update tracker
  tier.sh show --json                 # Show all tiers as JSON
  tier.sh get memory/2026-03-25.md    # Get tier for one file
  tier.sh read memory/2026-03-20.md   # Read with tier-appropriate depth
EOF
}

# Parse arguments
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)   MEMORY_DIR="$2"; shift 2 ;;
    --tracker)      TRACKER="$2"; shift 2 ;;
    --hot-seconds)  THRESHOLD_HOT="$2"; shift 2 ;;
    --warm-seconds) THRESHOLD_WARM="$2"; shift 2 ;;
    --warm-chars)   WARM_PREVIEW_CHARS="$2"; shift 2 ;;
    --json)         show_json=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              args+=("$1"); shift ;;
  esac
done

# Determine action from positional args
if [[ ${#args[@]} -gt 0 ]]; then
  action="${args[0]}"
  if [[ ${#args[@]} -gt 1 ]]; then
    query_file="${args[1]}"
  fi
fi

# Get file modification time (portable: macOS + Linux)
get_mtime() {
  local file="$1"
  # Try GNU stat first, then macOS stat
  stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0
}

# Classify a single file's age into a tier
classify_tier() {
  local age="$1"
  if (( age < THRESHOLD_HOT )); then
    echo "hot"
  elif (( age <= THRESHOLD_WARM )); then
    echo "warm"
  else
    echo "cold"
  fi
}

# Human-readable age
format_age() {
  local seconds="$1"
  if (( seconds < 3600 )); then
    echo "$((seconds / 60))m"
  elif (( seconds < 86400 )); then
    echo "$((seconds / 3600))h"
  else
    echo "$((seconds / 86400))d"
  fi
}

# ── classify ──────────────────────────────────────────────

cmd_classify() {
  if [[ ! -d "$MEMORY_DIR" ]]; then
    echo "Error: memory directory not found: $MEMORY_DIR" >&2
    exit 1
  fi

  # Ensure tracker directory exists
  mkdir -p "$(dirname "$TRACKER")"

  local now
  now="$(date +%s)"

  python3 - "$MEMORY_DIR" "$TRACKER" "$now" "$THRESHOLD_HOT" "$THRESHOLD_WARM" <<'PY'
import json, os, sys, glob
from datetime import datetime, timezone

memory_dir = sys.argv[1]
tracker_path = sys.argv[2]
now = int(sys.argv[3])
hot_threshold = int(sys.argv[4])
warm_threshold = int(sys.argv[5])

files = []
for pattern in ["*.md", "*.txt"]:
    files.extend(glob.glob(os.path.join(memory_dir, pattern)))

# Also check MEMORY.md in parent (workspace root)
workspace = os.path.dirname(memory_dir)
root_memory = os.path.join(workspace, "MEMORY.md")
if os.path.isfile(root_memory):
    files.append(root_memory)

entries = []
stats = {"hot": 0, "warm": 0, "cold": 0}

for filepath in sorted(set(files)):
    if not os.path.isfile(filepath):
        continue
    try:
        mtime = int(os.path.getmtime(filepath))
        size = os.path.getsize(filepath)
    except OSError:
        continue

    age = now - mtime

    if age < hot_threshold:
        tier = "hot"
    elif age <= warm_threshold:
        tier = "warm"
    else:
        tier = "cold"

    stats[tier] += 1

    # Use relative path from workspace if possible
    try:
        rel = os.path.relpath(filepath, workspace)
    except ValueError:
        rel = os.path.basename(filepath)

    entries.append({
        "file": rel,
        "tier": tier,
        "age_seconds": age,
        "age_human": f"{age // 86400}d" if age >= 86400 else f"{age // 3600}h" if age >= 3600 else f"{age // 60}m",
        "size_bytes": size,
        "mtime": mtime,
    })

result = {
    "updated": datetime.now(timezone.utc).isoformat(),
    "thresholds": {
        "hot_seconds": hot_threshold,
        "warm_seconds": warm_threshold,
    },
    "summary": stats,
    "files": entries,
}

with open(tracker_path, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

total = len(entries)
print(f"Classified {total} files: {stats['hot']} HOT, {stats['warm']} WARM, {stats['cold']} COLD")
print(f"Tracker: {tracker_path}")
PY
}

# ── show ──────────────────────────────────────────────────

cmd_show() {
  if [[ ! -f "$TRACKER" ]]; then
    echo "No tier tracker found. Run 'ironclad tier classify' first." >&2
    exit 1
  fi

  if [[ $show_json -eq 1 ]]; then
    cat "$TRACKER"
    return
  fi

  python3 - "$TRACKER" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

s = data.get("summary", {})
print(f"Memory Tiers (updated: {data['updated']})")
print(f"  HOT:  {s.get('hot', 0)}  (<{data['thresholds']['hot_seconds'] // 3600}h)")
print(f"  WARM: {s.get('warm', 0)}  (<{data['thresholds']['warm_seconds'] // 86400}d)")
print(f"  COLD: {s.get('cold', 0)}  (>{data['thresholds']['warm_seconds'] // 86400}d)")
print()

tier_order = {"hot": 0, "warm": 1, "cold": 2}
tier_icons = {"hot": "🔴", "warm": "🟡", "cold": "🔵"}

for entry in sorted(data["files"], key=lambda e: (tier_order.get(e["tier"], 9), e["file"])):
    icon = tier_icons.get(entry["tier"], "⚪")
    size_kb = entry["size_bytes"] / 1024
    print(f"  {icon} {entry['tier'].upper():4s}  {entry['age_human']:>4s}  {size_kb:6.1f}KB  {entry['file']}")
PY
}

# ── get ───────────────────────────────────────────────────

cmd_get() {
  if [[ -z "$query_file" ]]; then
    echo "Error: 'get' requires a file path" >&2
    echo "Usage: tier.sh get <file>" >&2
    exit 1
  fi

  # If tracker exists, look up the file
  if [[ -f "$TRACKER" ]]; then
    local result
    result="$(python3 - "$TRACKER" "$query_file" "$WORKSPACE" <<'PY'
import json, sys, os

tracker_path = sys.argv[1]
query = sys.argv[2]
workspace = sys.argv[3]

with open(tracker_path) as f:
    data = json.load(f)

# Try exact match, basename match, or relative path match
query_base = os.path.basename(query)
try:
    query_rel = os.path.relpath(query, workspace)
except ValueError:
    query_rel = query

for entry in data["files"]:
    if entry["file"] == query or entry["file"] == query_rel or os.path.basename(entry["file"]) == query_base:
        print(entry["tier"])
        sys.exit(0)

# Not in tracker — classify on the fly
print("unknown")
PY
    )"

    if [[ "$result" != "unknown" ]]; then
      if [[ $show_json -eq 1 ]]; then
        echo "{\"file\":\"$query_file\",\"tier\":\"$result\"}"
      else
        echo "$result"
      fi
      return
    fi
  fi

  # Fall back to live classification
  if [[ ! -e "$query_file" ]]; then
    echo "Error: file not found: $query_file" >&2
    exit 1
  fi

  local mtime now age tier
  now="$(date +%s)"
  mtime="$(get_mtime "$query_file")"
  age=$(( now - mtime ))
  tier="$(classify_tier "$age")"

  if [[ $show_json -eq 1 ]]; then
    echo "{\"file\":\"$query_file\",\"tier\":\"$tier\",\"age_seconds\":$age}"
  else
    echo "$tier"
  fi
}

# ── read ──────────────────────────────────────────────────

cmd_read() {
  if [[ -z "$query_file" ]]; then
    echo "Error: 'read' requires a file path" >&2
    echo "Usage: tier.sh read <file>" >&2
    exit 1
  fi

  # Resolve the actual file path
  local filepath="$query_file"
  if [[ ! -f "$filepath" ]]; then
    # Try relative to memory dir
    if [[ -f "$MEMORY_DIR/$filepath" ]]; then
      filepath="$MEMORY_DIR/$filepath"
    elif [[ -f "$WORKSPACE/$filepath" ]]; then
      filepath="$WORKSPACE/$filepath"
    else
      echo "Error: file not found: $query_file" >&2
      exit 1
    fi
  fi

  # Get the tier
  local tier
  # Check tracker first
  if [[ -f "$TRACKER" ]]; then
    tier="$(python3 -c "
import json, os, sys
with open('$TRACKER') as f:
    data = json.load(f)
query = '$filepath'
workspace = '$WORKSPACE'
query_base = os.path.basename(query)
try:
    query_rel = os.path.relpath(query, workspace)
except ValueError:
    query_rel = query
for entry in data['files']:
    if entry['file'] == query or entry['file'] == query_rel or os.path.basename(entry['file']) == query_base:
        print(entry['tier'])
        sys.exit(0)
print('unknown')
" 2>/dev/null || echo "unknown")"
  fi

  if [[ "${tier:-unknown}" == "unknown" ]]; then
    local now mtime age
    now="$(date +%s)"
    mtime="$(get_mtime "$filepath")"
    age=$(( now - mtime ))
    tier="$(classify_tier "$age")"
  fi

  # Output based on tier
  case "$tier" in
    hot)
      cat "$filepath"
      ;;
    warm)
      head -c "$WARM_PREVIEW_CHARS" "$filepath"
      local size
      size="$(wc -c < "$filepath" | tr -d ' ')"
      if (( size > WARM_PREVIEW_CHARS )); then
        echo ""
        echo "[TRUNCATED — WARM tier: showing first ${WARM_PREVIEW_CHARS} of ${size} bytes. Use 'tier.sh read <file> --force-hot' or set IRONCLAD_TIER_WARM_CHARS to see more.]"
      fi
      ;;
    cold)
      local size age_human bn
      bn="$(basename "$filepath")"
      size="$(wc -c < "$filepath" | tr -d ' ')"
      local now mtime age_s
      now="$(date +%s)"
      mtime="$(get_mtime "$filepath")"
      age_s=$(( now - mtime ))
      age_human="$(format_age "$age_s")"
      echo "[COLD] $bn — ${size} bytes, last modified ${age_human} ago. Use 'tier.sh read <file> --force-hot' to load full content."
      ;;
  esac
}

# ── dispatch ──────────────────────────────────────────────

case "$action" in
  classify)   cmd_classify ;;
  show)       cmd_show ;;
  get)        cmd_get ;;
  read)       cmd_read ;;
  -h|--help|help) usage ;;
  *)
    echo "Unknown tier command: $action" >&2
    echo "Run 'tier.sh --help' for available commands." >&2
    exit 1
    ;;
esac
