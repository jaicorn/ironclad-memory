# LCM Subagent Retrieval Workaround

## Problem

`lcm_expand_query` and `lcm_expand` fail from subagent context with errors like:
- "conversation ID" errors
- "cross-conversation" access denied
- Empty results despite known content existing

**Root cause:** Subagents have separate conversation IDs and cannot access main-session LCM summaries via `lcm_expand_query`. This is a known architectural limitation — subagent sessions are isolated from the parent session's conversation history.

## Workaround: grep → describe Chain

This chains two working LCM tools to simulate `lcm_expand_query`:

### Step 1 — Search with lcm_grep

```
lcm_grep(pattern="<search terms>", mode="full_text")
```

- Try multiple pattern variants for better coverage
- Use `references/lcm-patterns.json` for pre-tested patterns on known topics
- Set `allConversations: true` if needed

### Step 2 — Inspect with lcm_describe

```
lcm_describe(id="sum_xxx")
```

For each relevant summary ID returned by grep:
- Call `lcm_describe` to get the full summary content
- File IDs (`file_xxx`) also work for stored file metadata

### Step 3 — Combine results

- Merge the describe outputs to build a comprehensive answer
- Cross-reference with file-based sources for verification
- Apply the cross-verification rule: 2+ sources for status-critical answers

## Example

```
# Step 1: Find summaries
lcm_grep(pattern="deployment status", mode="full_text")
→ Returns matches with IDs: sum_abc123, sum_def456

# Step 2: Inspect each
lcm_describe(id="sum_abc123")
→ Returns: summary content, lineage, token counts

lcm_describe(id="sum_def456")
→ Returns: summary content, lineage, token counts

# Step 3: Combine into answer
"Based on sum_abc123 and sum_def456: deployment completed at..."
```

## Fallback Chain

If the grep→describe workaround also fails or returns insufficient data:

1. **Direct file reads** — Check `MEMORY.md`, `memory/*.md`, `data/memory-index.md`
2. **FTS5 search** — `scripts/fts-search.sh "<query>"`
3. **LCM pattern lookup** — `scripts/lcm-search.sh "<query>"` (uses pre-tested patterns)
4. **Semantic search** — if available
5. **Report with qualifier** — state what was found from file-based sources with appropriate confidence level

## When This Applies

- Any subagent spawned from main session (depth 1+)
- Worker agents doing research or analysis tasks
- Cron-triggered agents that need historical context
- Any non-main session attempting LCM expansion

## When This Does NOT Apply

- Main session — use `lcm_expand_query` directly
- Direct file reads — always work regardless of session context
- `lcm_grep` itself — works from all contexts
