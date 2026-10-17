# Kitchen-knowledge coverage and licence report

Answers the review brief's two open questions for the kitchen-knowledge data
(learn cards, waste model, packs): what the cards cover against the app's
ingredients, and what licences the cited sources carry. Every number below is
reproducible from the data itself — coverage from `learn-cards/index.json`
(`data.coverage`), licences from `learn-cards/SOURCES.md` and the `source`
/`sources` records of the waste and pack files.

## Card coverage

| Universe | Size | Covered | Gap |
| --- | --- | --- | --- |
| App catalog — `apps/ios/Resources/data.json` ingredients | 50 | 50 | 0 |
| Seed-corpus distinct ingredient names (rights-clear recipes) | 113 | 113 | 0 |
| USDA catalog sqlite — `apps/ios/Resources/usda_ingredient_catalog.sqlite` | 800 rows | not a learn-card universe | — |

- 116 cards ship: the 50 app-catalog ingredients (`isCore: true` in
  `learn-cards/index.json`) plus 66 extras for seed-corpus names outside the
  bundled catalog.
- 47 cards are referenced by the bundled `data.json` recipes; all 47 are core
  cards.
- 9 cards carry no nutrition — no honest SR Legacy row exists, so the cards
  refuse rather than guess (listed in `index.json` `data.coverage.missingNutrition`):
  chaat masala, chipotle, flattened rice, garam masala, gochujang, halloumi,
  harissa, paneer, rice vinegar.

### Against the 300-card target

The review brief asks coverage to be stated against a 300-card target. No
in-repo document defines that universe: the app catalog has 50 ingredients,
the bundled recipe corpus references 47 distinct ids, and the USDA catalog
sqlite holds 800 rows. Stated honestly — 116 cards ship, and both in-repo
universes the cards were built from (the app catalog and the seed corpus) are
fully covered with no gaps. What the remaining ~184 cards of a 300 target
should cover is an open product question for the operator, recorded here and
in the PR handoff.

## Licence report — all cited sources

| Data | Sources | Licences |
| --- | --- | --- |
| Learn cards — prose (`SOURCES.md`) | 110 | CC BY-SA 4.0 (Wikipedia articles) |
| Learn cards — nutrition | 2 | Public domain (USDA FoodData Central SR Legacy) |
| Waste — emission factors | 1 | CC BY 4.0 (OWID grapher data; underlying study Poore & Nemecek 2018, Science) |
| Waste — price factors | 1 | Public domain (BLS Average Price Data, U.S. government work) |
| Waste — loss factors | 3 | Public domain (USDA Economic Research Service) |
| Packs — budget | 3 | 2 public domain (BLS, USDA); 1 FAO-published dataset (flag 1) |
| Packs — seasonal | 3 | 2 public domain (USDA); 1 NANASP chart (flag 3) |
| Packs — use-it-up | 1 | Internal project data, FridgeLuck PR #97 (flag 2) |

No card, factor, or pack item cites an absent or licence-empty source — the
SCHEMA.md join checklist requires that, and the validators enforce it on every
run.

### Flags for the operator (matter for external redistribution, not internal app use)

1. **FAO budget source** — the budget packs' third source is an FAO-published
   dataset; FAO terms of use permit reuse with attribution, but the source
   file itself carries no explicit licence line.
2. **Use-it-up packs** — built from FridgeLuck's own PR #97 output; external
   redistribution terms for that dataset are not yet set.
3. **Seasonal packs (NANASP chart)** — the underlying chart is a grantee work
   supported by an ACL grant, not a U.S. government work. The seasonal packs
   reproduce the uncopyrightable region-produce-month facts only, not the
   chart's expression. If any seasonal pack text is later found to mirror the
   chart's wording, that pack must be rewritten before external release.
