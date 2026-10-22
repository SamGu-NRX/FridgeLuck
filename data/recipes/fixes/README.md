# Corpus fixes — applied to the corpus

The fix packets in this directory (`amounts-a.json` #195, `amounts-b.json`
#196, `rubric.json` #197) reviewed and pinned their base records but
deliberately did not touch the shipped bundle. `data/recipes/tools/
apply_corpus_fixes.py` is the rebuild step that applies them to
`data/recipes/corpus.jsonl`.

## What was applied (burst12 rebuild)

All three packets, every fix:

| file | packet | fixes | rights-pin fixes |
|---|---|---|---|
| amounts-a.json | burst11-fridgeluck-recipe-amounts-a | 86 | 3 (`fl-original-0028`, `-0033`, `-0035`) |
| amounts-b.json | burst11-fridgeluck-recipe-amounts-b | 85 | 0 |
| rubric.json | burst11-fridgeluck-recipe-rubric | 18 | 7 (`fl-original-0001`, `-0075`, `-0082`, `-0270`, `-0341`, `-0376`, `-0516`) |
| **total** | | **189** | **10** |

Nothing was skipped: every fix's `before_sha256` matched the corpus line it
pinned (validated in one dry run before writing), no two files target the same
recipe, and every fix record's `id` matches its target.

## Review packets (#214, #220)

`review-new.json` (2 step-time fixes) and `review-fixed.json` (14 fixes from
the cook's review of the 189 recipes above) were applied later with
`apply_corpus_fixes.py --packet review-new.json --packet review-fixed.json
--write`. Every fix's `before_sha256` matched the corpus line. The 14
review-fixed fixes pin the record amounts-a/amounts-b wrote, so each forms a
chain with that earlier fix rather than a second decision. Three
(`fl-original-0284`, `-0297`, `-0395`) change the ingredient-name list and
carry rights-pin revisions. The 16 recipes ship the next revision in
`data/recipes/revisions.json` (`compile_bundle.py --bump-revisions`).

## Fail-closed rules

The applier refuses to write unless all of these hold:

1. `before_sha256` — the SHA-256 of the corpus line's exact bytes — matches
   the pin in the fix file (the corpus moved under the packet → re-review,
   never force);
2. one recipe, one decision: two files fixing the same id refuse, unless the
   later fix's `before_sha256` pins the earlier fix's record (a follow-up
   review of that fix). A recipe's fixes must form one such chain;
3. the fix record's `id` matches the target id;
4. the derived rights-pin revisions cover exactly the fixes flagged
   `changes_rights_pin` — none skipped, none invented.

## Rights revisions (changes_rights_pin)

Ten fixes change a recipe's title or ingredient-name list (or its full body) —
the inputs the authoring record pinned at ingest covers. The recipes stay
FridgeLuck originals under **LicenseRef-FL-Original**: the revision is
FridgeLuck's own edit of its own text, performed in the open by the reviewed
fix packet — not new third-party content.

The pin lives in `data/recipes/evidence/rights.json` under `fl_revisions`
(derived from these fix packets by `data/recipes/tools/fl_revisions.py`, so
`pin_rights_evidence.py --check` reproduces it). The rights gate
(`rights_evidence.py`) accepts a recipe whose authoring record no longer
matches ONLY when the pinned revision describes the shipped record exactly —
same title, same ingredient-name hash, same full-body hash
(canonical sort-keys SHA-256). Any other body change still refuses; deleting
the revision or swapping its licence also refuses.
`data/recipes/tools/tests/test_rights_revisions.py` plants those violations.

One claim was stripped afterwards by `strip_unproven_claims.py` (the suite's
own fail-closed rule — it only ever removes claims the composition gate cannot
prove): `fl-original-0341` no longer claims vegetarian, because the rubric fix
added a `banana` line whose composition the suite allergen table does not
resolve. The revision pins tolerate exactly this delta (claim-list edits only);
the `stripped_claims` field on each revision records any removal.

## Re-running

The applier is one-shot by design: after the fixes land, a second
`--write` refuses every fix (`before_sha256` now points at the replaced
lines). A fresh checkout of the pre-fix corpus applies cleanly. To apply a new
packet on top of applied ones, name it with `--packet`; the chain and id rules
still check every committed packet. The corpus
state after this rebuild is what `validate_corpus.py` gates, and the
revision pins are what `pin_rights_evidence.py --check` verifies.
