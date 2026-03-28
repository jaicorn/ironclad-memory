# Ironclad Memory

**Built to remember. Wired to verify.**

Most AI memory systems store and retrieve. Ironclad does the full loop — flush before context loss, retrieve with evidence, track every commitment, escalate what's rotting, and verify before claiming "done."

---

## The Problem

You've built an AI agent. It has memory. It still lies to you. Here's how:

### 1. "Done" without proof
Your agent says "I deployed the update." You check. It didn't. The deployment failed silently, but the agent's short-term context said "deploy command ran" and that was good enough to claim victory. No verification gate means "done" is whatever the model *feels* is true.

### 2. Commitments vanish during compaction
You asked for three things. Context compacted. The agent remembers two. The third — the one with the deadline — is gone. Not explicitly dropped. Just... evaporated. No flush protocol means promises die with context windows.

### 3. Status from vibes
"What's the status of the migration?" The agent answers confidently from whatever fragments survived in its context. No file check. No ledger lookup. No evidence. Just vibes shaped into a plausible sentence. You act on it. It was wrong.

### 4. Tasks rot silently
Day 1: "I'll handle the insurance call." Day 3: silence. Day 7: silence. Day 14: you remember and ask. The agent says "oh right, that's still pending." No escalation system means items decay in the dark, exactly the way ADHD-pattern task management fails in humans.

### 5. Cross-session amnesia
You discussed something important across three separate sessions. Each session had fragments. None had the full picture. Your agent answers from whichever fragment it can see, not the stitched truth.

---

## How Ironclad Fixes Each One

| Failure Mode | Ironclad Module | What It Does |
|---|---|---|
| "Done" without proof | **Verification Gate** | `done_unverified` vs `verified_done`. Can't claim completion without artifact path or message proof. |
| Commitments vanish | **Memory Flush** | Mandatory structured flush before compaction. Commitments, blockers, state, and next steps survive context death. |
| Status from vibes | **Retrieval Gate** | Searches MEMORY.md, daily logs, and ledger before answering. Builds evidence ledger with explicit unknowns. |
| Silent rot | **Escalation Engine** | Day 3→micro-step. Day 5→callout. Day 7→force decision. Day 10+→rot counter. Task-type-aware interventions. |
| Token waste on old files | **Memory Tiers** | HOT/WARM/COLD classification by age. Retrieval reads old files at reduced depth. ~8x token savings on mature workspaces. |
| Cross-session amnesia | **Session Stitching** | Optional adapter finds related conversation fragments across session boundaries. |

---

## Competitive Comparison

| Feature | Bonsai Memory | ClawMem | LanceDB Pro | **Ironclad** |
|---|:---:|:---:|:---:|:---:|
| Key-value storage | ✅ | ✅ | ✅ | ✅ |
| Semantic search | ✅ | ❌ | ✅ | via adapter |
| Vector embeddings | ❌ | ❌ | ✅ | via adapter |
| **Pre-compaction flush** | ❌ | ❌ | ❌ | ✅ |
| **Evidence-based retrieval gate** | ❌ | ❌ | ❌ | ✅ |
| **Commitment lifecycle tracking** | ❌ | ❌ | ❌ | ✅ |
| **Verification enforcement** | ❌ | ❌ | ❌ | ✅ |
| **Stale item escalation** | ❌ | ❌ | ❌ | ✅ |
| **Temperature-based decay tiers** | ❌ | ❌ | ✅ (Weibull) | ✅ (HOT/WARM/COLD) |
| **Audit trail** | ❌ | ❌ | ❌ | ✅ |
| **Full-text search (FTS5)** | ❌ | ❌ | ❌ | ✅ |
| **Multi-path retrieval cascade** | ❌ | ❌ | ❌ | ✅ |
| Cross-session stitching | ❌ | ❌ | ❌ | ✅ (adapter) |
| Atomic writes / locking | ❌ | ❌ | ✅ | ✅ |

Other tools do storage well. None do integrity.

---

## Quick Start

**Prerequisites:** Python 3, jq, bash, sqlite3

```bash
# Clone or install
git clone https://github.com/jaicorn/ironclad-memory.git
cd ironclad-memory

# Make scripts executable
chmod +x scripts/*.sh adapters/*.sh

# Initialize workspace
export IRONCLAD_WORKSPACE="/path/to/your/workspace"
scripts/ironclad.sh init

# Validate
scripts/ironclad.sh doctor
```

That's it. Under 2 minutes. Now wire the commands into your agent's system prompt (see [Integration Guide](references/integration-guide.md)).

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Agent Session                         │
│                                                         │
│  ┌──────────┐  Context    ┌──────────┐                 │
│  │  Agent    │  dying?     │  FLUSH   │──→ memory/      │
│  │  Runtime  │────────────→│  Engine  │──→ ledger.jsonl  │
│  │          │             └──────────┘                  │
│  │          │                                           │
│  │          │  Status     ┌──────────┐  ┌──────────┐    │
│  │          │  question?  │ RETRIEVE │←─│  TIERS   │    │
│  │          │────────────→│   Gate   │  │ HOT  full│    │
│  │          │             │          │  │ WARM 500c│    │
│  │          │             └──────────┘  │ COLD 1ln │    │
│  │          │                  ↑        └──────────┘    │
│  │          │          memory/ MEMORY.md ledger [adapt] │
│  │          │                  │                         │
│  │          │   Evidence       │                         │
│  │          │   ledger         ▼                         │
│  │          │          ┌──────────────┐                  │
│  │          │          │  VERIFIED?   │                  │
│  │          │          │  yes/no/     │                  │
│  │          │          │  mixed/      │                  │
│  │          │          │  unknown     │                  │
│  │          │          └──────────────┘                  │
│  │          │                                           │
│  │          │  New task  ┌──────────┐                   │
│  │          │───────────→│  LEDGER  │──→ ledger.jsonl   │
│  │          │            │ captured │                    │
│  │          │  Done      │ in_flight│                    │
│  │          │───────────→│ verified │                    │
│  └──────────┘            └──────────┘                   │
│                               │                         │
│                    ┌──────────┘                         │
│                    ▼                                    │
│           ┌──────────────┐                              │
│           │  ESCALATION  │  3d→micro  5d→callout       │
│           │    ENGINE    │  7d→decide 10d+→rotting     │
│           └──────────────┘                              │
└─────────────────────────────────────────────────────────┘
```

---

## Module Deep-Dives

### Memory Flush (`flush.sh`)

Structured memory preservation before context loss.

```bash
# Full flush with all sections
ironclad flush \
  --commitment "Ship feature X by Friday" \
  --inflight "Running test suite" \
  --blocker "CI credentials expired" \
  --state "Main branch at abc123" \
  --expectation "User expects demo by 3pm" \
  --next "Fix CI creds, re-run tests"

# Also sync to ledger
ironclad flush \
  --commitment "Ship feature X" \
  --blocker "CI creds expired" \
  --ledger
```

Output: Appends structured markdown to `memory/YYYY-MM-DD.md`.

### Retrieval Gate (`retrieve.sh`)

Evidence-based answer validation.

```bash
# Before answering "is the deployment done?"
ironclad retrieve \
  --claim "The deployment is complete" \
  --term "deployment" \
  --term "v2.1" \
  --path deploy-log.txt

# JSON output for programmatic use
ironclad retrieve \
  --claim "Migration status" \
  --term "migration" \
  --json
```

Output: Sources checked, evidence found, unknowns, and answer-allowed verdict.

### Commitment Ledger (`ledger.sh`)

Full lifecycle tracking with JSONL backend.

```bash
# Direct ledger operations
scripts/ledger.sh add --type commitment --priority p1 --summary "Deploy v2.1" --owner agent
scripts/ledger.sh update --id c-20260325-abc --status in_flight --note "Starting deployment"
scripts/ledger.sh close --id c-20260325-abc --artifact-path /logs/deploy.txt --note "Verified live"
scripts/ledger.sh verify --id c-20260325-abc --message-id msg-123 --note "User confirmed working"
scripts/ledger.sh list --status blocked
scripts/ledger.sh search --query "deploy"
scripts/ledger.sh history --id c-20260325-abc
scripts/ledger.sh gc --days 30
```

### Capture Engine (`capture.sh`)

Deterministic event-to-ledger capture with dedup.

```bash
# From memory flush
scripts/capture.sh from-flush --commitment "Ship feature X" --blocker "CI expired"

# From events
scripts/capture.sh from-event --event-type user_ask --summary "Deploy dashboard"
scripts/capture.sh from-event --event-type blocker_raised --summary "OAuth expired"

# Check for existing entry
scripts/capture.sh match --summary "Deploy dashboard"
```

Features: fuzzy dedup, automatic reopening of deferred/dropped items, TOCTOU-safe locking.

### Open Loops (`loops.sh`)

Compact summary for context injection.

```bash
ironclad status                          # Quick counts
scripts/loops.sh --json                  # Machine-readable
scripts/loops.sh --priority p0           # Fires only
scripts/loops.sh --counts-only           # Minimal
```

### Escalation Engine (`escalate.sh`)

Stale item watchdog with task-type-aware interventions.

```bash
ironclad escalate                        # Full report
ironclad escalate --json                 # JSON rot report
ironclad escalate --dry-run              # Preview without writing
```

**Tier system:**
- **Day 3+** — Micro-step added (smallest possible next action)
- **Day 5+** — Callout (do it or kill it)
- **Day 7+** — Force decision (do today / reschedule / kill / delegate)
- **Day 10+** — Rotting (red alert with rot counter)

**Task-type detection:** Analyzes summaries to detect call, email, portal, purchase, in-person, and waiting tasks. Generates type-specific micro-steps:
- *Call:* "Pick up the phone and dial..."
- *Email:* "Open compose, type the recipient..."
- *Portal:* "Log in, locate the submit button..."
- *Purchase:* "Search, add to cart, don't overthink..."

### Memory Tiers (`tier.sh`)

Temperature-based memory decay. Classifies files as HOT, WARM, or COLD by age, then controls retrieval depth to cut token costs.

```bash
ironclad tier classify                    # Scan and classify all memory files
ironclad tier show                        # Current breakdown
ironclad tier show --json                 # Machine-readable output
ironclad tier get memory/2026-03-20.md    # Single file lookup
ironclad tier read memory/2026-03-20.md   # Read at tier-appropriate depth
```

**How retrieval respects tiers:**
- **🔴 HOT** (<24h) — Full content scan, 5 matches per term
- **🟡 WARM** (1–7d) — Capped scan, 3 matches per term  
- **🔵 COLD** (>7d) — Filename match + max 2 grep hits only

Retrieval automatically uses tiers when `tier.sh` is present — no configuration needed. Run `tier classify` nightly via cron or your agent's maintenance loop.

**Impact:** On a workspace with 90+ daily memory files, this reduces retrieval token cost by ~8x. Old files aren't deleted — they're just read proportionally to their likely relevance.

---

## Multi-Path Retrieval (v2.0)

v2.0 adds a 5-layer retrieval cascade that improved accuracy from **85% → 99.3% (150-question publication-grade benchmark)** on fresh, unbiased questions.

### The Cascade

| Layer | Speed | Method | Answers |
|---|---|---|---|
| 1. Instant | <1s | MEMORY.md + daily files + memory-index grep | "Is this in operational memory?" |
| 2. Fast Search | <1s | FTS5 full-text + LCM conversation grep | "Has this been discussed or logged?" |
| 3. Semantic | ~5s | Embedding/similarity search (if available) | "Related entries I missed?" |
| 4. Deep Expansion | ~10s | LCM cross-session expansion | "What happened in past sessions?" |
| 5. Direct Reads | varies | Targeted file reads from evidence | "What does the artifact actually say?" |

### FTS5 Full-Text Search

SQLite FTS5 index over workspace markdown files. Splits by section headers for granular results. Porter stemming catches morphological variants.

```bash
# Build the index
scripts/build-fts-index.sh

# Search
scripts/fts-search.sh "deployment status" --limit 10
scripts/fts-search.sh "budget review" --json

# CLI shortcut
ironclad search "deployment status"

# Build all indexes at once
ironclad index
```

### Memory Index

Greppable concept→file index. Fast lookups for "which file contains X?"

```bash
# Build
scripts/memory-index.sh

# Search
grep -i "project" data/memory-index.md
```

Edit the `CATEGORIES` array in `memory-index.sh` to match your workspace topics.

### LCM Pattern Search

Topic-aware patterns for searching compacted conversation history via `lcm_grep`.

```bash
# Search with pattern matching
scripts/lcm-search.sh "deployment status"
ironclad patterns "deployment status"
```

Customize `references/lcm-patterns.json` with your own topic patterns.

See: [Retrieval Cascade](references/retrieval-cascade.md) | [LCM Subagent Workaround](references/lcm-subagent-workaround.md)

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `IRONCLAD_WORKSPACE` | Auto-detect | Base workspace directory |
| `IRONCLAD_MEMORY_DIR` | `$WORKSPACE/memory` | Daily memory file directory |
| `IRONCLAD_LEDGER_PATH` | `$WORKSPACE/data/commitments/ledger.jsonl` | Commitment ledger |
| `IRONCLAD_TIMEZONE` | `UTC` | Timezone for flush timestamps |
| `IRONCLAD_LCM_ADAPTER` | `0` | Enable LCM retrieval adapter |
| `IRONCLAD_LCM_DB` | — | LCM database path |
| `IRONCLAD_STITCH_DB` | — | Cross-session stitch database path |
| `IRONCLAD_TIER_HOT_SECONDS` | `86400` | HOT threshold (default 24h) |
| `IRONCLAD_TIER_WARM_SECONDS` | `604800` | WARM threshold (default 7d) |
| `IRONCLAD_TIER_WARM_CHARS` | `500` | Characters shown for WARM preview reads |
| `IRONCLAD_TIER_TRACKER` | `$WORKSPACE/.ironclad/tier-tracker.json` | Tier classification cache |
| `IRONCLAD_FTS_DB` | `$WORKSPACE/data/fts5-index.db` | FTS5 search index database |

### Workspace Auto-Detection

Ironclad finds your workspace by looking for a `.ironclad/` directory:
1. Check `IRONCLAD_WORKSPACE` env var
2. Walk up from the script's directory
3. Walk up from the current working directory

---

## Adapters

### LCM Adapter
Searches an LCM (Lossless Context Management) database for conversation evidence.

```bash
export IRONCLAD_LCM_ADAPTER=1
export IRONCLAD_LCM_DB=/path/to/lcm.db
ironclad retrieve --claim "..." --term "..."
# LCM results are automatically included
```

### Cross-Session Stitch
Finds related conversation fragments across session boundaries.

```bash
adapters/cross-session-stitch.sh --chat-id "12345" "deployment" "status"
```

### Writing Custom Adapters
See [Integration Guide](references/integration-guide.md#adapter-development) for the adapter interface.

---

## Test Suite

```bash
# Run all tests
scripts/test-ironclad.sh

# Tests cover:
# - Flush: daily file creation, section appending, missing dirs
# - Retrieve: memory search, evidence ledger, missing files
# - Ledger: add, update, close, verify, list, search, history, gc
# - Capture: dedup, reopen, event mapping, locking
# - Loops: text/json output, filtering, counts
# - Escalate: tier calculation, micro-steps, task-type detection
# - CLI: all subcommands, help text, version
# - Doctor: dependency detection, invalid ledger, permissions
# - Edge cases: empty ledger, unicode, long summaries
```

---

## Known Limitations

- **Windows:** Native Windows is not supported. Use WSL (Windows Subsystem for Linux) — all scripts work there.
- **No encryption at rest:** Memory files and ledger entries are stored as plaintext markdown and JSONL. If your agent handles sensitive data, encrypt the storage directory at the OS level (FileVault, LUKS, BitLocker).
- **No semantic search (built-in):** FTS5 provides stemmed full-text search, but not semantic/vector search. For embedding-based search, wire up an adapter (see [Adapters](#adapters)).
- **Single-agent only:** The ledger uses file locking for concurrency safety, but is designed for one agent instance. Multi-agent setups sharing a ledger are not tested.

## Privacy

Ironclad stores everything you flush as plaintext files. **Do not** store:
- Passwords, API keys, tokens, or secrets
- Full credit card or bank account numbers
- Social security numbers or government IDs

If your agent processes sensitive user data, configure `IRONCLAD_MEMORY_DIR` to point to an encrypted volume. The `ironclad purge` workflow (drop → gc) archives entries but does not truly delete them from the JSONL file — manual editing is required for complete removal.

## Why This Exists

Every AI agent framework talks about memory. They mean storage. That's like saying a filing cabinet makes you organized.

Organization isn't about where things go. It's about:
- Do you flush before you forget? (Most agents don't.)
- Do you check before you claim? (Most agents don't.)
- Do you track what you promised? (Most agents don't.)
- Do you escalate what's rotting? (Most agents don't.)
- Can you prove you did what you said? (Most agents can't.)

Ironclad doesn't replace your storage layer. It adds the integrity layer that's been missing. The one that turns "I think I did that" into "here's the proof" or "I don't actually know."

---

## License

MIT. See [LICENSE](LICENSE).
