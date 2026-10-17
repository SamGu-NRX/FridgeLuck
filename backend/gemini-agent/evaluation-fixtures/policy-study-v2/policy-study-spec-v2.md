# Policy Study v2 — Frozen Specification (R1)

Status: **pre-registered before scoring**. This document, the builder
(`build_cases.py`), and every generated file are committed together; the
scoring stages read the generated files as frozen bytes. Any change after
scoring begins requires a new version directory.

v2 inherits the pre-registered constants, arms, and metrics of
`next-decisions/next-decisions-spec-v1.md` unchanged (spec v1 §4–§8). This
document records what changes and why; anything not listed here is v1 as
written.

## §1 Source binding (the v2 change)

v1's family was built from local scratch caches with provisional mappings.
v2 binds the same study design to commit-verifiable sources:

| Source | Role | Provenance |
|---|---|---|
| **PR 41 frozen refs** (`obv/fl-next-portion-estimates` → `experiments/nutrition5k-portion/data/dish_targets.csv`) | N5k plate universe + per-plate provenance (plate cluster, official RGB split, official dish mass) | read-only via `git show`; sha256 pinned in `source-hashes.json` and in the build manifest |
| Official Nutrition5k metadata CSVs (cafe1/cafe2/ingredients) | per-ingredient masses (the adjudication truth) | cached 2026-10-09; sha256 verified at build time |
| Food-101 `meta/` label files (test split) | photo stratum universe | cached 2026-10-09; sha256 verified |
| Pinned app catalog `apps/ios/Resources/data.json` | recipe structure, ingredient ids, confusable sets | sha256 verified |
| Committed class→recipe and N5k→catalog mappings (v1 files, verbatim) | stratum sampling + truth projection | committed with this study |

**PR 41 is consumed read-only.** Its frozen reference rows supply the plate
universe and provenance fields; no portion-model output (per-ingredient
estimates, arm results) is used as study truth. Per-ingredient masses come
from the official metadata CSVs, which PR 41 also consumed unmodified. The
builder cross-checks every sampled plate: it must exist in PR 41's
`dish_targets.csv`, and PR 41's `total_mass_g` must equal the official
dish-row mass column exactly (≤1e-6 g). PR 41's totals are whole-dish mass;
official per-ingredient masses do not have to sum to them.

**Real-scan demo stratum: excluded.** The committed recognition manifest
(`apps/ios/Resources/benchmark_manifest.json`) covers 4 demo scans with
expected ingredient ids and **no measured confidences**, so no real-scan
requests can be declared under the §4 declaration rule. The FoodSeg103
image manifest and OFF packaging-OCR manifest cited by v1 were never
committed (their directories are empty on every branch). The eval slice is
therefore 800 N5k + 408 Food-101 cases; no demo cases are invented.

## §2 Targets (the second v2 change)

Every eval label carries three explicit targets; a target with no source
for its stratum is `null` — never guessed, never proxied:

| Target | n5k-plate | food101-photo |
|---|---|---|
| `native_recipe_identity` | `null` (plates have no native recipe label) | `{mapped_recipe_id}` from the committed mapping |
| `dish_category` | `null` (no dish-category label for N5k plates) | `{food101_class}` (adjudicable: ground truth is the class) |
| `weighed_mass` | per-ingredient `mass_g` from the official CSVs, per-serving basis = catalog `quantity_grams / recipe.servings`, tolerance 0.35, floor 10 g | `null` (Food-101 has no measured masses) |

Scored metrics per arm are computed only over cases whose relevant target
is non-null; per-target coverage is reported alongside every metric so a
target with sparse coverage is visible, not silently averaged in.

## §3 Candidate inputs vs. labels (strict separation)

- `requests.jsonl` — the **only** producer input: `{case_id, detections}`
  where `detections` is the declared `[ingredient_id, confidence]` list.
  No truth ids, no masses, no recipe identity, no final edits, no reference
  fields appear in this file (enforced by test).
- `labels.jsonl` — adjudication truth per eval case (the three targets,
  truth ingredient ids, and PR 41 provenance fields). Read only by the
  scorer after a manifest's decisions are frozen.
- `cases.jsonl` — the case registry (ids, strata, slices, source refs).
- `replay.json` — 200 development episodes with declared actions and
  rewards, for the development-warm arm (v1 §5, unchanged).

## §4 Evidence declaration (frozen from v1)

Same constants as the pre-registered values: N5k presence 0.85 per truth
ingredient; Food-101 required 0.90, optional 0.65; confidence = 0.45 +
0.50·Beta(8.2, 2.2) per true detection; false-positive budget 0/1/2 with
probabilities 0.53/0.35/0.12 drawn from recipe co-occurring sets outside
the truth set at confidence 0.45–0.80; mass floor 10 g. All randomness is
the SHA-256 counter PRNG of v1 §6 — the build is byte-reproducible.

The Swift producer still sees real catalog structure (§5 of v1): candidate
generation, the four-signal projection, and hard-fail rules run on the
declared detections; scoring compares producer output against labels.

## §5 Families, slices, counts (frozen)

- `n5k-plate` — dev 200, eval 600. Eligibility (unchanged): ≥2 mapped
  ingredients with mass > 0, ≥1 with mass ≥ 10 g; measured pool 1,552
  plates (v1's provisional 1,970 counted without the mass floor).
- `food101-photo` — eval only, 34 per class over the 12 mapped classes
  (408 cases; 3,000-class eligible test images).
- Dev and eval slices are disjoint; dev cases carry no labels.

Committed in `build-manifest.json`: per-stratum slice counts, eligible
pool sizes, per-target unknown counts, and information-collision counts.

## §6 Information-collision reporting

A **collision group** is a set of cases whose canonical request evidence
(the only producer input) is byte-identical. Within a group, distinct
label signatures mean the information limit: no policy can distinguish
those cases, so any quality difference between arms on them is chance.
R1 build-time finding: 1 group of 8 cases — all with an **empty detection
vector** (every presence draw missed; empty evidence cannot be
distinguished), spanning 6 eval cases with 6 distinct truth signatures.
The scorer recomputes collisions at the producer level (canonical
4-signal request including hard-fail reasons) and reports both levels.

## §7 Arms (frozen from v1)

1. **Cold-start**: real Swift `ConfidenceLearningService` with fresh state
   (no learned history) over all eval requests.
2. **Development-warm**: same service after replaying the 200 dev
   episodes (800 events: four learner signals per episode).
3. **Degenerate-input**: empty, single-item, duplicate, and
   unknown-ingredient requests — producer must fail closed.
4. **Live Decisions arm** (`POST /v1/decisions`): gated. Runs only with
   operator-supplied access and spend limits; without them the arm is
   reported as not-run, never imputed.

## §8 Verification

- Build-time: source hashes (all pinned bytes), PR 41 membership + mass
  cross-check per plate, determinism (rebuild ⇒ identical bytes).
- Test-time (backend suite, strict): manifest `file_sha256` vs. actual
  bytes; requests/labels/cases schemas; the no-leak rule (no truth, mass,
  recipe, or reference fields in `requests.jsonl`); registry/label/replay
  consistency; disjoint slices; PR 41 provenance fields present on every
  N5k label; three-target adjudicability per stratum; replay episode
  count and reward domain.
- Scoring-time: producer-vs-declared parity checks, then metric tables
  per arm with per-target coverage, then tamper checks (scored manifests
  must fail re-verification if any frozen byte changes).
