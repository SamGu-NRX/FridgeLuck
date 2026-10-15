# Substitutions converter

Bridges PR #114's reviewed substitution table (`data/substitutions/pairs.json`,
from branch `overhaul/substitution-table`, pinned at commit `4b589540`) and the
base branch's canonical ingredient vocabulary
(`data/ingredients/vocabulary.json`) to the app-facing resource bundled by the
iOS target (`apps/ios/Resources/Substitutions/substitutions-v2.json`).

## What it does

- Maps pair endpoints to **canonical ingredient keys** using exact evidence
  only: canonical names (key, display name, recorded aliases), fdc-id equality,
  or the recorded USDA source-name reference. No fuzzy matching; ambiguous or
  conflicting evidence fails closed. The reviewed table no longer depends on
  the app's ingredient-id space, so regeneration cannot silently ship stale
  app ids — the app resolves canonical keys to ingredient ids through the
  catalog identity bridge at runtime.
- Drops pairs with an unmapped endpoint, self-swaps (canonicalization merging
  two distinct reviewed endpoints into one key), and duplicate
  (original, substitute, role) offers — first pairId wins — and records the
  mapping audit with named `mappedKeys` / `unmappedKeys` lists.
- Emits per-role evidence verdicts (`verified` / `plausible` / `unknown` /
  `unsupported`; unknown is never upgraded) and the scaling basis for each
  recorded ratio. An alternative role never inherits the primary ratio.
- Emits a per-key composition map (`compositions`) carrying the full compound
  allergen/diet class closure — the union of the vocabulary's curated classes
  and the mapped facts store — plus `compositionKnown`. Keys nothing covers
  fail closed to known=false with empty class lists. Each swap's `recheck`
  denormalizes its substitute's composition, so the app's recheck can refuse
  or fail closed per eater (SPEC overhaul-20261011 §3.1/§3.5).

## Regenerate

```sh
git show 4b5895409cb1c990a5e8251f490fe80ccd35c295:data/substitutions/pairs.json \
  > /tmp/flsubs/pairs.json
git show origin/obv/burst6-fridgeluck-catalog-recommend:data/ingredients/vocabulary.json \
  > /tmp/flsubs/vocabulary.json
python3 scripts/substitutions/convert.py \
  --table /tmp/flsubs/pairs.json \
  --vocabulary /tmp/flsubs/vocabulary.json \
  --out apps/ios/Resources/Substitutions/substitutions-v2.json \
  --source-commit 4b5895409cb1c990a5e8251f490fe80ccd35c295
```

`--source-commit` must be the commit on `overhaul/substitution-table` that the
pinned `pairs.json` came from; it is recorded in the output's `source` block.
The output is deterministic — regenerating from the same inputs is
byte-identical, which the converter tests pin.

## Tests and the portable check

```sh
python3 -m pytest scripts/substitutions/ -q          # 32 converter tests
bash apps/ios/Tools/substitution-check/run.sh        # needs swiftc
```

The portable check compiles the production
`apps/ios/FeatureLogic/Substitution/SubstitutionTable.swift` against the
generated resource and asserts the schema gate (2.0.0), audit counts,
canonical-key integrity (no self-swaps, no duplicate offers, composition
coverage for every endpoint), determinism, recheck/compositions agreement, the
all-pairs x all-restrictions sweep (a forbidden class never screens allowed;
unknown composition fails closed to ask-the-user), compound refusals
(yogurt carries dairy, tofu carries soy), and verdict honesty.
