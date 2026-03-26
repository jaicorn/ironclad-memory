#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — Installation validator for Ironclad Memory.
# Checks dependencies, directories, permissions, and configuration.

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
  cat <<'EOF'
Usage:
  doctor.sh [options]

Validate Ironclad Memory installation.

Checks:
  - Required directories exist
  - Ledger file is valid JSONL (or empty)
  - Memory directory is writable
  - Python3 is available
  - jq is available
  - All script files are executable
  - Adapter configuration

Options:
  --fix     Attempt to fix issues where possible
  -h, --help    Show help
EOF
}

fix_mode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)     fix_mode=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

WORKSPACE="$(detect_workspace)"
MEMORY_DIR="${IRONCLAD_MEMORY_DIR:-$WORKSPACE/memory}"
LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"

pass=0
fail=0
warn=0

check_pass() {
  printf "  ✅ %s\n" "$1"
  ((pass++)) || true
}

check_fail() {
  printf "  ❌ %s\n" "$1"
  if [[ -n "${2:-}" ]]; then
    printf "     Fix: %s\n" "$2"
  fi
  ((fail++)) || true
}

check_warn() {
  printf "  ⚠️  %s\n" "$1"
  ((warn++)) || true
}

echo "Ironclad Memory Doctor"
echo "======================"
echo "Workspace: $WORKSPACE"
echo ""

# --- Dependencies ---
echo "Dependencies:"

if command -v python3 &>/dev/null; then
  py_ver="$(python3 --version 2>&1)"
  check_pass "Python3 available ($py_ver)"
else
  check_fail "Python3 not found" "Install Python 3: https://www.python.org/downloads/"
fi

if command -v jq &>/dev/null; then
  jq_ver="$(jq --version 2>&1)"
  check_pass "jq available ($jq_ver)"
else
  check_fail "jq not found" "Install jq: https://stedolan.github.io/jq/download/"
fi

echo ""

# --- Directories ---
echo "Directories:"

if [[ -d "$WORKSPACE/.ironclad" ]]; then
  check_pass ".ironclad/ directory exists"
else
  if [[ $fix_mode -eq 1 ]]; then
    mkdir -p "$WORKSPACE/.ironclad"
    check_pass ".ironclad/ directory created"
  else
    check_fail ".ironclad/ directory missing" "Run: ironclad init"
  fi
fi

if [[ -d "$MEMORY_DIR" ]]; then
  check_pass "Memory directory exists ($MEMORY_DIR)"
else
  if [[ $fix_mode -eq 1 ]]; then
    mkdir -p "$MEMORY_DIR"
    check_pass "Memory directory created ($MEMORY_DIR)"
  else
    check_fail "Memory directory missing ($MEMORY_DIR)" "Run: mkdir -p $MEMORY_DIR"
  fi
fi

ledger_dir="$(dirname "$LEDGER")"
if [[ -d "$ledger_dir" ]]; then
  check_pass "Ledger directory exists ($ledger_dir)"
else
  if [[ $fix_mode -eq 1 ]]; then
    mkdir -p "$ledger_dir"
    check_pass "Ledger directory created ($ledger_dir)"
  else
    check_fail "Ledger directory missing ($ledger_dir)" "Run: mkdir -p $ledger_dir"
  fi
fi

if [[ -d "$WORKSPACE/data/escalations" ]]; then
  check_pass "Escalation directory exists"
else
  if [[ $fix_mode -eq 1 ]]; then
    mkdir -p "$WORKSPACE/data/escalations"
    check_pass "Escalation directory created"
  else
    check_warn "Escalation directory missing (will be created on first escalate run)"
  fi
fi

echo ""

# --- Memory directory writable ---
echo "Permissions:"

if [[ -d "$MEMORY_DIR" ]]; then
  if touch "$MEMORY_DIR/.doctor-test" 2>/dev/null; then
    rm -f "$MEMORY_DIR/.doctor-test"
    check_pass "Memory directory is writable"
  else
    check_fail "Memory directory is not writable ($MEMORY_DIR)" "Run: chmod u+w $MEMORY_DIR"
  fi
fi

if [[ -d "$ledger_dir" ]]; then
  if touch "$ledger_dir/.doctor-test" 2>/dev/null; then
    rm -f "$ledger_dir/.doctor-test"
    check_pass "Ledger directory is writable"
  else
    check_fail "Ledger directory is not writable ($ledger_dir)" "Run: chmod u+w $ledger_dir"
  fi
fi

echo ""

# --- Ledger validation ---
echo "Ledger:"

if [[ ! -f "$LEDGER" ]]; then
  if [[ $fix_mode -eq 1 ]]; then
    touch "$LEDGER"
    check_pass "Ledger file created (empty)"
  else
    check_warn "Ledger file does not exist yet (will be created on first use)"
  fi
elif [[ ! -s "$LEDGER" ]]; then
  check_pass "Ledger file exists (empty)"
else
  # Validate JSONL
  invalid_lines="$(python3 -c "
import json, sys
invalid = 0
with open(sys.argv[1], 'r') as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError:
            invalid += 1
            if invalid <= 3:
                print(f'  Line {i}: invalid JSON', file=sys.stderr)
print(invalid)
" "$LEDGER" 2>&1)"

  if echo "$invalid_lines" | tail -1 | grep -q '^0$'; then
    entry_count="$(wc -l < "$LEDGER" | tr -d ' ')"
    check_pass "Ledger is valid JSONL ($entry_count entries)"
  else
    check_fail "Ledger has invalid JSON lines" "Review and fix manually: $LEDGER"
  fi
fi

echo ""

# --- Scripts ---
echo "Scripts:"

scripts=(ironclad.sh flush.sh retrieve.sh ledger.sh capture.sh loops.sh escalate.sh doctor.sh)
for script in "${scripts[@]}"; do
  script_path="$SCRIPT_DIR/$script"
  if [[ ! -f "$script_path" ]]; then
    check_fail "$script not found"
  elif [[ ! -x "$script_path" ]]; then
    if [[ $fix_mode -eq 1 ]]; then
      chmod +x "$script_path"
      check_pass "$script made executable"
    else
      check_fail "$script is not executable" "Run: chmod +x $script_path"
    fi
  else
    check_pass "$script is executable"
  fi
done

echo ""

# --- Adapters ---
echo "Adapters:"

lcm_adapter="$SCRIPT_DIR/../adapters/lcm-adapter.sh"
stitch_adapter="$SCRIPT_DIR/../adapters/cross-session-stitch.sh"

if [[ "${IRONCLAD_LCM_ADAPTER:-0}" == "1" ]]; then
  if [[ -x "$lcm_adapter" ]]; then
    check_pass "LCM adapter enabled and executable"
  elif [[ -f "$lcm_adapter" ]]; then
    check_fail "LCM adapter enabled but not executable" "Run: chmod +x $lcm_adapter"
  else
    check_fail "LCM adapter enabled but file not found" "Create adapters/lcm-adapter.sh"
  fi
else
  if [[ -f "$lcm_adapter" ]]; then
    check_pass "LCM adapter present (disabled — set IRONCLAD_LCM_ADAPTER=1 to enable)"
  else
    check_pass "LCM adapter not configured (optional)"
  fi
fi

if [[ -f "$stitch_adapter" ]]; then
  if [[ -x "$stitch_adapter" ]]; then
    check_pass "Cross-session stitch adapter present and executable"
  else
    check_warn "Cross-session stitch adapter present but not executable"
  fi
else
  check_pass "Cross-session stitch adapter not configured (optional)"
fi

echo ""

# --- Summary ---
echo "========================"
printf "Results: %d passed, %d failed, %d warnings\n" "$pass" "$fail" "$warn"

if [[ $fail -gt 0 ]]; then
  echo ""
  echo "Run 'doctor.sh --fix' to attempt automatic fixes."
  exit 1
fi

if [[ $warn -gt 0 ]]; then
  echo "All critical checks passed."
  exit 0
fi

echo "All checks passed. Ironclad Memory is healthy."
exit 0
