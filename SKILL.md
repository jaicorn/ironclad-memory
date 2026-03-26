---
name: ironclad-memory
version: 1.1.0
description: "Activate when: (1) context is compacting or session is ending — run memory flush, (2) about to answer a status question — run retrieval gate, (3) user asks for something trackable — capture commitment, (4) task completes — record with proof, (5) session starts — run daily review, (6) periodic check for stale items. Memory integrity system that prevents hallucinated status, lost commitments, and silent task rot."
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

See: [references/retrieval-protocol.md](references/retrieval-protocol.md)

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

## Installation

```bash
ironclad init
```

See: [references/integration-guide.md](references/integration-guide.md)
