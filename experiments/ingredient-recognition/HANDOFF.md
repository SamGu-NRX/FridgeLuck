# Handoff — ingredient-recognition benchmark

State of `obv/fl-next-ingredient-recognition-r1` (draft PR #47, base
`fix/scan-failure-report`) as of 2026-10-10. Read this before touching the
experiment; REPORT.md covers the results themselves.

## Where things stand

**Done and verified (40 tests pass, `verify_report.py` green):**

- Frozen FoodSeg103 slice: `manifest.json` (7,118 images, splits, hashes,
  duplicate groups) + `acquire.py` download/verify tooling. Dataset images are
  NOT in the repo (Recipe1M+ terms); local cache `/home/user/work/bench/dataset/`.
- Taxonomy `taxonomy/foodseg103_to_catalog.csv`: 38 exact / 8 coarse /
  5 ambiguous / 52 unsupported, each with rationale.
- Resolution port `resolution/app_resolution.py`: lexicon port executed
  differentially against 186 genuine Swift probe runs (zero differences).
  The catalog half is a sqlite3 replica of the resolver's SQL semantics —
  the app's real GRDB-backed `IngredientCatalogResolver` was never executed
  here; see REPORT.md "What was actually executed vs what was not".
- Observation runner `runner/observe.py` with the cross-crop dedup fix (the
  bug that deflated milestone 1's six-crop numbers) and deterministic
  `--sample N --seed S` development sampling.
- Scoring `scoring/score.py`, threshold sweep `scoring/threshold_sweep.py`
  (frozen: six-crop 0.25 interior peak; whole-image 0.005, deliberate
  deviation from the 0.001 boundary argmax — recorded as `frozen_threshold`
  in the sweep artifacts with rationale), byte-stable verifier
  `scoring/verify_report.py`.
- Final validation results in REPORT.md (headline: six-crop @0.25 gives
  38.4% instance recall / 40.8% detection precision; whole-image @0.005
  31.0% / 26.0%). All numbers trace to committed `scoring/*_scores.json`.

## Deliberately NOT done

- **No Apple run.** There is no Apple silicon here, so no on-device Vision
  inference was performed and no Apple observation exists. Nothing in this
  branch pretends otherwise: `runner/apple_replay.py` only converts a
  genuine device export and refuses to invent anything; its tests use
  synthetic schema fixtures, clearly labeled. Do not present fixture-based
  numbers as Apple observations.
- **No merge.** PR #47 stays draft; merging is the reviewer's call.
- **No app-threshold change.** The dev-tuned 0.25 belongs to the CLIP
  substitute, not the app's Vision model; do not port it.

## How to finish the Apple arm (when a device is available)

1. Capture a real session in the app and export its observations as JSON
   matching the contract documented at the top of `runner/apple_replay.py`
   (`source: "apple_device"`, per-image `crops[].labels[{name, prob}]`).
2. Convert and score:
   ```bash
   python3 runner/apple_replay.py --export <device-export.json> \
     --split validation --threshold 0.1 --out observations/apple_validation.jsonl.gz
   python3 scoring/score.py --split validation \
     --observations observations/apple_validation.jsonl.gz
   ```
3. The meta file will carry `source: "apple_device"`; keep it adjacent to the
   open-model runs and compare directly — same scorer, same ground truth.
4. Catalog-resolver caveat: to make catalog-path resolutions
   execution-verified (not just semantics-equivalent), run the differential
   probe against the real GRDB resolver on a macOS host.

## Verification commands

```bash
python3 -m pytest experiments/ingredient-recognition/tests -q   # 40 pass
python3 scoring/verify_report.py                                # VERIFIED
```

## Conventions

- Conventional Commits; author stays Sam Gu
  (`127461594+SamGu-NRX@users.noreply.github.com`); every commit message ends
  with `Co-authored-by: obvious-autobuild[bot] <262744130+obvious-autobuild[bot]@users.noreply.github.com>`.
- Never merge, never push to base/default branches, never force-push.
- Dataset images and secrets never enter the repo.
