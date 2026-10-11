# HANDOFF — preparation-state-v1 extension (image inference, nutrient consequences, held-out arm, verifier)

Status as of 2026-10-10 (draft PR #48, branch `obv/fl-l2-preparation` → `obv/fl-next-ingredient-recognition-r1`).
Companion to the benchmark README. Everything below was produced on the Linux
benchmark sandbox and independently re-verified by `verify_report.py`.

## What this work added

1. **Held-out preparation-alternative arm** (`heldout_alternative` in `run.py`)
   — 22 probes from the deterministic test split on groups with ≥2 catalog
   records, run through the production replay path.
2. **Image arm** (`image_inference.py`) — the frozen CPU CLIP baseline over the
   FoodSeg103 validation split (2,135 images), scored against ingredient
   identity groups and stateful bindings.
3. **Nutrient-consequence report** (`nutrient_consequences.py` →
   `results/nutrient_consequences.json`) — per-100 g deltas for wrong-state
   text predictions and kcal spread for ungrounded image-side state bindings.
4. **Independent verifier** (`verify_report.py`) — recomputes outcome
   classifications, per-arm summaries, confusion tables, hashes, and all image
   metrics (including the eligibility-invariance control) from the committed
   files alone; 23/23 checks pass.
5. **SwiftReplay root-path fix** (`sync_production_sources.sh` now resolves the
   repo root via `git rev-parse --show-toplevel`) and an explicit
   "Full-resolver execution limits" section in its README.

## Findings

### Text arms (1,375 probes; 620 groups, 800 records; frozen manifest)

| Arm | Correct | Correct-abstain | Abstain | Wrong-state | Wrong-identity | Curated-cross |
|---|---|---|---|---|---|---|
| pinned_cpu_baseline | 749 | 112 | 211 | 303 | 0 | 0 |
| production_replay | 867 | 37 | 26 | 369 | 53 | 23 |
| heldout_alternative (22 probes) | 11 | 4 | 0 | 6 | 1 | 0 |

- Production replay is better at identity but **worse at preparation state**:
  on unknown-state probes ("the bowl of rice" with no state given), 356 of 415
  return a concrete wrong-state record instead of abstaining. The largest
  confusion is `cooked→raw` (258), then `cooked→canned` (26),
  `raw→cooked` (26), `cooked→dried` (28).
- **Held-out alternative selection** (the slice that exposes which member of a
  multi-record group the resolver picks): identity is 21/22 group-correct, but
  exact-record match is only 11/22. All 11 state-family probes pick the exact
  record; on unknown-state targets only 4/11 abstain correctly and 6/11 return
  a concrete wrong-state record (cooked→frozen 2, cooked→raw 2, raw→cooked 1,
  dried→raw 1). This confirms the finding generalizes to the held-out split,
  not just the training-derived confusion table.

### Nutrient consequences of those errors

13 wrong-state predictions had both a predicted and a target catalog record
(unknown-state probes have no target record and cannot contribute a delta):

- `cooked→raw` (n=5): mean kcal **+7.96%**, median −11.11%, worst case
  +108.33%; 4 of 5 beyond ±20%.
- `frozen→raw` (n=4): mean kcal −16.93%, fat +151.32% on average.
- `canned→raw` (n=2): mean kcal **−61.44%**.
- Sodium swings are large in both directions (−57.9% mean on cooked→raw;
  +200% on the single cooked→dried pair).

### Image arm (FoodSeg103 validation, 2,135 images)

- **Identity detection is weak**: 503 expected ingredient groups, 37 detected
  → group recall 0.0736; only 37/2,135 images (1.73%) hit any expected group,
  with 1,720 spurious group detections. The whole-image ViT-B/32 food
  classifier does not transfer to FoodSeg103's fine-grained ingredient label
  space. This arm measures the shipped baseline honestly — it is not a
  viable production detector.
- **State binding is ungrounded**: of 128 detections on multi-alternative
  groups, 69 (53.91%) across 15 groups bound a concrete stateful record with
  no image evidence for that state. FoodSeg103 has no preparation-state
  labels, so state correctness is unverifiable on image — the report records
  this explicitly rather than guessing.
- Consequence: each ungrounded binding picks one member of a group whose
  per-100 g kcal spread averages **54.9% of the group mean** (median 25.64%,
  max 136.68%); 52 of 69 bindings are beyond a 20% kcal spread.

## Limits — what was NOT run or NOT checkable

- **`heldout_alternative` is not yet preparation-alternative-aware** — it
  calls the same production resolver on the 22-probe test-split slice; a
  preparation-aware alternative-selection evaluation (scoring which member of
  a multi-state group *should* be chosen under a stated preparation intent)
  remains open work, not delivered here.
- **SwiftReplay (lexicon arm) is unrun**: no Swift toolchain in the Linux
  sandbox. Run it on macOS per the package README; the runner records the arm
  as unrun (`status: unrun — swift toolchain unavailable`).
- **The full GRDB-backed resolver is not replayable in SwiftReplay** (GRDB +
  bundled catalog are outside the package). The production text replay uses
  the read-only Python port, differential-verified against Swift at 186
  cases, 0 divergences. See the README's execution-limits section.
- **Image preparation-state accuracy is unmeasurable** on FoodSeg103 (no
  state labels). Only identity detection and ungrounded-binding rates are
  reported.
- No iOS/Xcode build happened; nothing here touches app code.

## How to reproduce / verify

```bash
python3 benchmarks/preparation-state-v1/run.py               # text arms (deterministic)
python3 benchmarks/preparation-state-v1/image_inference.py   # needs cached FoodSeg103 embeddings
python3 benchmarks/preparation-state-v1/nutrient_consequences.py
python3 benchmarks/preparation-state-v1/verify_report.py     # 22/22 checks, exit 0
python3 -m pytest benchmarks/preparation-state-v1/tests -q   # 23 passed
```

`verify_report.py` needs only the committed files — it re-derives every metric
it checks and fails loudly on any mismatch. The image scorer needs the cached
validation embeddings (`~/work/bench/embeddings/validation-ViT-B-32-laion2b_s34b_b79k.npy`)
and is ~9 min cold, <1 min warm.

## Provenance

- Manifest sha256 `4204714c…a674`; text predictions sha256 `82bb421b…1a87ca4`
  (both re-verified). Image observations and predictions hashes are recorded
  in `results/image_inference/image_report.json` and re-verified.
- Product mapper (`FoundationModelsMapper` etc.) was **not** touched; all work
  lives under `benchmarks/preparation-state-v1/`.
- Git author: Sam Gu; commits on this branch carry the requested
  `Co-authored-by: obvious-autobuild[bot]` trailer.

## Suggested next steps

1. Run SwiftReplay on macOS (lexicon arm) and paste results back into
   `results/text_arms/` via the runner's `--swift-replay` input.
2. If image identity matters, swap in a FoodSeg103-trained segmentation model
   (the harness scores from per-image detections, so the scorer is reusable).
3. Product decision from the confusion table: unknown-state probes should
   abstain or ask, never silently pick `raw` — `IngredientCatalogResolver`'s
   unique-or-nil prefix match is the code path to change.
