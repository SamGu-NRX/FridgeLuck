# Suite C — recipe corpus quality and rights

Scorecard row C. This suite is a **scorer of the repo's recipe corpus**, not a
holder of one: it grades the scored tree's product corpus through canonical
sources and fails closed on every judgment it cannot support. Invoked by the
runner as:

```
python3 suite.py --out <abs out dir> --repo-root <abs repo root>
```

## Scored inputs (precedence)

1. **The product tree's corpus** — `data/recipes/corpus.jsonl`, plus
   `data/recipes/originals/originals.jsonl` when present. Rights evidence
   comes from the tree's own manifests (`data/recipes/rights_manifest.json`,
   `data/recipes/originals/rights_manifest.json`); conflicting records for
   one `source_ref` are a hard error. Duplicate recipe ids are a hard error.
   The corpus schema (line-carried conversion evidence, household
   `conversion_ref` + resolved grams) is documented in
   `data/recipes/REPORT.md` on branch `fleet/fl-recipe-corpus-v2` (PR #113).
2. **The bundled catalog baseline** — `apps/ios/Resources/data.json` (or
   `assets/recipes.json`) when no product corpus exists on the tree. Positional
   records carry no per-recipe rights evidence, so the baseline scores
   **0 rights-clear and the suite FAILS it honestly** (166 recipes as of
   2026-10-11, 141 citing bbcgoodfood.com with no licence evidence).

Missing inputs report `not-run` with a precise reason, never pass. When no
recipe is rights-clear, the downstream metrics report `not-run` rather than
vacuous zeros — a quarantined corpus scores nothing.

**The suite's own fixture files are never scored.** `corpus_build.py` and the
files it writes (`fixtures/selftest/authored.json`, `composed.json`,
`conversions.json`, `rights_manifest.json`) exist only for the planted-failure
self-test. Nothing under `fixtures/` can enter scored output.

## Food safety through the canon

Doneness classes, minimum temperatures, required rests, classification
keywords and safety-citation tokens come ONLY from the canonical rulebook
`data/food-safety/rules.json` (branch `overhaul/food-safety-canon`, PR #126;
see `canon/PROVENANCE.md`):

- **Precedence:** the scored tree's `data/food-safety/rules.json` when
  present, else the pinned snapshot `canon/rules.json` (verbatim from
  `2e03467d`). `rs.CanonRulebook.load` validates the rulebook (schema
  version, usable checks for all eight FSIS classes) and returns
  `(None, reason)` on any failure.
- **Fail-closed:** with no canon, every recipe with any safety-relevant
  signal (safety classes, reheat flags or checks) is a violation. The linter
  never substitutes its own temperature table.
- **Ingredient-derived checks:** required doneness classes derive from each
  ingredient's ACTUAL class (allergen-class intersection plus the rulebook's
  keyword classification) and from combination-dish titles (casseroles need
  the 165 F `leftovers` minimum). Every required class must be covered by a
  check naming that class at or above the class minimum — a fish-class check
  cannot clear a chicken recipe. Whole cuts must state the 3-minute rest
  (check `rest_minutes` or step text). Every reheat-flagged step must carry
  its own 165 F `leftovers` thermometer check; reheat language without the
  flag is itself a violation. Colour/time doneness phrases (including
  "juices run clear" and "no pink") fail on steps without a check. Safety
  sources must resolve against the rulebook's citations.
- **UNVERIFIED-NATIVE:** the canonical executable linter
  (`packages/FLFoodSafety`, Swift) cannot run in this Python suite on the
  scored tree. The rulebook DATA is integrated as the source of truth; the
  executable-linter checks are recorded as UNVERIFIED-NATIVE in
  `lint_report.json` (`linter_engine`) and in every run report.

## Allergen/diet claims — FLIngredientFacts wiring (pending)

Composition evidence is the one thing that clears a claim, and it must come
from a sourced table. The `overhaul/ingredient-facts` branch (head `5597db7`)
seeds `packages/FLIngredientFacts` (README today; the dataset and audit
skeletons are landing). The contract (overhaul PLAN.md / SPEC.md): one
`evaluate()` over an ingredient name returning sourced compound composition
whose **unknown result never means allowed**.

**Intended wiring once the package ships its dataset:** `AllergenScanner`
(`rs.py`) becomes its thin consumer — `classify()` asks FLIngredientFacts for
each ingredient's composition and unions the returned allergen classes;
`verify_claim()` recomputes each claim's conflicts from that result. The
fail-closed contract does not change: an ingredient the package cannot
resolve is classification INCOMPLETE, the claim is UNCHECKED, and the suite
strips and counts it (`lint_report.json`: `classification_incomplete`,
`stripped_detail`). Until the dataset lands, the interim alias table
`allergens.json` resolves what it can; **any name it does not resolve makes
every claim on that recipe UNCHECKED** — unknown composition never clears a
claim (fixes the rs.py:259 defect from the PR #88 review BLOCK).

## Rights: every needed permission affirmative

`rights.record_status` quarantines a record unless it is complete AND every
REQUIRED permission is `true` (fixes the rights.py:50 defect where every
permission could be false and the record still cleared):

- always required: `text`, `modification`, `caching`, `offline_use`;
- `attribution`: required unless `source_type` is a FridgeLuck original
  (`original`, `original-rewrite`); derived works and open-licence
  government text must attribute;
- `images`: required when the record indicates images ship (`has_images`).

One denied or absent permission fails and the record is quarantined
(SPEC 3.5: unknown rights means quarantine). The bundled-catalog audit
(`rights.audit_bundled_catalog`) never upgrades a recipe the data cannot
evidence.

## Quantity evidence

A line resolves to grams only through its OWN carried evidence
(`rs._line_resolves`):

- `source_grams`: positive grams on the line;
- `household`: a cited conversion — `conversion_ref` AND the resolved
  `grams` carried on the line (the conversions TABLE is no longer consulted
  at scoring time; `conversions.json` is fixture-only);
- `weighed`: positive grams AND a recorded scale measurement in the
  recipe's `provenance.scale_measurements` — **a builder estimate is never
  weighed** (`corpus_build.py` emits `source_grams` for builder constants);
  an unresolvable `conversion_ref` is unresolved, not weighed.

## Run-payload identity

The runner renders the scorecard row from the payload's `letter`/`title`.
They are loaded from `suite.json` at module import (hard exit if undeclared —
a payload without them renders `?. <id>`; same gap suite A fixed at
`564482c5`), stamped on the payload in `run()`, and `check_identity()`
verifies any payload against `suite.json`. The battery plants an
identity-drifted payload to prove drift is caught.

## Self-test

```
python3 suite.py --self-test
```

A planted-failure battery plus passing controls: a 400-recipe control corpus
spanning every declared band with complete rights records and every canon
doneness pattern must derive ALL FIVE metrics as pass; then 13 plants
re-introduce each BLOCK defect (P1 uncited conversion, P2 flipped claim,
P3 lying emitter, P4 denied permissions, P5 coverage hole, D1a wrong-class
check, D1b reheat on an unrelated check, D1c missing rest, D1d ground
poultry at 160 F, D2 unknown-composition claim, D5 builder "weighed" label,
D4 scoring the suite's own fixtures, D6 identity drift) and each must flip
the derived status to fail. Exit 0 only when every plant is caught and every
control holds. The runner's battery reaches this via
`python3 evaluation/run.py --self-test`.

## Verification

```
# (i) this repo as root: honest FAIL (bundled baseline, 0 rights-clear)
python3 suite.py --out <abs out> --repo-root <abs repo root>

# (ii) temp tree with a schema-true data/recipes corpus: 5/5 pass path
#      (rights gating, line-carried conversions, canon doneness, originals merge)

# (iii) the runner battery exits 0
python3 evaluation/run.py --self-test
```

UNVERIFIED-NATIVE (this Linux sandbox has no Xcode/simulator): the
executable FLFoodSafety linter; iOS rendering of anything scored here.
