# Serving identifiability study - report

Question: on `feat/meal-photo-confirmation-v1`, the meal log records
**servingsConsumed** (`MealFinalizationViewModel.servings`), and the inventory
model scales each required ingredient by
`consumed * portion / max(declared, 1)` (`InventoryRepository.servingFactor`).
If a photo of the plate is all an observer effectively holds, which
consumed-servings values could have produced it? Exact `Fraction` arithmetic
throughout; family of 10624 worlds (166 bundled recipes x cook scales
{1/2, 1, 3/2, 2} x consumed {1..4} x portions {1/2, 1, 3/2, 2}),
kitchen-scale readout at 5 g steps, ties up.

## Evidence regimes

| regime | evidence | keys | identifiable | ambiguous keys | ambiguous worlds |
|---|---|---|---|---|---|
| R1_plate_only | plate + only | 645 | 102 | 543 | 10501 |
| R2_identity_and_declared | identity + and + declared | 2653 | 498 | 2155 | 10126 |
| R3_plus_reference | plus + reference | 5973 | 1992 | 3981 | 8632 |
| R4_plus_portion | plus + portion | 10621 | 10618 | 3 | 6 |

The ambiguous-key count is not monotone in evidence (refinement splits one
ambiguous parent into children that can each remain ambiguous); the sound
invariants - identifiable keys never decrease, ambiguous-world count never
grows - hold by construction and are test-enforced.

## Hand witnesses, verified exhaustively

- **same_evidence_different_allocations** (R2_identity_and_declared): targets [1, 2] - 520 x 1 x 1 / 2 = 260 (target 1); 260 x 2 x 1 / 2 = 260 (target 2). Re-derived: PASS.
- **unknown_recipe_identity** (R1_plate_only): targets [1, 3] - 528 x 1 x 1 / 2 = 264 (target 1); 88 x 3 x 2 / 2 = 264 (target 3); both plates read 265 g at the 5 g scale resolution. Re-derived: PASS.
- **portion_reference_tradeoff** (R3_plus_reference): targets [2, 1] - 260 x 2 x 1 / 2 = 260 (target 2, portion 1.0); 260 x 1 x 2 / 2 = 260 (target 1, portion 2.0). Re-derived: PASS.
- **resolved_by_portion_confirmation** (R4_plus_portion): targets [2] - 260 / (130 x 1.0) = 2 -> the only consistent target is 2. Re-derived: PASS.

Each witness was re-derived here from the bundled metadata and the source
formula (`servingFactor`), then re-confirmed as one class of the enumerated
family under its regime: identical available evidence, different serving
allocations.

## The surviving R4 ambiguities (dish + declared + reference + portion confirmed)

Even with the recipe known, the per-serving reference weight of this cook
measured, and the portion multiplier confirmed, 3 observation
keys remain ambiguous:

1. observation (plate, identity, declared) = (10 g, recipe 55, declared 2) - targets [2, 3]: ##55 Chicken parmesan cook x1/2, batch 15 g, t=2, portion 1/2, renders 15/2 g, reads 10 g; ##55 Chicken parmesan cook x1/2, batch 15 g, t=3, portion 1/2, renders 45/4 g, reads 10 g
2. observation (plate, identity, declared) = (10 g, recipe 80, declared 2) - targets [2, 3]: ##80 Halloumi pasta cook x1/2, batch 15 g, t=2, portion 1/2, renders 15/2 g, reads 10 g; ##80 Halloumi pasta cook x1/2, batch 15 g, t=3, portion 1/2, renders 45/4 g, reads 10 g
3. observation (plate, identity, declared) = (10 g, recipe 159, declared 2) - targets [2, 3]: ##159 The ultimate makeover: Chicken pie cook x1/2, batch 15 g, t=2, portion 1/2, renders 15/2 g, reads 10 g; ##159 The ultimate makeover: Chicken pie cook x1/2, batch 15 g, t=3, portion 1/2, renders 45/4 g, reads 10 g

Cause: the 5 g readout rounds rendered plates that are a few grams apart onto
the same step. Finer readouts dissolve them:

| scale resolution | R4 ambiguous keys | R4 ambiguous worlds | unmeasurable (reads 0 g) |
|---|---|---|---|
| 1 g | 0 | 0 | 0 |
| 2 g | 0 | 0 | 0 |
| 5 g | 3 | 6 | 0 |
| 10 g | 13 | 26 | 3 |
| 25 g | 93 | 197 | 31 |

At coarse readouts some legitimately tiny plates round to zero grams - no
valid plate observation exists for those worlds at that resolution
(`make_evidence` refuses a non-positive plate), so they are counted
unmeasurable rather than grouped.

## Leak canary

The observation key is built from observation fields only. The active canary:
a mutated key builder that appends `consumed_servings` MUST be flagged by
`schema.find_outcome_leak` - honest key clean: True; mutated key
flagged: True. The detector is exercised on every `verify.py`
run, not just in unit tests.

## Minimum amount (answer)

The **confirmed portion multiplier** is the decisive observation: adding it
(R3 -> R4) collapses ambiguity by roughly three orders of magnitude at the key
level and cuts ambiguous worlds to the readout floor. With portion confirmed,
the only residual is the 5 g readout artifact (the exhibits above); at 1 g resolution the measurable family is fully identifiable.
Recipe identity and declared
servings alone (R2) leave the cook-size x portion trade-off wide open - the
same plate is one serving of a double cook or two servings of a single cook -
which is exactly witness 1. A per-serving reference weight (R3) pins the
realized batch but not the (servings x portion) product - witness 3.

This answers the study's question for the declared finite family. It does not
claim the app's UI communicates any of this; it bounds what any plate-based
estimate could know.

## Threats to validity

- The family bounds cook scale to {1/2..2} and consumed to {1..4}; witnesses
  outside the grid may exist, none inside it were missed by construction of
  the partition (grouping is exact).
- The 5 g scale and the reference-weight availability are constructed
  observation-model choices, documented in `schema.py`; the sensitivity table
  prices them.
- `batch_grams` comes from the bundle's required-ingredient grams; the app
  scales required ingredients only (`MealBreakdownContent.make`), so optional
  swaps are out of scope by source definition.

## Handoff

- `results.json` carries every number in this report, machine-readable.
- Regenerate: `python3 tools/serving-identifiability/verify.py` (self-verifying:
  witness re-derivation and the canary abort the run on failure).
- Suite: `python3 -m pytest tools/serving-identifiability/tests -q`.
