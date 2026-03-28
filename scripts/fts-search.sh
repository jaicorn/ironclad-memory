#!/usr/bin/env bash
# fts-search.sh — Search the FTS5 index for workspace markdown content
# Usage: fts-search.sh "search query" [--limit N] [--json]
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
DB_PATH="${IRONCLAD_FTS_DB:-$WORKSPACE/data/fts5-index.db}"
LIMIT=10
JSON=false

if [[ $# -lt 1 ]]; then
  echo "Usage: fts-search.sh \"search query\" [--limit N] [--json]"
  exit 1
fi

RAW_QUERY="$1"
shift

# Sanitize query for FTS5: quote terms containing special characters
QUERY=""
for term in $RAW_QUERY; do
  if [[ "$term" =~ [.\-/\\@:] ]]; then
    # Wrap in double quotes so FTS5 treats it as a literal phrase
    term="\"$term\""
  fi
  if [[ -z "$QUERY" ]]; then
    QUERY="$term"
  else
    QUERY="$QUERY $term"
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    *) shift ;;
  esac
done

if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: FTS5 index not found at $DB_PATH"
  echo "Run: scripts/build-fts-index.sh"
  exit 1
fi

if $JSON; then
  sqlite3 -json "$DB_PATH" <<SQL
SELECT
    s.file_path,
    s.section_header,
    snippet(sections_fts, 2, '>>>', '<<<', '...', 40) AS snippet,
    round(rank, 4) AS relevance_score,
    s.last_modified
FROM sections_fts
JOIN sections s ON s.id = sections_fts.rowid
WHERE sections_fts MATCH '$(echo "$QUERY" | sed "s/'/''/g")'
ORDER BY rank
LIMIT $LIMIT;
SQL
else
  sqlite3 -header -column "$DB_PATH" <<SQL
SELECT
    s.file_path AS file,
    s.section_header AS section,
    snippet(sections_fts, 2, '>>>', '<<<', '...', 30) AS snippet,
    round(rank, 2) AS score
FROM sections_fts
JOIN sections s ON s.id = sections_fts.rowid
WHERE sections_fts MATCH '$(echo "$QUERY" | sed "s/'/''/g")'
ORDER BY rank
LIMIT $LIMIT;
SQL
fi
