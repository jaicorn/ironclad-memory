#!/usr/bin/env bash
set -euo pipefail

# flush.sh — Memory flush engine.
# Writes structured memory sections to daily files before context is lost.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
TZ_NAME="${IRONCLAD_TIMEZONE:-UTC}"
TODAY="$(TZ="$TZ_NAME" date +%F)"
STAMP="$(TZ="$TZ_NAME" date +"%H:%M %Z")"
TARGET="$MEMORY_DIR/$TODAY.md"

usage() {
  cat <<'EOF'
Usage:
  flush.sh [options]

Append a structured memory flush to memory/YYYY-MM-DD.md.

Options (repeatable):
  --commitment TEXT   Active commitment being tracked
  --inflight TEXT     In-flight work currently underway
  --blocker TEXT      Blocker, risk, or unknown
  --state TEXT        System/deployment/runtime state worth preserving
  --expectation TEXT  What someone/something is expecting next
  --next TEXT         Single next recovery step
  --ledger            Also sync commitments/blockers to the commitment ledger
  --file PATH         Override target file (default: memory/YYYY-MM-DD.md)
  -h, --help          Show this help

Environment:
  IRONCLAD_WORKSPACE    Base workspace directory
  IRONCLAD_MEMORY_DIR   Memory directory (default: $WORKSPACE/memory)
  IRONCLAD_TIMEZONE     Timezone for timestamps (default: UTC)

Example:
  flush.sh \
    --commitment "Deploy v2.1 by Friday" \
    --inflight "Database migration running" \
    --blocker "Auth token expired" \
    --state "Repo at commit abc123" \
    --expectation "User expects deployment status update" \
    --next "Verify migration completes cleanly"
EOF
}

ledger_sync=0
commitments=()
inflight=()
blockers=()
states=()
expectations=()
next_steps=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commitment)
      commitments+=("$2"); shift 2 ;;
    --inflight)
      inflight+=("$2"); shift 2 ;;
    --blocker)
      blockers+=("$2"); shift 2 ;;
    --state)
      states+=("$2"); shift 2 ;;
    --expectation)
      expectations+=("$2"); shift 2 ;;
    --next)
      next_steps+=("$2"); shift 2 ;;
    --ledger)
      ledger_sync=1; shift ;;
    --file)
      TARGET="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

mkdir -p "$(dirname "$TARGET")"
touch "$TARGET"

print_section() {
  local title="$1"
  shift
  local items=("$@")
  printf "### %s\n" "$title"
  if [[ ${#items[@]} -eq 0 ]]; then
    printf -- "- None.\n\n"
    return
  fi
  local item
  for item in "${items[@]}"; do
    printf -- "- %s\n" "$item"
  done
  printf "\n"
}

{
  printf "\n## Memory Flush — %s\n\n" "$STAMP"
  print_section "Active commitments" "${commitments[@]+"${commitments[@]}"}"
  print_section "In-flight work" "${inflight[@]+"${inflight[@]}"}"
  print_section "Blockers / risks" "${blockers[@]+"${blockers[@]}"}"
  print_section "System state" "${states[@]+"${states[@]}"}"
  print_section "Pending expectations" "${expectations[@]+"${expectations[@]}"}"
  print_section "Next recovery step" "${next_steps[@]+"${next_steps[@]}"}"
} >> "$TARGET"

# Summary output
section_count=0
[[ ${#commitments[@]} -gt 0 ]] && ((section_count += ${#commitments[@]})) || true
[[ ${#inflight[@]} -gt 0 ]] && ((section_count += ${#inflight[@]})) || true
[[ ${#blockers[@]} -gt 0 ]] && ((section_count += ${#blockers[@]})) || true
[[ ${#states[@]} -gt 0 ]] && ((section_count += ${#states[@]})) || true
[[ ${#expectations[@]} -gt 0 ]] && ((section_count += ${#expectations[@]})) || true
[[ ${#next_steps[@]} -gt 0 ]] && ((section_count += ${#next_steps[@]})) || true

echo "Flushed $section_count items to $TARGET"

# Optionally sync to commitment ledger
if [[ $ledger_sync -eq 1 ]]; then
  CAPTURE_SCRIPT="$SCRIPT_DIR/capture.sh"
  if [[ -x "$CAPTURE_SCRIPT" ]]; then
    capture_args=(from-flush)
    for c in "${commitments[@]+"${commitments[@]}"}"; do
      capture_args+=(--commitment "$c")
    done
    for b in "${blockers[@]+"${blockers[@]}"}"; do
      capture_args+=(--blocker "$b")
    done
    if [[ ${#commitments[@]} -gt 0 || ${#blockers[@]} -gt 0 ]]; then
      "$CAPTURE_SCRIPT" "${capture_args[@]}" || echo "Warning: ledger capture had errors" >&2
    fi
  else
    echo "Warning: capture.sh not found or not executable" >&2
  fi
fi
