# Integration Guide

## Overview
Ironclad Memory is framework-agnostic. It works with any AI agent system that can run shell commands. This guide shows how to wire it into your agent's system prompt or configuration.

## Quick Integration

### 1. Initialize

```bash
cd /path/to/your/workspace
export IRONCLAD_WORKSPACE="$(pwd)"
path/to/ironclad-memory/scripts/ironclad.sh init
```

### 2. Add to System Prompt / AGENTS.md

Add these rules to your agent's operating instructions:

```markdown
## Memory Discipline

### Before Context Loss
Before compaction, session end, or any likely context loss, run:
ironclad flush --commitment "..." --inflight "..." --blocker "..." --next "..."

### Before Status Answers
Before any answer claiming status, completion, or what changed:
ironclad retrieve --claim "..." --term "..." --term "..."

### Commitment Tracking
- ironclad ask "<summary>"      — New commitment
- ironclad start "<summary>"    — Begin work
- ironclad done "<summary>"     — Complete (with note)
- ironclad block "<summary>"    — Blocked
- ironclad waiting "<summary>"  — Needs user input

### Daily Review
Run at session start: ironclad review
Run periodically: ironclad escalate
```

### 3. Validate

```bash
ironclad doctor
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IRONCLAD_WORKSPACE` | Auto-detect | Base workspace directory |
| `IRONCLAD_MEMORY_DIR` | `$WORKSPACE/memory` | Where daily memory files are stored |
| `IRONCLAD_LEDGER_PATH` | `$WORKSPACE/data/commitments/ledger.jsonl` | Commitment ledger file |
| `IRONCLAD_TIMEZONE` | `UTC` | Timezone for timestamps |
| `IRONCLAD_LCM_ADAPTER` | `0` | Enable LCM adapter (set to `1`) |
| `IRONCLAD_LCM_DB` | — | Path to LCM database file |
| `IRONCLAD_STITCH_DB` | — | Path to cross-session stitch database |

## Framework-Specific Examples

### OpenClaw

In your workspace `AGENTS.md`:

```markdown
## Memory Discipline

- Before compaction: run `ironclad flush` with active state
- Before status answers: run `ironclad retrieve`
- Track commitments with `ironclad ask/start/done/block/waiting`
- Daily review: `ironclad review`
- Stale item check: `ironclad escalate`
```

### Claude Code / Codex

Add to `CLAUDE.md` or project instructions:

```markdown
Before answering status questions, run:
  scripts/ironclad.sh retrieve --claim "<your claim>" --term "<keyword>"

Before session end, run:
  scripts/ironclad.sh flush --commitment "..." --next "..."
```

### Custom Agents

Any agent that can execute shell commands can use Ironclad. The key integration points are:

1. **Session start** → `ironclad review`
2. **Before status answers** → `ironclad retrieve --claim "..." --term "..."`
3. **Before context loss** → `ironclad flush --commitment "..." --next "..."`
4. **On new tasks** → `ironclad ask "..."`
5. **On completion** → `ironclad done "..." --note "..."`
6. **Periodically** → `ironclad escalate`

## Data Layout

After initialization:

```
workspace/
├── .ironclad/                    # Marker directory
├── memory/
│   ├── 2026-03-25.md            # Daily memory files
│   └── 2026-03-26.md
├── data/
│   ├── commitments/
│   │   └── ledger.jsonl          # Commitment ledger
│   └── escalations/
│       ├── 2026-03-25.md         # Escalation reports
│       └── rot-report.json       # Latest rot analysis
└── MEMORY.md                     # Strategic memory (optional, user-maintained)
```

## Adapter Development

To create a custom retrieval adapter:

1. Create a script in `adapters/` that accepts search terms as arguments
2. Output matching evidence in the format: `  - [term] (source) snippet text`
3. Set the appropriate environment variable to enable it
4. The retrieve script will call your adapter when configured

Example adapter skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail
# my-adapter.sh — Custom retrieval source

for term in "$@"; do
  # Search your data source for $term
  # Print matches in format:
  #   - [$term] (my-source) matched text here
  echo "  - [$term] (my-source) example match"
done
```
