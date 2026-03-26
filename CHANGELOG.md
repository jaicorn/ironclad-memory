# Changelog

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
