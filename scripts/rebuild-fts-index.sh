#!/usr/bin/env bash
# rebuild-fts-index.sh — Standalone FTS5 index rebuild for cron/nightly use
# Usage: scripts/rebuild-fts-index.sh [--quiet]
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
QUIET=false

[[ "${1:-}" == "--quiet" ]] && QUIET=true

if $QUIET; then
  bash "$SCRIPT_DIR/build-fts-index.sh" --quiet
else
  bash "$SCRIPT_DIR/build-fts-index.sh"
fi
