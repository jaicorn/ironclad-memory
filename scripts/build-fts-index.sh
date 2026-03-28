#!/usr/bin/env bash
# build-fts-index.sh — Build FTS5 full-text search index over workspace markdown files
# Splits markdown files by ## headers into sections, indexes with porter stemming
# Usage: scripts/build-fts-index.sh [--quiet]
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
TEMP_DB="${DB_PATH}.tmp"
QUIET=false

[[ "${1:-}" == "--quiet" ]] && QUIET=true

cd "$WORKSPACE"

# Ensure data directory exists
mkdir -p "$(dirname "$DB_PATH")"

# Remove temp db if exists
rm -f "$TEMP_DB" "$TEMP_DB-wal" "$TEMP_DB-shm"

$QUIET || echo "Building FTS5 index..."
$QUIET || echo "Workspace: $WORKSPACE"
$QUIET || echo "Database: $DB_PATH"
$QUIET || echo ""

# Check for sqlite3
if ! command -v sqlite3 &>/dev/null; then
  echo "ERROR: sqlite3 not found. Install SQLite to use FTS5 indexing." >&2
  exit 1
fi

# Create database schema
sqlite3 "$TEMP_DB" <<'SQL'
CREATE TABLE sections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT NOT NULL,
    section_header TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL,
    last_modified TEXT NOT NULL
);

CREATE VIRTUAL TABLE sections_fts USING fts5(
    file_path,
    section_header,
    content,
    content='sections',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER sections_ai AFTER INSERT ON sections BEGIN
    INSERT INTO sections_fts(rowid, file_path, section_header, content)
    VALUES (new.id, new.file_path, new.section_header, new.content);
END;

CREATE TRIGGER sections_ad AFTER DELETE ON sections BEGIN
    INSERT INTO sections_fts(sections_fts, rowid, file_path, section_header, content)
    VALUES('delete', old.id, old.file_path, old.section_header, old.content);
END;

CREATE TRIGGER sections_au AFTER UPDATE ON sections BEGIN
    INSERT INTO sections_fts(sections_fts, rowid, file_path, section_header, content)
    VALUES('delete', old.id, old.file_path, old.section_header, old.content);
    INSERT INTO sections_fts(rowid, file_path, section_header, content)
    VALUES (new.id, new.file_path, new.section_header, new.content);
END;
SQL

# Collect files to index
MEMORY_DIR="${IRONCLAD_MEMORY_DIR:-$WORKSPACE/memory}"
FILES=()

# MEMORY.md at root
[[ -f "MEMORY.md" ]] && FILES+=("MEMORY.md")

# memory/*.md
if [[ -d "$MEMORY_DIR" ]]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$MEMORY_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)
fi

# data/**/*.md (excluding research if present)
if [[ -d "data" ]]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(find data -name "*.md" -type f -not -path "data/research/*" 2>/dev/null | sort)
fi

TOTAL_FILES=${#FILES[@]}
TOTAL_SECTIONS=0
ERRORS=0

$QUIET || echo "Found $TOTAL_FILES files to index"
$QUIET || echo ""

# Process each file
for filepath in "${FILES[@]}"; do
  if [[ ! -f "$filepath" ]]; then
    $QUIET || echo "  SKIP (missing): $filepath"
    ((ERRORS++)) || true
    continue
  fi

  # Get last modified time (macOS and Linux compatible)
  last_modified=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$filepath" 2>/dev/null \
    || date -r "$filepath" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
    || stat -c '%y' "$filepath" 2>/dev/null \
    || echo "unknown")

  # Use Python for reliable markdown section splitting and SQLite insertion
  python3 -c "
import sqlite3, re

filepath = '''$filepath'''
last_modified = '''$last_modified'''

with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Split by ## headers (level 1-4)
sections = []
current_header = ''
current_content = []
in_code_block = False

for line in content.split('\n'):
    if line.strip().startswith('\`\`\`'):
        in_code_block = not in_code_block
        current_content.append(line)
        continue

    if not in_code_block and re.match(r'^#{1,4}\s+', line):
        if current_content:
            text = '\n'.join(current_content).strip()
            if text:
                sections.append((current_header, text))
        current_header = line.strip().lstrip('#').strip()
        current_content = [line]
    else:
        current_content.append(line)

if current_content:
    text = '\n'.join(current_content).strip()
    if text:
        sections.append((current_header, text))

if not sections:
    sections = [('', content.strip())]

conn = sqlite3.connect('$TEMP_DB')
c = conn.cursor()
for header, text in sections:
    c.execute('INSERT INTO sections (file_path, section_header, content, last_modified) VALUES (?, ?, ?, ?)',
              (filepath, header, text, last_modified))
conn.commit()
conn.close()

print(len(sections))
" 2>/dev/null

  section_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM sections WHERE file_path = '$filepath'")
  TOTAL_SECTIONS=$((TOTAL_SECTIONS + section_count))
done

# Optimize
sqlite3 "$TEMP_DB" "INSERT INTO sections_fts(sections_fts) VALUES('optimize');"
sqlite3 "$TEMP_DB" "VACUUM;"

# Atomic swap
mv -f "$TEMP_DB" "$DB_PATH"
rm -f "${TEMP_DB}-wal" "${TEMP_DB}-shm"

$QUIET || echo ""
$QUIET || echo "=== FTS5 Index Build Complete ==="
$QUIET || echo "Files indexed: $TOTAL_FILES"
$QUIET || echo "Total sections: $TOTAL_SECTIONS"
$QUIET || echo "Errors: $ERRORS"
$QUIET || echo "Database size: $(du -h "$DB_PATH" | cut -f1)"
$QUIET || echo "Database: $DB_PATH"
