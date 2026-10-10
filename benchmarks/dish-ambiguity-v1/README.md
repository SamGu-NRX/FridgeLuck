# dish-ambiguity-v1

Measures what is lost when a coarse food-photograph label (a Food-101 class) is
turned into a specific recipe suggestion against the bundled FridgeLuck catalog
(`apps/ios/Resources/data.json`, 166 recipes at the frozen revision).

A dish label is **not native recipe gold**: Food-101 tells you the dish, not which
of several interchangeable (or non-equivalent) bundled recipes a routing layer
should suggest. This benchmark owns only the mapping and its evaluation; the
running Decisions datasets and ingredient benchmarks are out of scope.

## Taxonomy

`mapping.food101-v1.json` freezes, for each of the 101 official Food-101 classes
(`food101-classes.txt`, copied from the dataset's `meta/classes.txt`), one of:

| status | meaning | recipes field |
|---|---|---|
| `exact` | one bundled recipe is a plausible rendering of the photographed dish | exactly 1 |
| `coarse` | >= 2 bundled recipes are interchangeable renderings of the one dish | >= 2 (equivalence class) |
| `ambiguous` | plausible candidates exist but are non-equivalent; a specific suggestion is a guess | >= 2 (candidates, not answers) |
| `unsupported` | no bundled recipe could be offered without misleading the user | [] |

Each entry carries a `reason` citing the catalog evidence (bundled titles scanned
2026-10-10) and a `nearMiss` note naming the closest rejected candidates.
Uniqueness: an exact/coarse recipe serves exactly one class, and ambiguous
candidates may not double-book an exact/coarse answer.

`taxonomy-summary.json` records the counts: 11 exact, 3 coarse, 2 ambiguous,
85 unsupported; 25 of 166 catalog recipes claimed by exact/coarse answers;
14 eligible classes -> 350 of 2,525 sampled test images are suggestion-eligible.

Development-only threshold choices (frozen in `thresholds`): the dHash
near-duplicate Hamming threshold (10) and the abstention policy (suggest a
specific recipe only for `exact` predictions with top1 probability >= tau, tau
chosen on dev data for >= 0.9 suggestion precision). Neither is tuned on test data.

## Commands

```bash
# 1. validate taxonomy + manifests (exit 1 with ERROR lines on any conflict)
python3 benchmarks/dish-ambiguity-v1/check_manifest.py

# 2. build the stratified sampling manifests (needs the Food-101 dataset on disk)
python3 benchmarks/dish-ambiguity-v1/build_manifest.py --dataset-root /path/to/food-101

# 3. run both pinned classifiers (CPU) over the manifest
python3 benchmarks/dish-ambiguity-v1/run.py --manifest benchmarks/dish-ambiguity-v1/manifest.json --out benchmarks/dish-ambiguity-v1/results

# 4. score + byte-for-byte verify the report
python3 benchmarks/dish-ambiguity-v1/score.py --verify-report

# tests (validator planted-failures + scoring hand controls)
python3 -m pytest benchmarks/dish-ambiguity-v1/tests -q
```

## What is committed

- `mapping.food101-v1.json`, `food101-classes.txt` - frozen taxonomy
- `manifest.json` / `dev_manifest.json` - seeded stratified samples from the
  OFFICIAL test / train splits with per-image sha256 + dHash
  (`dev-near-duplicates-dropped.json` records dev exclusions)
- `results/` - predictions (failures retained), run metadata, weight hashes,
  actual latency and peak memory, dev-chosen tau, generated report
- NOT committed: the Food-101 dataset itself and model weights (hashes only)

## Download / environment limits (documented, specific)

Food-101 is downloaded from the official ETH mirror
(`https://data.vision.ee.ethz.ch/cvl/food-101.tar.gz`, sha256 recorded in
`results/run-metadata.json`). Class list is the distribution's own
`meta/classes.txt` - note this distribution has **no `cheeseburger` class**
(verified: absent from classes.txt and images/). Model checkpoints are fetched
from the Hugging Face Hub at pinned revisions; a download failure of either
source is recorded as a documented limit, not silently skipped.
