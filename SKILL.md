---
name: ironclad-memory
version: 2.0.0
description: "Activate when: (1) context is compacting or session is ending — run memory flush, (2) about to answer a status question — run retrieval gate, (3) user asks for something trackable — capture commitment, (4) task completes — record with proof, (5) session starts — run daily review, (6) periodic check for stale items. Memory integrity system that prevents hallucinated status, lost commitments, and silent task rot. v2.0 adds multi-path retrieval (FTS5, LCM patterns, memory index) — benchmarked at 99.3% accuracy on 150-question benchmark."
---

# Ironclad Memory

Memory integrity system for AI agents. Other memory systems store and retrieve data. Ironclad ensures the agent is honest about what it knows.

## Trigger Conditions

Activate this skill when any of the following are true:

1. **Context compaction risk** — The model warns about truncation, low context, or session pressure. Run a memory flush immediately.
2. **Status-critical answer** — The agent is about to claim something is done, pending, blocked, current, or changed. Run retrieval before answering.
3. **New commitment** — The user asks for something trackable. Capture it in the ledger.
4. **Task completion** — Work finishes. Record it with proof.
5. **Session start** — Run a daily review to surface stale items and blockers.
6. **Periodic hygiene** — Run escalation to catch rotting items.

## Usage

### Memory Flush (before context loss)

```bash
scripts/ironclad.sh flush \
  --commitment "Deploy v2.1 by Friday" \
  --inflight "Database migration running" \
  --blocker "Auth token expired" \
  --next "Verify migration completes"
```

See: [references/flush-protocol.md](references/flush-protocol.md)

### Evidence Retrieval (before status answers)

```bash
scripts/ironclad.sh retrieve \
  --claim "Is the deployment complete?" \
  --term "deployment" \
  --term "v2.1"
```

Retrieval automatically uses multiple search paths when available:
- Grep-based keyword search (always available)
- FTS5 full-text search (if index exists)
- LCM pattern search (if patterns file exists)
- Memory tier awareness (if tier.sh is present)

See: [references/retrieval-protocol.md](references/retrieval-protocol.md) and [references/retrieval-cascade.md](references/retrieval-cascade.md)

### Multi-Path Retrieval (v2.0)

Ironclad v2.0 adds a 5-layer retrieval cascade that improved accuracy from 85% to 99.3% on 150 fresh, unbiased questions:

**Layer 1 — Instant:** MEMORY.md + daily memory files + memory-index.md grep
**Layer 2 — Fast Search:** FTS5 full-text search + LCM conversation grep
**Layer 3 — Semantic:** Embedding/similarity search (if available)
**Layer 4 — Deep Expansion:** LCM cross-session expansion
**Layer 5 — Direct Reads:** Targeted file reads based on evidence from layers 1-4

```bash
# FTS5 full-text search
scripts/ironclad.sh search "deployment status"
scripts/ironclad.sh search "migration" --limit 20 --json

# Build/rebuild search indexes
scripts/ironclad.sh index

# LCM pattern-based conversation search
scripts/ironclad.sh patterns "deployment status"
```

See: [references/retrieval-cascade.md](references/retrieval-cascade.md)

#### FTS5 Search

Full-text search over workspace markdown files using SQLite FTS5 with porter stemming. Splits files by section headers for granular results.

```bash
# Build the index (run nightly or after major memory writes)
scripts/build-fts-index.sh

# Search
scripts/fts-search.sh "server deployment" --limit 10
scripts/fts-search.sh "budget expense" --json

# Rebuild (cron-friendly wrapper)
scripts/rebuild-fts-index.sh --quiet
```

#### Memory Index

Builds a greppable concept→file index for fast lookups:

```bash
# Build the index
scripts/memory-index.sh

# Use it
grep -i "deployment" data/memory-index.md
grep -i "budget" data/memory-index.md
```

#### LCM Pattern Search

Topic-aware search across compacted conversation history:

```bash
# Search with pre-tested patterns
scripts/lcm-search.sh "deployment status"

# Outputs: search plan with lcm_grep calls + local file matches
```

Customize patterns in `references/lcm-patterns.json`.

See: [references/lcm-subagent-workaround.md](references/lcm-subagent-workaround.md) for subagent retrieval limitations.

### Commitment Tracking

```bash
scripts/ironclad.sh ask "Pull the January receipt"
scripts/ironclad.sh start "Pull the January receipt"
scripts/ironclad.sh done "Pull the January receipt" --note "Uploaded to Drive"
scripts/ironclad.sh block "OAuth token expired for Gmail"
scripts/ironclad.sh waiting "Need approval on budget"
scripts/ironclad.sh defer "Refactor auth module" --until 2026-04-01
scripts/ironclad.sh drop "Old migration script" --note "No longer needed"
```

See: [references/ledger-protocol.md](references/ledger-protocol.md)

### Memory Tiers (token cost reduction)

```bash
scripts/ironclad.sh tier classify                   # Scan and classify all memory files
scripts/ironclad.sh tier show                       # Show current HOT/WARM/COLD breakdown
scripts/ironclad.sh tier read memory/2026-03-20.md  # Read with tier-appropriate depth
```

Files are classified by age: HOT (<24h, full read), WARM (1-7d, 500-char preview), COLD (>7d, one-line reference). Retrieval automatically respects tiers — cold files get minimal scans, warm get capped results. Run `tier classify` nightly via cron.

### Daily Review

```bash
scripts/ironclad.sh review      # Full review: stale items, blockers, in-flight
scripts/ironclad.sh status      # Quick counts
scripts/ironclad.sh escalate    # Decay watchdog with tier system
```

### System Validation

```bash
scripts/ironclad.sh doctor      # Check installation health
scripts/ironclad.sh doctor --fix  # Auto-fix what's possible
```

## Prerequisites

- Python 3.6+
- jq
- bash 4+ (macOS ships with zsh, but bash 4+ is available via default install on most systems)
- sqlite3 (for FTS5 search — included on most systems)

## Installation

```bash
ironclad init
```

See: [references/integration-guide.md](references/integration-guide.md)
