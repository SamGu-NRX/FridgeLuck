# FridgeLuck waste-accounting model (binding spec)

Part 2 of the kitchen-knowledge programme. This document is the binding
arithmetic specification for turning FridgeLuck inventory events into
"food saved / food wasted" amounts in grams, US dollars and kg CO2e, with
uncertainty ranges. The Swift implementation (`packages/FLKitchenKnowledge`)
must reproduce every example in `hand_computed_examples.json` exactly, under
the rounding rules below. `tools/reference.py` is the normative reference
implementation.

Sam's copy rule (binding, from `planning/stage_0-brainstorm/fridgeluck planning.md`):
*"Track your food waste reduction over time (visualize impact in dollars, CO2, etc.)"*
and *"Every recipe shows estimated food waste saved"* — **food saved counts only food
actually consumed before its use-by, as evidenced by the app's inventory events. The
model never invents savings.** Food that was eaten but cannot be *evidenced* as
pre-use-by is displayed in its own bucket and is never claimed as saved.

## 1. Input contract

The model consumes the app's inventory event stream (see
`apps/ios/Domain/Models/Inventory.swift`): `InventoryEvent(eventType:quantityDeltaGrams:)`
over `InventoryLot(quantityGrams:remainingGrams:expiresAt:)`. Event kinds:

| kind | meaning |
|---|---|
| `add` | food entered the inventory |
| `consume` | food was actually eaten/used (grams = amount consumed) |
| `adjust` | a quantity correction (grams = signed delta; magnitude = corrected amount) |
| `discard` | the user threw food away |
| `expire` | the lot passed its use-by and was written off |

Each event carries: `ingredientKey` (a stable ingredient identifier), `grams`
(positive; for `adjust` the delta's absolute value), `on` (event date, ISO
`YYYY-MM-DD`, may be absent), and `lotUseBy` (the lot's use-by date, ISO
`YYYY-MM-DD`, may be absent). Dates are local calendar dates as recorded by the
app; no timezone conversion. ISO dates compare correctly as strings.

## 2. Buckets

Every event lands in exactly one bucket. All gram amounts are positive.

| bucket | rule | copy meaning |
|---|---|---|
| `saved` | `consume` event where the lot has a use-by and the event date is **on or before** it (`on <= lotUseBy`) | "food saved" — eaten before use-by, evidenced |
| `usedLate` | `consume` event dated **after** the lot's use-by (`on > lotUseBy`) | shown as "eaten (past use-by)" — the food was eaten, but the copy rule forbids claiming it as saved |
| `consumedUnknown` | `consume` event with **no** lot use-by **or no** event date — "before use-by" cannot be evidenced | shown as "eaten (date unverifiable)" — excluded from saved claims |
| `wasted` | `discard` or `expire` event, regardless of any dates | "food wasted" |
| `notCounted` | `add` and `adjust` events — inventory corrections are not food outcomes | never displayed as a food outcome |

The use-by day is inclusive: an event dated exactly on the use-by date counts as
`saved` (see `ex-17`).

## 3. Formulas

Money (per ingredient, per bucket):

```
usd = (grams / 1000) × usdPerKg
```

A point value; the model claims no price uncertainty.

Emissions (per ingredient, per bucket), propagated linearly:

```
kgCo2eLow     = (grams / 1000) × kgCo2ePerKg.low
kgCo2eCentral = (grams / 1000) × kgCo2ePerKg.central
kgCo2eHigh    = (grams / 1000) × kgCo2ePerKg.high
```

All factors are linear, so sums over events and ingredients are computed by
multiplying once per summed gram amount or per event — the unrounded result is
identical either way. Totals sum per-ingredient sums; totals are computed
unrounded and rounded once at output.

With `rangeBasis: "point"` factors (today: all of them — OWID publishes one
central value per product), `low = central = high`. When cited ranges are added
later, the propagation stays linear; nothing else changes.

## 4. Rounding

- All sums are computed **unrounded**; rounding is applied **once, at output**.
- Mode: **half-up** (ROUND_HALF_UP, ties away from zero). Implementations must
  use decimal arithmetic on the decimal representation of the factor values —
  binary floating-point will misround ties (e.g. `0.25 × 9.87 = 2.4675` must
  round to `2.468`, and `6.25 × 3.15 = 19.6875` to `19.688`; see `ex-18`, `ex-19`).
- Output precision: grams **1** decimal, USD **2** decimals, kg CO2e **3** decimals.

## 5. Refusal semantics

An ingredient with grams in a counted bucket (`saved`, `usedLate`,
`consumedUnknown`, `wasted`) that has **no citable factor** is a **refusal**,
never an interpolation and never a silent zero:

| missing factor | effect on totals | recorded as |
|---|---|---|
| no price row | its money contribution is **excluded** from money totals | `unpricedIngredientKeys` (list of keys) and `unpricedGrams` (grams excluded from money), reason `missingPrice` |
| no emission factor | its CO2e contribution is **excluded** from CO2e totals | `missingEmissionFactorKeys` and `missingEmissionFactorGrams`, reason `missingEmissionFactor` |

Refusals are data, not errors: the ledger reports them next to the totals.
The two refusals are independent — `tofu` has a citable emission factor but no
BLS price series (its CO2e counts, its dollars refuse), while `chicken_breast`
has a price but no cut-specific emission factor (its dollars count, its CO2e
refuses). A key missing both appears in both refusal lists. Grams still count
in their bucket in full.

## 6. Ledger output

For each of the four counted buckets, the ledger reports `grams`, `moneyUsd`,
and `kgCo2eLow`/`kgCo2eCentral`/`kgCo2eHigh`; plus `notCountedGrams` (sum of
`|grams|` over `add`/`adjust` events) and the two refusal pairs from §5.
Field names as in `hand_computed_examples.json` (`savedGrams`,
`savedMoneyUsd`, `savedKgCo2eCentral`, …). An empty event stream yields an
all-zero ledger with empty refusal lists (`ex-20`).

The three "food was eaten" buckets are **separate displays that must never be
merged**: `usedLate` and `consumedUnknown` food was eaten, but only `saved`
may appear as "food saved" or feed the waste-reduction trend.

## 7. Loss factors are display-only

`loss_factors.json` (edible share, consumer-level loss) exists for translation
and display only — e.g. "a 1 lb purchase ≈ 340 g edible strawberries". The
model **never multiplies them into waste or savings totals**: the event stream
already observed the outcome (a discarded lot's discard grams are the waste;
no loss percentage is applied on top). Applying loss factors to observed
outcomes would double-count.

## 8. What the model must never do

- Never claim `usedLate` or `consumedUnknown` grams as "saved".
- Never accept a malformed date or a non-positive `grams` value; refuse the
  stream loudly (§1).
- Never invent a price or an emission factor for an unmapped key (§5).
- Never apply loss factors to event-derived totals (§7).
- Never round intermediate values (§4).
- Never present a single-point CO2e number without its (today degenerate)
  low/high range.
