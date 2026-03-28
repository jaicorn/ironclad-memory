# Changelog

## [2.0.0] - 2026-03-28

### Added
- **Multi-path retrieval cascade** — 5-layer retrieval strategy (instant → fast search → semantic → deep expansion → direct reads)
- **FTS5 full-text search** — SQLite FTS5 index over workspace markdown files with porter stemming and section-level granularity
  - `build-fts-index.sh` — builds the FTS5 index
  - `fts-search.sh` — searches with special-character sanitization
  - `rebuild-fts-index.sh` — cron-friendly rebuild wrapper
- **LCM pattern search** — topic-aware search across compacted conversation history
  - `lcm-search.sh` — generates search plans from pre-tested patterns
  - `references/lcm-patterns.json` — template patterns file (customize for your workspace)
- **Memory index** — greppable concept→file index for fast lookups
  - `memory-index.sh` — builds the index with configurable topic categories
- New `ironclad search` command — FTS5 search from CLI
- New `ironclad index` command — build/rebuild all search indexes
- New `ironclad patterns` command — LCM pattern search from CLI
- `references/retrieval-cascade.md` — documentation for the 5-layer cascade
- `references/lcm-subagent-workaround.md` — workaround for LCM limitations in subagent context
- `retrieve.sh` now automatically uses FTS5 and LCM patterns when available (backward-compatible)
- `doctor.sh` now validates all new scripts

### Changed
- Retrieval accuracy improved from 85% → 99.3% on 150 fresh, unbiased questions
- `retrieve.sh` enhanced with multi-path search (FTS5 + LCM patterns as additional layers)
- `ironclad.sh` updated with new subcommands (search, index, patterns)
- SKILL.md updated with multi-path retrieval documentation
- sqlite3 added to prerequisites (for FTS5 — included on most systems)

## [1.1.0] - 2026-03-26

### Added
- Temperature-tiered memory decay (HOT/WARM/COLD) with configurable thresholds
- Tier-aware retrieval — cold files return stubs unless forced
- `tier classify`, `tier show`, `tier read` commands
- `.gitignore` for runtime artifacts
- Known Limitations and Privacy sections in README
- CHANGELOG.md

### Fixed
- SKILL.md description rewritten to be trigger-focused (agents now know *when* to activate)
- README test path corrected (`scripts/test-ironclad.sh`, not `tests/`)
- README clone URL fixed (`jaicorn`, not `your-org`)
- `doctor.sh` now validates `tier.sh` in its script check array
- Version synced across SKILL.md and ironclad.sh

## [1.0.0] - 2026-03-26

### Added
- Initial release: 7 modules (flush, retrieve, ledger, capture, loops, escalate, doctor)
- 79-test suite
- 4 reference docs (flush, retrieval, ledger protocols + integration guide)
- 2 adapters (LCM, cross-session stitch)
- MIT license
