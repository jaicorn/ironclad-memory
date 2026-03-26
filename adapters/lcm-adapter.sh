#!/usr/bin/env bash
set -euo pipefail

# lcm-adapter.sh — Optional LCM (Lossless Context Management) retrieval adapter.
# Searches the LCM database for conversation evidence matching given terms.
#
# This adapter is only called when IRONCLAD_LCM_ADAPTER=1 is set.
# It requires access to an LCM database file.

LCM_DB="${IRONCLAD_LCM_DB:-${LCM_DB_PATH:-}}"

usage() {
  cat <<'EOF'
Usage:
  lcm-adapter.sh <term> [<term> ...]

Search the LCM database for conversation evidence matching the given terms.
Returns matching snippets suitable for inclusion in a retrieval brief.

Environment:
  IRONCLAD_LCM_DB     Path to LCM database file
  LCM_DB_PATH         Fallback path to LCM database file

Example:
  IRONCLAD_LCM_DB=/path/to/lcm.db lcm-adapter.sh "deployment" "v2.1"
EOF
}

if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$LCM_DB" ]] || [[ ! -f "$LCM_DB" ]]; then
  echo "LCM database not found. Set IRONCLAD_LCM_DB or LCM_DB_PATH." >&2
  exit 1
fi

terms=("$@")

python3 - "$LCM_DB" "${terms[@]}" <<'PY'
import json, sys, sqlite3, os

db_path = sys.argv[1]
terms = sys.argv[2:]

if not os.path.isfile(db_path):
    print("LCM database not found.", file=sys.stderr)
    sys.exit(1)

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
except Exception as e:
    print(f"Cannot open LCM database: {e}", file=sys.stderr)
    sys.exit(1)

# Try common table names for LCM storage
tables_to_try = ["messages", "summaries", "conversation_messages"]
available_tables = set()
try:
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
        available_tables.add(row[0])
except Exception:
    pass

results = []
for table in tables_to_try:
    if table not in available_tables:
        continue
    try:
        # Get column names
        cursor = conn.execute(f"PRAGMA table_info({table})")
        columns = [row[1] for row in cursor.fetchall()]

        # Find text-like columns
        text_cols = [c for c in columns if any(k in c.lower() for k in
                     ("content", "text", "message", "summary", "body"))]
        if not text_cols:
            continue

        for term in terms:
            for col in text_cols:
                query = f"SELECT * FROM {table} WHERE {col} LIKE ? ORDER BY rowid DESC LIMIT 5"
                for row in conn.execute(query, (f"%{term}%",)):
                    row_dict = dict(row)
                    content = row_dict.get(col, "")
                    if content:
                        results.append({
                            "source": f"lcm:{table}",
                            "term": term,
                            "snippet": str(content)[:200],
                        })
    except Exception:
        continue

conn.close()

if results:
    for r in results:
        print(f"  - [{r['term']}] ({r['source']}) {r['snippet']}")
else:
    print("  - No LCM matches found.")
PY
