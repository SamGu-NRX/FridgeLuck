# canon/ — pinned food-safety rulebook snapshot

`rules.json` here is a verbatim snapshot of the canonical rulebook
`data/food-safety/rules.json` from branch `overhaul/food-safety-canon`
(draft PR #126), fetched read-only at head
`2e03467d3b0996d81bde3b9c6f3f80007b9d54ba` on 2026-10-11. This suite
never edits it; the canonical owner (fl-root-food-safety-f1) owns the
content under `data/food-safety/`.

## Precedence (rs.CanonRulebook.load)

1. `<scored repo root>/data/food-safety/rules.json` — the live canon,
   once PR #126 merges and the scored tree carries it;
2. this pinned snapshot `evaluation/suites/recipes/canon/rules.json`.

If neither can be loaded or the file fails validation (wrong
schema_version, a doneness/reheating rule without a usable check, a
food_class outside the eight RS FSIS classes), doneness validation
FAILS CLOSED: every recipe with any safety-relevant signal is a
violation until the canon is available. The suite never substitutes
its own temperature table.

The executable linter (`packages/FLFoodSafety`, Swift) cannot be
invoked from this Python suite on the scored tree; rulebook DATA is
the integrated source of truth. Lint checks that would require the
executable linter are reported UNVERIFIED-NATIVE (see README.md).
