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

## Re-verification (r3, part A — eval/scorecard-a-safety-lint)

Re-verified 2026-10-12: branch `overhaul/food-safety-canon` (PR #126)
has moved past the CONTRACTS.md-pinned `a23439c` and now sits at head
`0b8ddca4df9ab828ecbe468f33d1bcce17a5b6c3` ("Join P5: fix lists for the
nine food-safety review targets"). Consumed read-only. The derived class
minimums and required rests are IDENTICAL between this snapshot
(`2e03467d`) and `0b8ddca` for all eight FSIS classes (poultry 165, ground
160, whole cuts 145 + 3-minute rest, fish/shellfish 145, egg 160,
leftovers 165), so this snapshot remains a faithful pin; the head-to-head
diff is citation/summary prose plus one new `cooling_window` rule the RS
linter does not consume. Updating this snapshot and the CONTRACTS.md row
to the new head belongs to the canon/join owner (out of this branch's
file scope).
