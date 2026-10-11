# Kitchen Knowledge Data — Schema & Join Contract

This directory is the versioned, sourced knowledge layer that `packages/FLKitchenKnowledge`
loads. Every file shares one envelope; every number traces to a cited source; files that
cannot prove their numbers are refused by the loader, not guessed around.

This document is also the **join checklist** for the three sub-branches contributing data
(learn cards, waste accounting, challenge packs). The parent branch owns this file; the
join is complete only when every checklist item below passes in `swift test`.

## Envelope (all JSON files)

```json
{
  "schemaVersion": 1,
  "kind": "<one of the kinds below>",
  "retrieved": "<YYYY-MM-DD the source data was retrieved>",
  "data": { ... }
}
```

- `schemaVersion` must be `1`. A future version changes this file first.
- `kind` must match the expected kind for the path (see layout). Mismatched kind or
  version is a hard load error.
- Unknown keys inside `data` decode-and-ignore: additive evolution never breaks the app.

## Layout

```
data/kitchen-knowledge/
├── SCHEMA.md                      (this file — the contract and join checklist)
├── learn-cards/
│   ├── index.json                 kind: learn-card-index
│   └── cards/<ingredient-key>.json  kind: learn-card
├── waste/
│   ├── model.md                   semantics: buckets, saved/used-late/unknown, rounding
│   ├── emission_factors.json      kind: emission-factors
│   ├── price_factors.json         kind: price-factors
│   ├── loss_factors.json          kind: loss-factors (display-only, never in ledger math)
│   └── hand_computed_examples.json  kind: hand-computed-examples  (exactly 21)
└── packs/
    ├── budget_packs.json          kind: budget-packs
    ├── food_bank_packs.json       kind: food-bank-packs
    ├── seasonal_packs.json        kind: seasonal-packs
    └── use_it_up_packs.json       kind: use-it-up-packs
```

## Invariants the loader enforces (tests pin these)

1. **No number without a cited source.** A learn card's nutrition block carries a
   `sourceId`; if it does not resolve in the card's `sources` map the card refuses to
   load (`MissingSourceError`). History prose must carry at least one citation.
   A source record's id IS the dictionary key it sits under — records must not
   repeat it (a redundant `id` field inside a record is ignored in favor of the key).
2. **Storage guidance is not duplicated.** Each card's storage section links
   `foodSafetyRef` to `data/food-safety/rules.json` (the rulebook owns the numbers).
3. **Waste math never invents.** Price is a point estimate; emissions carry
   low/central/high. Grams whose ingredient lacks a price or an emission factor are
   reported as **refusals** per ingredient+reason — never silently dropped from or
   folded into totals.
4. **Buckets.** `discard` and `expire` are wasted. A dated `consume` on or before the
   lot's use-by is **saved**; after the use-by it is **used late**; without usable
   date/use-by evidence it is **consumed-unknown**. `add`/`adjust` are corrections, not
   outcomes, and only surface in `notCounted`.
5. **Round only on output.** Ledger aggregation sums unrounded values; USD rounds to
   cents, kg CO2e to 3 decimals, at presentation time.
6. **Packs stay under budget.** A budget pack's summed item prices equal its stated
   total and never exceed `budgetUsd`.
7. **Index agrees with cards.** `learn-cards/index.json` card ids must equal the set of
   card files present.

## Join checklist (parent verification before the draft PR)

- [ ] All three sub-branches land their directories above with the declared `kind`s.
- [ ] `swift build` and `swift test` pass on Linux with the joined tree present
      (`RepositoryDataTests` stops skipping).
- [ ] The 21 hand-computed waste examples are asserted through `WasteLedger` against
      their literal expected values (`WasteMathTests`), not merely parsed.
- [ ] No learn card, factor, or pack item cites a source that is absent or has an empty
      licence.
- [ ] `hand_computed_examples.json` contains exactly 21 examples.
- [ ] Seasonal months each carry one pack per declared region.

## Licensing floor

- USDA FoodData Central SR Legacy rows: public domain (US government work); cite the
  FDC ID and the release.
- OWID food emissions: CC-BY 4.0; attribute "Our World in Data" with the dataset name.
- Any web source must state publisher, URL, retrieval date, and licence; sources that
  cannot state all of these are not used.
