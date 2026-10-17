# FLKitchenKnowledge

The sourced kitchen-knowledge layer for FridgeLuck: ingredient learn cards, waste
accounting in grams/dollars/CO2e, and challenge packs (budget, food-bank, seasonal,
use-it-up).

Pure Foundation. Linux-buildable. No UIKit, no third-party dependencies.

## The contract

Every JSON file in `data/kitchen-knowledge/` shares one envelope
(`schemaVersion`, `kind`, `retrieved`, `data`). Every number traces to a cited
source. Data that cannot prove its numbers is **refused at load**, never guessed:

- a learn card whose nutrition block cites a source outside its `sources` map
  throws `MissingSourceError`;
- the waste ledger never absorbs grams from an ingredient it cannot price or
  factor — they are reported as explicit **refusals** per ingredient and reason;
- consumption only counts as *saved* when a dated consume event lands on or
  before the lot's use-by date; after it, *used late*; without evidence,
  *consumed-unknown*.

Rounding happens only on output (cents for USD, 3 decimals for kg CO2e);
aggregation sums unrounded values. Full data contract and join checklist:
`data/kitchen-knowledge/SCHEMA.md`.

## API sketch

- `KitchenKnowledge(directory:)` — loads everything found under a data root;
  missing subdirectories load as empty, not as errors.
- `LearnCard.parse(from:)` — strict decoder for a single card file.
- `WasteLedger.record(_:)` / `.result()` — event-sourced waste accounting with
  low/central/high emission ranges and a deterministic refusal report.
- Pack payloads (`BudgetPacksPayload`, `FoodBankPacksPayload`,
  `SeasonalPacksPayload`, `UseItUpPacksPayload`) decode through the same
  `DataEnvelope` and keep their budget invariants in tests, not runtime logic.

## Verify

```sh
cd packages/FLKitchenKnowledge
swift build
swift test
```

`RepositoryDataTests` loads the real `data/kitchen-knowledge/` tree relative to
the repo root; it skips cleanly when the data has not been joined to the branch
yet, so the package stays green from the first commit.
