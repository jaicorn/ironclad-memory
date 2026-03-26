# Memory Retrieval Protocol

## Purpose
Memory is not a scrapbook. It is retrieval infrastructure for operational truth.

Before giving a status-critical answer, retrieve evidence from the canonical record instead of relying on short-term context, vibes, or whatever feels recently true.

## When Retrieval Is Mandatory
Run structured retrieval before any answer that claims or implies:
1. Current status
2. Completion / delivery
3. What changed
4. Whether something is blocked or pending
5. What the user is expecting next
6. What a sub-agent, script, or process supposedly did
7. What was previously said or agreed

If the answer would contain words like `done`, `sent`, `finished`, `current`, `latest`, `still`, `already`, `pending`, `waiting on`, or `exactly`, retrieval is mandatory.

## Canonical Source Order
Check sources in this order:

1. **Direct artifact / observable state** — file exists, command output, visible result
2. **Operational memory** — MEMORY.md, today's daily log, yesterday's daily log
3. **Commitment ledger** — structured commitment/action/blocker state
4. **Relevant domain files** — implementation reports, status docs, JSON state
5. **Short-term model context** — only as a search lead, not a source of truth

## Retrieval Workflow

### Step 1 — Define the claim
Write down the exact claim you are about to make.

### Step 2 — Break the claim into search terms
List nouns, IDs, dates, paths, artifact names, or people involved.

### Step 3 — Retrieve from canonical sources
Search the sources above and collect concrete evidence.

### Step 4 — Build an evidence ledger
```
Claim:
Sources checked:
Evidence:
Unknowns:
Answer allowed: [verified yes / verified no / mixed / unknown]
```

### Step 5 — Speak only to the evidence
- If verified: answer directly and cite the basis
- If mixed: say exactly what is verified vs not
- If unknown: say unknown and keep checking
- Never round uncertainty up into confidence

## Fast Path

```bash
ironclad retrieve \
  --claim "Is the deployment complete?" \
  --term "deployment" \
  --term "v2.1"
```

Add `--path <file>` for additional sources. Use `--json` for machine-readable output.

## Open Loops in Retrieval
The retrieval script automatically appends an open loops summary at the end of every pass. This surfaces active commitments alongside evidence for the claim being checked.

## Write-Back Rule
If retrieval uncovers a status change that would be painful to lose, write it back into daily memory immediately.

## Operational Rule
Do not answer status-critical questions from memory alone. Retrieve first. Then answer.

If retrieval was skipped, the answer is procedurally invalid even if it happened to be correct.
