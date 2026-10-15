# Handoff — scan-correction-eval

Everything needed to reproduce the full evaluation from a clean clone.
Numbers quoted here come from the committed results; regenerate any of them
with the commands below.

## Pinned sources

The replay executes production code verbatim. These files are copied by
`SwiftReplay/Scripts/sync_sources.py` into
`SwiftReplay/Sources/AppSources/` and `--check` fails on any drift
(transforms are platform shims only: dropping `import CoreGraphics`, the
Linux `CGRect` stand-in, and verbatim block extractions):

| Production source | Role in replay |
|---|---|
| `apps/ios/Capability/Core/Recognition/LearningService.swift` | The correction learner (all four policy arms execute it) |
| `apps/ios/Capability/Core/Recognition/ConfidenceRouter.swift` | The production auto-add / confirm / possible router |
| `apps/ios/Domain/Models/Detection.swift` | The Detection the router buckets |
| `apps/ios/Capability/Core/Recognition/ScanContracts.swift` | `OCRMatchKind`, `ConfidenceBucket` (verbatim extraction) |
| `apps/ios/Platform/Persistence/Database/Migrations.swift` | `user_corrections` + `ingredients` schema (verbatim extraction) |

Pin state of the synced copies (committed verbatim in
`data/sync-sha256.txt`; re-derive with
`sha256sum SwiftReplay/Sources/AppSources/{LearningService,ConfidenceRouter,Detection,ScanContractsSubset,GeneratedSchema}.swift`
from `apps/ios/Tools/scan-correction-eval`):

```
f0bb5231694a8b2a…  LearningService.swift
b296bbddf3467828…  ConfidenceRouter.swift
e2f4fb7456ae2db5…  Detection.swift
a17bf0d0c0fda103…  ScanContractsSubset.swift
e01d4c5383891102…  GeneratedSchema.swift
```

`bash SwiftReplay/Scripts/sync_sources.py --check` is the source-of-truth
check — it compares the synced copies against production and fails on
semantic drift.

Toolchain pins: Swift 6.1.2 (Linux toolchain at
`/home/user/work/swift-toolchain/usr/bin` — the run script resolves it
automatically), GRDB 7.10.0, SQLite via the system library with
`-DSQLITE_DISABLE_SNAPSHOT` (required on this Linux build).

## Exact full replay command

From the repository root:

```bash
bash apps/ios/Tools/scan-correction-eval/SwiftReplay/Scripts/run_replay.sh
```

That single command syncs sources (fail on drift), builds the package, runs
all four policy unit tests plus the full replay — 300 committed histories ×
4 arms in fresh GRDB databases with the logical-clock trigger — and writes
`data/replay-out/replay-results.json` (schema 2). Wall time ≈ 2.5 min on
this machine. `REPLAY_FAST=1` runs one seed per family for a smoke build
(writes `replay-results-partial.json`; never scored).

Then, from `apps/ios/Tools/scan-correction-eval`:

```bash
python3 SwiftReplay/Scripts/tally_replay.py     # cross-checks + routing table
python3 score.py                                # formal scoring -> score-report.json
python3 score.py --verify-report                # tamper check (hash + recompute)
python3 -m pytest tests -q                      # 23 checks incl. learner-only preservation
```

## What is measured (and what is not)

- **Learner-only decisions** (`wrongAuto` / `correctAuto` / `abstained` and
  per-scan `decision`): the raw `LearningService` / policy-arm decision per
  scan. Schema 1 (preserved verbatim as
  `data/replay-out/replay-results-learner-only.json`) contained exactly
  these; schema 2 reproduces them identically — enforced by
  `test_learner_only_decisions_preserved`.
- **Routing effects** (schema 2): each scan's `Detection` is built as
  `VisionService` would build it (vision source, the history's confidence)
  and bucketed by the real `ConfidenceRouter`. Auto-add is the only bucket
  that takes effect without the user; its correctness follows the learner's
  decision. Confirm/possible await the user, so the learner's decision has
  no silent effect there. Feedback events fire as scripted by the frozen
  histories (user confirmations in the review flow); routing does not
  re-time or drop feedback.
- **Formal scoring**: `score.py` selects the policy arm on development
  families only (max net auto-corrections, rule fixed in advance in its
  docstring), scores the held-out family afterwards with seed-grouped
  bootstrap intervals, and `--verify-report` refuses tampered results,
  dropped cases, or an edited report.

## Known limits

- No Xcode here: validated on Swift 6.1.2/Linux only. The Apple-toolchain
  build and the iOS app target are left to hosted macOS CI.
- The histories model vision-label scans; the router's OCR paths
  (exact/fuzzy thresholds) are compiled into the replay but not exercised
  by any committed history.
- Production app code is untouched by this branch; `DEFECTS.md` records
  production issues found during the study as reduced records, not edits.
