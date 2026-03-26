#!/usr/bin/env bash
set -euo pipefail

# cross-session-stitch.sh — Optional cross-session conversation stitching adapter.
# Finds related conversations across session boundaries using a shared identifier
# (e.g., chat ID, thread ID, user ID).
#
# This is useful for messaging platforms where the AI agent's internal session
# boundaries don't match the human's conversation thread.

STITCH_DB="${IRONCLAD_STITCH_DB:-${LCM_DB_PATH:-}}"

usage() {
  cat <<'EOF'
Usage:
  cross-session-stitch.sh [options] <term> [<term> ...]

Find and stitch related conversation fragments across session boundaries.

Options:
  --chat-id ID          Stitch by chat/thread ID
  --session-key KEY     Stitch by session key pattern
  --limit N             Max results per term (default: 10)
  -h, --help            Show help

Environment:
  IRONCLAD_STITCH_DB    Path to conversation database
  LCM_DB_PATH           Fallback path

Example:
  cross-session-stitch.sh --chat-id "12345" "deployment" "status"
EOF
}

chat_id=""
session_key=""
limit=10
terms=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-id)     chat_id="$2"; shift 2 ;;
    --session-key) session_key="$2"; shift 2 ;;
    --limit)       limit="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; exit 1 ;;
    *)             terms+=("$1"); shift ;;
  esac
done

if [[ ${#terms[@]} -eq 0 ]]; then
  echo "Error: at least one search term is required" >&2
  exit 1
fi

if [[ -z "$STITCH_DB" ]] || [[ ! -f "$STITCH_DB" ]]; then
  echo "Stitch database not found. Set IRONCLAD_STITCH_DB or LCM_DB_PATH." >&2
  exit 1
fi

python3 - "$STITCH_DB" "$chat_id" "$session_key" "$limit" "${terms[@]}" <<'PY'
import json, sys, sqlite3, os

db_path = sys.argv[1]
chat_id = sys.argv[2]
session_key = sys.argv[3]
limit = int(sys.argv[4])
terms = sys.argv[5:]

if not os.path.isfile(db_path):
    print("Database not found.", file=sys.stderr)
    sys.exit(1)

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
except Exception as e:
    print(f"Cannot open database: {e}", file=sys.stderr)
    sys.exit(1)

# Get available tables
available_tables = set()
try:
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
        available_tables.add(row[0])
except Exception:
    pass

results = []

# Search across tables for matching content
for table in available_tables:
    try:
        cursor = conn.execute(f"PRAGMA table_info({table})")
        columns = [row[1] for row in cursor.fetchall()]

        text_cols = [c for c in columns if any(k in c.lower() for k in
                     ("content", "text", "message", "summary", "body"))]
        if not text_cols:
            continue

        # Build WHERE clause
        conditions = []
        params = []

        if chat_id:
            chat_cols = [c for c in columns if any(k in c.lower() for k in ("chat", "thread", "channel"))]
            if chat_cols:
                conditions.append(f"{chat_cols[0]} = ?")
                params.append(chat_id)

        if session_key:
            session_cols = [c for c in columns if any(k in c.lower() for k in ("session", "conversation"))]
            if session_cols:
                conditions.append(f"{session_cols[0]} LIKE ?")
                params.append(f"%{session_key}%")

        for term in terms:
            for col in text_cols:
                term_conditions = list(conditions)
                term_params = list(params)
                term_conditions.append(f"{col} LIKE ?")
                term_params.append(f"%{term}%")

                where = " AND ".join(term_conditions) if term_conditions else "1=1"
                query = f"SELECT * FROM {table} WHERE {where} ORDER BY rowid DESC LIMIT ?"
                term_params.append(limit)

                for row in conn.execute(query, term_params):
                    row_dict = dict(row)
                    content = row_dict.get(col, "")
                    if content:
                        results.append({
                            "source": f"stitch:{table}",
                            "term": term,
                            "snippet": str(content)[:300],
                        })
    except Exception:
        continue

conn.close()

if results:
    print(f"Cross-session matches ({len(results)}):")
    for r in results:
        print(f"  [{r['term']}] ({r['source']}) {r['snippet'][:200]}")
else:
    print("No cross-session matches found.")
PY
