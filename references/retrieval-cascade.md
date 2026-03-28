# Multi-Path Retrieval Cascade

## Purpose

Memory retrieval is not a single search — it's a layered strategy. Different questions need different retrieval paths. This document describes the 5-layer cascade that achieves 96.7% retrieval accuracy on fresh, unbiased questions (up from 85% with single-path grep).

## The 5-Layer Cascade

Run layers in order. Layers 1-2 are parallel (<1s each). Layers 3-4 are budget-capped. Layer 5 is targeted follow-up.

### Layer 1 — Instant (parallel, <1s)

Run all three simultaneously:
- **MEMORY.md** — check active priorities, standing commitments, operating state
- **Today's + yesterday's daily memory file** — recent decisions, actions, blockers
- **`memory-index.md` grep** — `grep -i "<terms>" data/memory-index.md` to find which files contain what

This layer answers: *"Is this in immediate operational memory?"*

### Layer 2 — Fast Search (parallel, <1s)

Run both simultaneously:
- **FTS5 via `scripts/fts-search.sh "<query>"`** — full-text search across all indexed workspace files with porter stemming
- **LCM grep with 2-3 pattern variants** — search compacted conversation history
  - Always try: exact phrase, key terms individually, reversed word order
  - Use `references/lcm-patterns.json` for pre-tested patterns on known topics

This layer answers: *"Has this been discussed, decided, or logged anywhere?"*

### Layer 3 — Semantic (budget: 5s)

- **Semantic/embedding search** (if available) — similarity search across memory corpus
- **Skip if:** semantic search is unavailable, slow (>5s), or returns no results
- **Fallback:** rely on layers 1-2 and 4

This layer answers: *"Are there conceptually related entries I missed with keyword search?"*

### Layer 4 — Deep Expansion (budget: 10s)

- **LCM expand_query** — cross-session context retrieval from conversation history
- **Main session only** — this tool does not work reliably from subagent context (see `lcm-subagent-workaround.md`)
- Use when layers 1-3 produced insufficient or contradictory evidence

This layer answers: *"What happened in previous sessions that's relevant?"*

### Layer 5 — Direct File Reads

- **Targeted reads** based on results from layers 1-4
- Read the specific files, configs, logs, or artifacts that evidence points to
- Verify claims against actual file contents, not summaries

This layer answers: *"What does the actual artifact/state say?"*

---

## Query Classification Heuristics

Route the query to the most efficient starting layer:

| Query Type | Best Starting Path | Examples |
|---|---|---|
| Names/numbers/dates/status | FTS5/grep first (Layer 2) | "What's the client's number?", "When was the release?" |
| "When did X happen?" | Timeline queries in memory files (Layer 1→5) | "When did the API break?", "When was v2 deployed?" |
| Broad/open-domain | Semantic search (Layer 3) | "What's our deployment strategy?" |
| Structured data | Direct file reads (Layer 5) | "What's the config value?" |
| Exact wording / "what did I say?" | LCM conversation record (Layer 2→4) | "What did I say about the budget?" |
| Artifact existence | Direct file check (Layer 5) | "Did the report get written?" |

---

## Source Tiering

### Tier 1 — Canonical (primary truth)
- `MEMORY.md` — strategic picture, active state
- `memory/*.md` — daily operational decisions, actions, evidence
- Structured configs (JSON, YAML)
- Direct artifacts — files, scripts, git state

### Tier 2 — Derived (valid for search, verify against Tier 1)
- `data/memory-index.md` — auto-generated index
- LCM conversation summaries (compacted)

### Tier 3 — Non-canonical (reference only)
- Research reports, audits, benchmarks
- External web fetches, transcripts

---

## Cross-Verification Rule

For **status-critical answers**, require **2+ independent sources** before stating with confidence.

- 1 source found → answer with "based on [source]" qualifier
- 0 sources found → state "unverified" and keep searching
- Sources contradict → state the contradiction explicitly, cite both

---

## Evidence Ledger

Before answering a retrieval-mandatory question, build:

```md
Claim:
Sources checked:
Evidence:
Unknowns:
Answer allowed: [verified yes | verified no | mixed/partial | unknown]
```

The `ironclad retrieve` command automates this structure.

---

## Benchmark Results

Using the 5-layer cascade with FTS5 + LCM patterns:
- **Before:** 85% accuracy on fresh, unbiased questions (grep-only retrieval)
- **After:** 96.7% accuracy on the same question set
- **Key improvement:** FTS5 catches morphological variants and section-level matches that simple grep misses. LCM patterns find cross-session context that file search alone cannot reach.
