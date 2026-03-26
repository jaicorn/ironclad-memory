# Memory Flush Protocol

## Purpose
When context is about to compact, rotate, or disappear, active work must survive. A flush is mandatory before any session ends, before handing work back after a long execution block, and whenever compaction risk is visible.

This protocol preserves:
- Active commitments
- In-flight work
- Blockers and risks
- System/deployment/runtime state
- Who is expecting what next
- The single next recovery step

If it matters after context loss, it gets flushed.

## Trigger Conditions (flush immediately)
Run a memory flush when any of these are true:

1. The model warns about compaction, truncation, low context, or session pressure
2. A long tool/coding/browser sequence is wrapping up
3. A sub-agent was spawned, completed, failed, or is still pending
4. Work changed real system state (deploy, config, auth, cron, database, file mutation, new artifact)
5. The user is expecting a follow-up, result, retry, or verification
6. Status is currently living only in short-term context

## Output Location
Write the flush to: `memory/YYYY-MM-DD.md`

If the file does not exist, create it. Append — never overwrite.

## Required Structure

```md
## Memory Flush — HH:MM TZ

### Active commitments
- ...

### In-flight work
- ...

### Blockers / risks
- ...

### System state
- ...

### Pending expectations
- ...

### Next recovery step
- ...
```

### Rules
- Be concrete, not poetic
- Include paths, session IDs, commit hashes, artifact names, commands when they matter
- Mark unknowns as unknown
- Prefer bullets over paragraphs
- If nothing belongs in a section, write `- None.`

## Quality Bar
A good flush lets the next session answer all of these without guessing:
- What did we promise?
- What is still moving?
- What is blocked?
- What changed on the machine / repo / deployment?
- What does the user expect next?
- What is the single next move?

## Fast Path

```bash
ironclad flush \
  --commitment "Deploy v2.1 by Friday" \
  --inflight "Database migration running" \
  --blocker "Auth token expired" \
  --state "Repo at commit abc123" \
  --expectation "User expects deployment status" \
  --next "Verify migration completes"
```

Add `--ledger` to also sync commitments/blockers to the commitment ledger.

## Recovery Rule
If compaction already happened and state is fuzzy:
1. Reconstruct from artifacts, logs, git, and session evidence
2. Write a recovery flush immediately
3. Label uncertainties explicitly instead of hallucinating continuity

## Minimum Standard
Before context can die, preserve:
- The promise
- The current state
- The blocker
- The next move

Anything less is memory negligence.
