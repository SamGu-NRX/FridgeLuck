# Pinned FLIngredientFacts snapshot

| field | value |
| --- | --- |
| Canonical source | branch `overhaul/ingredient-facts` — PR #127 (read-only; owned by its own task) |
| Pinned from commit | `b0deecce36bf6ee91e6f5933e746d75466165288` |
| Files pinned verbatim | `data/ingredient-facts/identities.json`, `data/ingredient-facts/facts.json` |
| Byte-for-byte | no edits; `git show origin/overhaul/ingredient-facts:data/ingredient-facts/<file>` reproduces both files exactly |
| Pinned by | eval scorecard Part B (`eval/scorecard-b-allergens`) — 2026-10-12 |

## Why a snapshot

`evaluation/CONTRACTS.md` records the facts branch as the canonical source of
ingredient-composition evidence for allergen/diet claim verdicts, and forbids
this suite from clearing claims through its fixture alias table. The suite may
not push to or edit the canonical branch, and suite runs must be reproducible
from committed inputs — so the exact bytes this suite was verified against are
pinned here and provenance is recorded in `rs.py` (`PINNED_FACTS_HEAD`).

## Load precedence

1. `<scored tree>/data/ingredient-facts/` — when the tree being scored ships
   the dataset itself (same schema), it wins (freshest, tree-specific).
2. This pinned snapshot — otherwise.

If neither is present or a candidate fails validation, the scanner holds
every dependent claim (fail closed) with a reason naming the absent or
incomplete source. See `rs.py` (`FLIngredientFacts.load`).

## Re-verification duty

When the canonical source moves (`overhaul/ingredient-facts` lands new
commits), re-run the dataset's conformance runner on the new head, re-pin
verbatim, and update this file and `PINNED_FACTS_HEAD` in one commit. Never
edit the pinned JSON by hand.
