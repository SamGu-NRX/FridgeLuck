# data/recipes — RS v1 corpus schema and ownership contract

Status: **STABLE**. This file is the shared contract for everyone writing recipe
data under `data/recipes/`. It is published before the original-recipes task
(`fl-original-recipes-f1`) starts, and it does not change silently: propose
changes through the programme parent, never edit it in passing.

The normative implementation of every rule here is suite C's code:
`evaluation/suites/recipes/{rs.py,rights.py,bands.py}` on branch
`eval/scorecard-runner` (PR #88), with tables `conversions.json` and
`allergens.json` beside it, and the bar definitions in
`evaluation/SCORECARD.md`. Where this file and that code disagree, the code
wins and this file gets fixed. Suite C bars for the final corpus: >=400
rights-clear recipes (target 1,500), 100% food-safety linter pass, >=95% of
ingredient lines resolved with quantity evidence, 0 unchecked allergen/diet
claims, and every declared cuisine / meal slot / time band covered.

## Who writes what

| Path | Writer |
|---|---|
| `data/recipes/originals/` | `fl-original-recipes-f1` (branch `overhaul/original-recipes`) ONLY |
| `data/recipes/corpus.jsonl`, `data/recipes/rights_manifest.json`, `data/recipes/REPORT.md` | the corpus ingestion task ONLY |
| `data/recipes/RIGHTS-AUDIT.md`, `data/recipes/SOURCES.md` | the rights-audit task (PR #43 branch) |
| this file | programme parent only |

Source tasks never write corpus-level files; ingestion never rewrites a
source task's files — it validates, lints, dedupes and merges them.

## 1. Recipe object (RS v1)

One JSON object per recipe. Required fields:

```
rs_version   "1"
id           string, globally unique (see §7)
title        string
cuisine      one of: american | asian | indian | italian | mediterranean | mexican
meal_slots   non-empty subset of: breakfast | lunch | dinner
minutes      number > 0  (time bands: 0-15, 16-30, 31-45, 46-60, 61+)
servings     number > 0
ingredients  non-empty list (see §2)
steps        non-empty list (see §3)
source_ref   string, must be a key in the rights manifest (see §5)
```

Optional: `provenance` (object, see §6), `claims` (list, see §4).
Unknown extra fields are tolerated but discouraged; do not invent semantics.

## 2. Ingredients and quantity evidence (rs.py R2)

Each ingredient: `{"name": str, "qty": {...}}`. `qty.kind` is one of:

- `"weighed"` — grams from an **actual scale measurement**, with the
  measurement recorded in `provenance`. A builder's estimate is never
  `weighed`. No one in this programme is measuring in a kitchen, so in
  practice this kind stays unused.
- `"source_grams"` — grams carried from a source record, e.g. the bundled
  catalog's per-ingredient grams for rewrites
  (`apps/ios/Resources/data.json`); name the source in `provenance`.
- `"household"` — household measure with conversion:
  `{"kind":"household","value":>0,"unit":str,"conversion_ref":str}` where
  `conversion_ref` resolves in the suite's `conversions.json` with a
  `grams_per_unit`. An optional positive `"grams"` may record the resolved
  mass. Use only refs that exist in that table today.
- `"unknown"` — an honest unresolved line (`grams` null). Allowed, but the
  corpus bar is >=95% resolved, so use it sparingly and only when true.

## 3. Steps, timers, safety (rs.py R3/R5)

Each step: `{"text": str, "timer_min"?: number, "reheat"?: true, "safety"?: {...}}`.

- `timer_min` only where the step has a natural one, bounded 1–240.
- `reheat: true` marks reheating-leftovers steps.
- A **safety check** is required when the recipe's ingredients include an
  FSIS flesh/egg class or any step is a reheat:

```
{"class": one of meat_poultry | meat_ground | meat_whole_cut_pork |
          meat_whole_cut_red | flesh_fish | flesh_shellfish | egg | leftovers,
 "temp_f": >= the class minimum (165 / 160 / 145 / 145 / 145 / 145 / 160 / 165),
 "method": "thermometer",
 "source": citation — USDA FSIS; use the food-safety rulebook
           (data/food-safety/ on overhaul/food-safety-rules)}
```

- Never state doneness by colour or time ("until golden", "no longer pink",
  "juices run clear") on an animal-protein step without a safety check.

## 4. Allergen and diet claims (rs.py R4)

Each claim: `{"claim": <type from allergens.json "claims">, "evidence":
{"conflicts": [...]}}`. The recorded `conflicts` must **exactly equal** the
recomputed scan (ingredient names resolve through `allergens.json`
`ingredient_aliases` to classes; each claim type lists forbidden classes).
Unknown claim types or mismatched evidence are stripped and counted — write
claims only from actual scanner output, and prefer ingredient names the alias
table recognizes.

## 5. Rights records (rights.py)

`rights_manifest.json`:

```
{"records": {"<source_ref>": {
  "source_id": str, "source_type": str, "origin": str,
  "license": str, "access_date": "YYYY-MM-DD", "license_evidence": str,
  "permissions": {"text": bool, "images": bool, "modification": bool,
                  "attribution": bool, "caching": bool, "offline_use": bool}
}}}
```

A recipe whose `source_ref` has no complete record is quarantined
(fail-closed); unknown rights means quarantine. For original and rewritten
work: `license` is `LicenseRef-FL-Original` (original expression created for
FridgeLuck), one rights record **per recipe** (`source_ref` = the recipe id),
`source_type` `original` (new) or `original-rewrite`, all six permissions
true except `images: false` while no image ships. `license_evidence` points
at the authorizing record — for rewrites, the dish's verdict entry in
`data/recipes/RIGHTS-AUDIT.md` (branch `obv/fl-next-recipe-fidelity`); for
new work, the task name and commit. The app-required permissions are `text`,
`modification`, `caching`, `offline_use`; a denied or unknown one
disqualifies the recipe.

## 6. Rewrites (SPEC 10)

A rewrite is **fresh expression of the same dish concept**: new title, new
ingredient lines, new steps. Never a synonym pass over the original text.
Keep the dish recognizable — core ingredients and rough method — that is the
point; the expression must be ours. Set `provenance.rewrite_of` to the
bundled recipe id. The work list is the rights audit's per-dish verdicts:
rewrite only dishes marked *rewrite*; dishes marked *remove* do not come
back.

## 7. IDs, dedupe, and files under data/recipes/originals/

- Every corpus id starts `fl-`. Originals: `fl-original-<4 digits>`
  (`fl-original-0001`…). Licensed sources: `fl-<source-tag>-<4 digits>`,
  where `<source-tag>` is the source's key in SOURCES.md. Merge-time
  uniqueness is enforced at ingestion; dedupe also compares normalized
  title + core-ingredient sets across sources.
- Originals land as:
  - `data/recipes/originals/originals.jsonl` — one JSON object per line,
    UTF-8, LF endings, append-ordered;
  - `data/recipes/originals/rights_manifest.json` — same shape as §5;
  - `data/recipes/originals/COVERAGE.md` (optional but expected) — band
    counts per milestone.

## 8. Validation loop — run it before every push

Fetch `eval/scorecard-runner` (read-only) and, in the sandbox, lint your own
batch with the suite's `rs.py` over your recipes plus its `conversions.json`
and `allergens.json`; check your manifest with `rights.py` completeness; and
compute band coverage with `bands.py`. Paste the exact commands and output
into your PR's Proof section. Suite C's committed `authored.json` and
`composed.json` are harness **test fixtures** — never copy them, never count
them, and do not derive recipe text from them.
