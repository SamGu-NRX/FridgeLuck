# estimateGrams evaluation vs USDA FNDDS household measures

- Estimator: `InventoryIntakeService` (replayed verbatim from source blob `b23d9e6b2b79`; read-only, unmodified)
- Examples: 176 source-bound FNDDS portions (`estimator_examples.json`, units table `fndds_household_units.csv`)
- Replay executable: `apps/ios/Tools/mass-conversion-check` (`estimator-eval`)

## Arm summary

| Arm | n | Median rel. error | Mean rel. error | Within ±25% | Within ±50% |
|---|---|---|---|---|---|
| nameArm | 176 | 113% | 960% | 17 | 46 |
| unitArm | 176 | 77% | 376% | 35 | 55 |
| unitPrefixedArm | 176 | 72% | 351% | 42 | 67 |

## Unit-arm median relative error by unit family

| Unit | n | Median rel. error |
|---|---|---|
| can | 12 | 72% |
| cup | 12 | 15% |
| egg | 12 | 61% |
| floz | 12 | 292% |
| large | 12 | 62% |
| medium | 12 | 75% |
| oz | 12 | 323% |
| package | 12 | 140% |
| pat | 8 | 1614% |
| piece | 12 | 44% |
| slice | 12 | 72% |
| small | 12 | 73% |
| stick | 12 | 323% |
| tbsp | 12 | 6% |
| tsp | 12 | 33% |

## Name-arm bias by keyword bucket (signed, positive = overestimate)

| Bucket | n | Median signed error |
|---|---|---|
| aromatic | 2 | +133% |
| bread | 7 | +275% |
| dry goods | 9 | +300% |
| egg | 13 | -33% |
| fallback | 101 | +300% |
| liquid | 9 | -35% |
| oil/condiment | 17 | -40% |
| produce | 12 | +86% |
| protein | 6 | +196% |

## Worst name-arm examples

| Food | Portion | USDA g | Estimate g | Error |
|---|---|---|---|---|
| Baby Toddler yogurt melts | 1 piece | 0.5 | 240 | 47900% |
| Sugar substitute, monk fruit, powder | 1 teaspoon | 0.5 | 120 | 23900% |
| Coffee, instant, not reconstituted | 1 teaspoon, dry | 0.9 | 120 | 13233% |
| Sugar substitute and sugar blend | 1 teaspoon | 2 | 120 | 5900% |
| Sugar substitute, stevia, powder | 1 teaspoon | 3 | 120 | 3900% |
| Potato sticks, fry shaped | 10 sticks | 3 | 120 | 3900% |
| Coffee, instant, pre-sweetened with sugar, not reconstituted | 1 teaspoon, dry | 3.4 | 120 | 3429% |
| Coffee, instant, decaffeinated, pre-lightened and pre-sweetened with sugar, not reconstituted | 1 teaspoon, dry | 3.4 | 120 | 3429% |

Reproduce: `python3 scripts/data/evaluate_mass_estimates.py` (regenerates the replay slice and examples, reruns `estimator-eval` and `conversion-checks`; add `--verify-report` to byte-verify the committed reports).
