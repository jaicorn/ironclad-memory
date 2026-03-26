# Commitment Ledger Protocol

## Purpose
Every commitment, blocker, and tracked action lives in a JSONL ledger with full lifecycle tracking. Nothing gets lost silently. Nothing gets marked "done" without proof.

## Status Flow

```
captured → in_flight → done_unverified → verified_done
              ↕              ↕
           blocked      (can verify at any time)
           awaiting_user
           deferred
           dropped
```

Any status can transition to `blocked`, `awaiting_user`, `deferred`, or `dropped` at any point.

### Status Definitions

| Status | Meaning |
|--------|---------|
| `captured` | Tracked but not started |
| `in_flight` | Actively being worked on |
| `blocked` | Stuck on a dependency |
| `awaiting_user` | Needs user input/decision/approval |
| `deferred` | Intentionally paused until later |
| `dropped` | No longer relevant (killed) |
| `done_unverified` | Claimed complete, no proof attached |
| `verified_done` | Complete with artifact or message proof |
| `archived` | Old closed item (via gc) |

## Entry Types

| Type | Use For |
|------|---------|
| `commitment` | User asked for something trackable |
| `action` | Work item the agent is driving |
| `blocker` | Something blocking progress |
| `question` | Needs an answer before proceeding |

## Priority Levels

| Priority | Meaning |
|----------|---------|
| `p0` | Active fire — drop everything |
| `p1` | Must do today / this session |
| `p2` | Should do soon |
| `p3` | Nice to have / backlog |

## Lifecycle Commands

```bash
# Create
ironclad ask "Deploy the new dashboard"
ironclad block "OAuth token expired"
ironclad waiting "Need approval on STR budget"

# Progress
ironclad start "Deploy the new dashboard"
ironclad done "Deploy the new dashboard" --note "Deployed to prod, verified live"

# Pause / Kill
ironclad defer "Refactor auth module" --until 2026-04-01
ironclad drop "Old migration script" --note "No longer needed"

# Review
ironclad review
ironclad status
ironclad escalate
```

## Verification Gate

The difference between `done_unverified` and `verified_done` is proof.

```bash
# Without proof → done_unverified
ironclad done "Deploy dashboard" --note "Deployed"

# With proof → verified_done (via ledger directly)
scripts/ledger.sh verify \
  --id c-20260325-abc123 \
  --artifact-path /path/to/deploy-log.txt \
  --note "Deployment log confirms v2.1 live"
```

An agent should not report completion to the user while an item is `done_unverified`. Either verify it first, or disclose that it hasn't been verified.

## Dedup and Reopening
The capture system uses fuzzy matching to prevent duplicate entries. If a deferred or dropped item is re-asked, it's automatically reopened instead of creating a duplicate.

## History
Every status transition is recorded in the entry's `history` array with timestamp and note. This creates a full audit trail.

## Garbage Collection
Old closed entries can be archived:

```bash
scripts/ledger.sh gc --days 30          # Archive entries closed 30+ days ago
scripts/ledger.sh gc --days 30 --dry-run  # Preview what would be archived
```

## Atomic Writes
All ledger mutations use file locking (`fcntl.LOCK_EX`) and atomic temp-file replacement to prevent corruption from concurrent access.
