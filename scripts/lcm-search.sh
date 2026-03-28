#!/usr/bin/env bash
# lcm-search.sh — Topic-aware LCM grep helper
# Usage: scripts/lcm-search.sh "search query"
#
# 1. Checks references/lcm-patterns.json for matching topic patterns
# 2. Falls back to auto-generated variants (exact phrase, reversed word order, key terms)
# 3. Outputs search plan for the agent to execute via lcm_grep tool calls
# 4. Also searches local files as a supplement
set -euo pipefail

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

# Look for patterns file in skill references/ first, then workspace data/
PATTERNS_FILE=""
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$SKILL_DIR/references/lcm-patterns.json" ]]; then
  PATTERNS_FILE="$SKILL_DIR/references/lcm-patterns.json"
elif [[ -f "$WORKSPACE/data/lcm-patterns.json" ]]; then
  PATTERNS_FILE="$WORKSPACE/data/lcm-patterns.json"
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <query>"
  echo "Example: $0 \"deployment status\""
  exit 1
fi

QUERY="$1"
QUERY_LOWER="$(echo "$QUERY" | tr '[:upper:]' '[:lower:]')"

# Collect all patterns to search
declare -a SEARCH_PATTERNS=()

# --- Step 1: Check lcm-patterns.json for topic matches ---
if [[ -n "$PATTERNS_FILE" && -f "$PATTERNS_FILE" ]] && command -v jq &>/dev/null; then
  TOPICS=$(jq -r --arg q "$QUERY_LOWER" '
    .patterns | to_entries[] |
    select(
      .key as $k |
      ($q | test($k; "i")) or
      (.value.description | ascii_downcase | test($q | split(" ")[0]; "i"))
    ) |
    .key
  ' "$PATTERNS_FILE" 2>/dev/null || true)

  if [[ -n "$TOPICS" ]]; then
    while IFS= read -r topic; do
      TOPIC_PATTERNS=$(jq -r --arg t "$topic" '.patterns[$t].patterns[]' "$PATTERNS_FILE" 2>/dev/null || true)
      while IFS= read -r pat; do
        [[ -n "$pat" ]] && SEARCH_PATTERNS+=("$pat")
      done <<< "$TOPIC_PATTERNS"
    done <<< "$TOPICS"
  fi
fi

# --- Step 2: Auto-generate fallback patterns ---
SEARCH_PATTERNS+=("$QUERY")

WORDS=()
read -ra WORDS <<< "$QUERY"
if [[ ${#WORDS[@]} -gt 1 ]]; then
  REVERSED=""
  for ((i=${#WORDS[@]}-1; i>=0; i--)); do
    [[ -n "$REVERSED" ]] && REVERSED+=".*"
    REVERSED+="${WORDS[$i]}"
  done
  SEARCH_PATTERNS+=("$REVERSED")

  STOP_WORDS="the a an is are was were be been being have has had do does did will would shall should may might can could of in on at to for with by from"
  for word in "${WORDS[@]}"; do
    word_lower="$(echo "$word" | tr '[:upper:]' '[:lower:]')"
    if [[ ${#word_lower} -gt 2 ]] && ! echo "$STOP_WORDS" | grep -qw "$word_lower"; then
      SEARCH_PATTERNS+=("$word")
    fi
  done
fi

# --- Step 3: Deduplicate patterns ---
UNIQUE_PATTERNS=()
for pat in "${SEARCH_PATTERNS[@]}"; do
  skip=0
  for seen in "${UNIQUE_PATTERNS[@]+"${UNIQUE_PATTERNS[@]}"}"; do
    [[ "$seen" == "$pat" ]] && skip=1 && break
  done
  [[ $skip -eq 0 ]] && UNIQUE_PATTERNS+=("$pat")
done

# --- Step 4: Output search plan ---
echo "=== LCM Search Plan ==="
echo "Query: $QUERY"
echo "Patterns to search (${#UNIQUE_PATTERNS[@]}):"
for pat in "${UNIQUE_PATTERNS[@]}"; do
  echo "  - $pat"
done
echo ""

# --- Step 5: Search instructions for the agent ---
echo "=== Execute These lcm_grep Calls ==="
echo ""
for pat in "${UNIQUE_PATTERNS[@]}"; do
  echo "lcm_grep(pattern=\"$pat\", mode=\"full_text\")"
done

echo ""
echo "=== After Results ==="
echo "1. Collect all unique summary IDs (sum_xxx) from results"
echo "2. For detailed content: lcm_describe(id=\"sum_xxx\") for each relevant ID"
echo "3. Cross-reference with file-based sources for verification"
echo ""

# --- Step 6: Also search local files as supplement ---
MEMORY_DIR="${IRONCLAD_MEMORY_DIR:-$WORKSPACE/memory}"

echo "=== Local File Search (Supplement) ==="

if [[ -f "$WORKSPACE/data/memory-index.md" ]]; then
  echo "--- memory-index.md matches ---"
  grep -i "$QUERY" "$WORKSPACE/data/memory-index.md" 2>/dev/null | head -10 || echo "(no matches)"
  echo ""
fi

if [[ -f "$WORKSPACE/MEMORY.md" ]]; then
  echo "--- MEMORY.md matches ---"
  grep -i "$QUERY" "$WORKSPACE/MEMORY.md" 2>/dev/null | head -10 || echo "(no matches)"
  echo ""
fi

# Search today's and yesterday's memory files
TODAY=$(date +%Y-%m-%d)
# macOS and Linux compatible yesterday calculation
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || echo "")

for DAY in "$TODAY" "$YESTERDAY"; do
  [[ -z "$DAY" ]] && continue
  DAYFILE="$MEMORY_DIR/$DAY.md"
  if [[ -f "$DAYFILE" ]]; then
    echo "--- memory/$DAY.md matches ---"
    grep -i "$QUERY" "$DAYFILE" 2>/dev/null | head -5 || echo "(no matches)"
    echo ""
  fi
done
