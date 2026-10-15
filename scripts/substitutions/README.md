# Substitutions converter

Bridges PR #114's reviewed substitution table (`data/substitutions/pairs.json`,
from branch `overhaul/substitution-table`) to the app-facing resource bundled
by the iOS target (`apps/ios/Resources/Substitutions/substitutions-v1.json`).

## What it does

- Maps pair endpoints to app ingredient IDs (`apps/ios/Resources/data.json`)
  using exact evidence only: catalog name, recorded alias, or fdc id. No fuzzy
  matching; ambiguous evidence fails closed.
- Drops pairs with an unmapped endpoint and records the mapping audit.
- Emits per-role evidence verdicts (`verified` / `plausible` / `unknown` /
  `unsupported`; unknown is never upgraded) and the scaling basis for each
  recorded ratio. An alternative role never inherits the primary ratio.
- Emits the substitute's full compound allergen/diet class closure and
  `compositionKnown` from the canonical facts store, so the app's recheck can
  refuse or fail closed per eater (SPEC overhaul-20261011 §3.1/§3.5).

## Regenerate

```sh
git show origin/overhaul/substitution-table:data/substitutions/pairs.json \
  > data/substitutions/pairs.json
python3 scripts/substitutions/convert.py \
  --table data/substitutions/pairs.json \
  --app-data apps/ios/Resources/data.json \
  --out apps/ios/Resources/Substitutions/substitutions-v1.json \
  --source-commit 4b5895409cb1c990a5e8251f490fe80ccd35c295
```

`--source-commit` must be the commit on `overhaul/substitution-table` that the
pinned `pairs.json` came from; it is recorded in the output's `source` block.

## Tests and the portable check

```sh
python3 -m pytest scripts/substitutions/ -q          # 24 converter tests
bash apps/ios/Tools/substitution-check/run.sh        # needs swiftc
```

The portable check compiles the production
`apps/ios/FeatureLogic/Substitution/SubstitutionTable.swift` against the
generated resource and asserts the schema gate, audit counts, determinism, the
all-pairs x all-restrictions sweep (a forbidden class never screens allowed),
compound refusals, and verdict honesty.
