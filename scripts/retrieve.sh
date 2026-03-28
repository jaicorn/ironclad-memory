#!/usr/bin/env bash
set -euo pipefail

# retrieve.sh — Retrieval gate.
# Searches canonical memory sources and prints an evidence ledger
# for status-critical answers. Blocks guessing.

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
cd "$WORKSPACE"

claim=""
days=2
terms=()
extra_paths=()
json_output=0

usage() {
  cat <<'EOF'
Usage:
  retrieve.sh --claim TEXT --term TEXT [--term TEXT ...] [options]

Search canonical memory sources and print a retrieval brief.

Options:
  --claim TEXT            Exact claim/question to verify (required)
  --term TEXT             Search term (repeatable, at least one required)
  --path PATH             Extra file or directory to search (repeatable)
  --days N                Number of recent daily memory files (default: 2)
  --json                  Output as JSON instead of markdown
  -h, --help              Show help

Environment:
  IRONCLAD_WORKSPACE      Base workspace directory
  IRONCLAD_MEMORY_DIR     Memory directory
  IRONCLAD_LCM_ADAPTER    Set to 1 to enable LCM adapter

Example:
  retrieve.sh \
    --claim "Is the deployment complete?" \
    --term "deployment" \
    --term "v2.1"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claim)  claim="$2"; shift 2 ;;
    --term)   terms+=("$2"); shift 2 ;;
    --path)   extra_paths+=("$2"); shift 2 ;;
    --days)   days="$2"; shift 2 ;;
    --json)   json_output=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$claim" ]]; then
  echo "Error: --claim is required" >&2
  exit 1
fi

if [[ ${#terms[@]} -eq 0 ]]; then
  echo "Error: at least one --term is required" >&2
  exit 1
fi

# Build source list
MEMORY_DIR="${IRONCLAD_MEMORY_DIR:-$WORKSPACE/memory}"
sources=()
[[ -f MEMORY.md ]] && sources+=("MEMORY.md")

if [[ -d "$MEMORY_DIR" ]]; then
  while IFS= read -r file; do
    sources+=("$file")
  done < <(find "$MEMORY_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | tail -n "$days")
fi

for p in "${extra_paths[@]+"${extra_paths[@]}"}"; do
  if [[ -n "$p" && -e "$p" ]]; then
    sources+=("$p")
  fi
done

# Deduplicate
unique_sources=()
for src in "${sources[@]+"${sources[@]}"}"; do
  skip=0
  for seen in "${unique_sources[@]+"${unique_sources[@]}"}"; do
    if [[ "$seen" == "$src" ]]; then
      skip=1
      break
    fi
  done
  [[ $skip -eq 0 ]] && unique_sources+=("$src")
done

# Search and collect evidence
if [[ $json_output -eq 1 ]]; then
  # JSON output mode
  python3 - "$claim" "$WORKSPACE" "$days" "$json_output" "${terms[@]}" -- "${unique_sources[@]+"${unique_sources[@]}"}" <<'PY'
import json, sys, os

args = sys.argv[1:]
claim = args[0]
workspace = args[1]
days = int(args[2])
json_mode = args[3] == "1"

sep_idx = args.index("--")
terms = args[4:sep_idx]
sources = args[sep_idx+1:]

ledger_path = os.environ.get("IRONCLAD_LEDGER_PATH",
    os.path.join(workspace, "data", "commitments", "ledger.jsonl"))

evidence = []
sources_checked = list(sources)

# Search file sources
for src in sources:
    if not os.path.exists(src):
        continue
    try:
        if os.path.isdir(src):
            import subprocess
            for term in terms:
                result = subprocess.run(
                    ["grep", "-RniF", "--", term, src],
                    capture_output=True, text=True, timeout=10
                )
                for line in result.stdout.strip().split("\n")[:5]:
                    if line:
                        evidence.append({"source": src, "term": term, "match": line})
        else:
            with open(src, 'r', encoding='utf-8', errors='replace') as f:
                content_lines = f.readlines()
            for term in terms:
                term_lower = term.lower()
                for i, line in enumerate(content_lines):
                    if term_lower in line.lower():
                        evidence.append({
                            "source": src,
                            "term": term,
                            "match": f"{i+1}:{line.rstrip()}"
                        })
                        if len([e for e in evidence if e["source"] == src and e["term"] == term]) >= 5:
                            break
    except Exception:
        pass

# Search ledger
if os.path.isfile(ledger_path):
    sources_checked.append(ledger_path)
    try:
        with open(ledger_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                text = json.dumps(entry).lower()
                for term in terms:
                    if term.lower() in text:
                        evidence.append({
                            "source": "ledger",
                            "term": term,
                            "match": f"{entry['id']} {entry['status']} {entry['priority']} \"{entry['summary']}\""
                        })
    except Exception:
        pass

result = {
    "claim": claim,
    "terms": terms,
    "sources_checked": sources_checked,
    "evidence": evidence,
    "evidence_found": len(evidence) > 0,
    "unknowns": [],
    "answer_allowed": "unknown" if not evidence else "review_evidence",
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
else
  # Markdown output mode
  printf '# Retrieval Brief\n\n'
  printf 'Claim:\n- %s\n\n' "$claim"
  printf 'Terms:\n'
  for term in "${terms[@]}"; do
    printf -- '- %s\n' "$term"
  done
  printf '\nSources checked:\n'
  if [[ ${#unique_sources[@]} -eq 0 ]]; then
    printf -- '- None found.\n'
  else
    for src in "${unique_sources[@]}"; do
      printf -- '- %s\n' "$src"
    done
  fi
  printf '\n'

  # Check for tier support
  TIER_SCRIPT="$SCRIPT_DIR/tier.sh"
  tier_enabled=0
  if [[ -x "$TIER_SCRIPT" ]]; then
    tier_enabled=1
  fi

  printf 'Evidence:\n'
  found_any=0
  for src in "${unique_sources[@]+"${unique_sources[@]}"}"; do
    printed_header=0

    # Determine tier if available
    src_tier=""
    if [[ $tier_enabled -eq 1 && -f "$src" ]]; then
      src_tier="$("$TIER_SCRIPT" get "$src" 2>/dev/null || echo "hot")"
    fi

    # COLD files: one-line reference, search only if term matches filename
    if [[ "$src_tier" == "cold" ]]; then
      bn="$(basename "$src")"
      size_bytes="$(wc -c < "$src" 2>/dev/null | tr -d ' ' || echo 0)"
      for term in "${terms[@]+"${terms[@]}"}"; do
        if echo "$bn" | grep -qiF -- "$term" 2>/dev/null; then
          printf -- '- %s [COLD — %s bytes, filename match only]\n' "$src" "$size_bytes"
          printed_header=1
          found_any=1
          break
        fi
        # Still grep but cap at 2 matches for cold files
        cold_matches="$(grep -niF -- "$term" "$src" 2>/dev/null | head -n 2 || true)"
        if [[ -n "$cold_matches" ]]; then
          if [[ $printed_header -eq 0 ]]; then
            printf -- '- %s [COLD — preview only]\n' "$src"
            printed_header=1
          fi
          found_any=1
          while IFS= read -r line; do
            [[ -n "$line" ]] && printf '  - [%s] %s\n' "$term" "$line"
          done <<< "$cold_matches"
        fi
      done
      continue
    fi

    # WARM files: search with preview cap (5 matches per term)
    # HOT files: full search (5 matches per term)
    match_limit=5
    if [[ "$src_tier" == "warm" ]]; then
      match_limit=3
    fi

    for term in "${terms[@]+"${terms[@]}"}"; do
      if [[ -d "$src" ]]; then
        matches="$(grep -RniF -- "$term" "$src" 2>/dev/null | head -n "$match_limit" || true)"
      else
        matches="$(grep -niF -- "$term" "$src" 2>/dev/null | head -n "$match_limit" || true)"
      fi
      if [[ -n "$matches" ]]; then
        if [[ $printed_header -eq 0 ]]; then
          if [[ -n "$src_tier" && "$src_tier" != "hot" ]]; then
            printf -- '- %s [%s]\n' "$src" "$(echo "$src_tier" | tr '[:lower:]' '[:upper:]')"
          else
            printf -- '- %s\n' "$src"
          fi
          printed_header=1
        fi
        found_any=1
        while IFS= read -r line; do
          [[ -n "$line" ]] && printf '  - [%s] %s\n' "$term" "$line"
        done <<< "$matches"
      fi
    done
  done

  # Search ledger
  LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"
  if [[ -s "$LEDGER" ]]; then
    printf -- '- %s\n' "$LEDGER"
    ledger_hits="$(python3 - "$LEDGER" "${terms[@]}" <<'LEDGER_PY'
import json, sys

ledger_path = sys.argv[1]
terms = [t.lower() for t in sys.argv[2:]]
with open(ledger_path, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = json.dumps(entry).lower()
        matched = [t for t in terms if t in text]
        if matched:
            terms_str = ", ".join(matched)
            due = f" due={entry.get('due_date','')}" if entry.get('due_date') else ""
            print(f"  - [{terms_str}] {entry['id']} {entry['status']} {entry['priority']} \"{entry['summary']}\"{due}")
LEDGER_PY
    )" || true
    if [[ -n "$ledger_hits" ]]; then
      printf '%s\n' "$ledger_hits"
      found_any=1
    fi
  fi

  if [[ $found_any -eq 0 ]]; then
    printf -- '- No matches found in searched files.\n'
  fi

  # --- FTS5 search layer ---
  FTS_DB="${IRONCLAD_FTS_DB:-$WORKSPACE/data/fts5-index.db}"
  FTS_SCRIPT="$SCRIPT_DIR/fts-search.sh"
  if [[ -f "$FTS_DB" && -x "$FTS_SCRIPT" ]]; then
    # Build a combined FTS query from all terms
    fts_query=""
    for term in "${terms[@]}"; do
      [[ -n "$fts_query" ]] && fts_query="$fts_query OR "
      fts_query="$fts_query$term"
    done
    fts_output="$("$FTS_SCRIPT" "$fts_query" --limit 5 2>/dev/null || true)"
    if [[ -n "$fts_output" ]] && ! echo "$fts_output" | grep -qF "ERROR"; then
      printf '\nFTS5 search results:\n%s\n' "$fts_output"
      found_any=1
    fi
  fi

  # --- LCM pattern search layer ---
  LCM_SEARCH="$SCRIPT_DIR/lcm-search.sh"
  if [[ -x "$LCM_SEARCH" ]]; then
    # Use the first term as the LCM query (most specific)
    lcm_query="${terms[0]}"
    if [[ ${#terms[@]} -gt 1 ]]; then
      lcm_query="${terms[*]}"
    fi
    lcm_output="$("$LCM_SEARCH" "$lcm_query" 2>/dev/null || true)"
    if [[ -n "$lcm_output" ]]; then
      printf '\nLCM pattern search:\n%s\n' "$lcm_output"
    fi
  fi

  # Optional LCM adapter
  if [[ "${IRONCLAD_LCM_ADAPTER:-0}" == "1" ]]; then
    LCM_ADAPTER="$SCRIPT_DIR/../adapters/lcm-adapter.sh"
    if [[ -x "$LCM_ADAPTER" ]]; then
      lcm_output="$("$LCM_ADAPTER" "${terms[@]}" 2>/dev/null || true)"
      if [[ -n "$lcm_output" ]]; then
        printf '\nLCM retrieval:\n%s\n' "$lcm_output"
      fi
    fi
  fi

  # Open loops summary
  LOOPS_SCRIPT="$SCRIPT_DIR/loops.sh"
  if [[ -x "$LOOPS_SCRIPT" ]] && [[ -s "${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}" ]]; then
    loops_output="$("$LOOPS_SCRIPT" --max 10 2>/dev/null || true)"
    if [[ -n "$loops_output" ]] && ! echo "$loops_output" | grep -qF "Ledger is empty"; then
      printf '\nOpen loops (active commitments/blockers/actions):\n'
      printf '%s\n' "$loops_output"
      printf '\n'
    fi
  fi

  printf '\nUnknowns:\n- Fill this in after reviewing the evidence above.\n\n'
  printf 'Answer allowed:\n- Choose one: verified yes / verified no / mixed / unknown\n'
fi
