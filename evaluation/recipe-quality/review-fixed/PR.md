## What changed and why

This PR is the cook's review of the 189 agent-fixed catalog recipes from the
three existing fix packets (`rubric.json`, `amounts-a.json`, `amounts-b.json`),
plus the 14 corrections the review found. Data-only; no app code.

- `evaluation/recipe-quality/review-fixed/review.py` + `findings.json` — the
  audit harness: recompiles all 189 packet records with the real compiler,
  screens them with the rubric audit, and records per-recipe `red_flags`.
- `evaluation/recipe-quality/review-fixed/REPORT.md` — the review: method,
  per-fix table with before → after numbers, findings left open on purpose
  (bone-in weights, documented sodium, intentionally light soups, audit false
  positives), verification, assumptions.
- `evaluation/recipe-quality/review_fixed.py` — the fix-packet generator
  (one correct answer per fix, reasons and evidence per change, corpus-line
  sha256 pins, post-fix band verification).
- `data/recipes/fixes/review-fixed.json` — 14 fixes in the
  `fridgeluck/corpus-fixes/v1` shape: 1 quantity conversion repair (the almond
  bowl at 1,564 → 383 kcal), 10 servings corrections on over-portioned braises
  (250-350 g raw protein/serving → 167-200 g), 3 added lines the steps already
  name (birria garlic; bhurji butter + bread; kadhi rice), and 1 honest
  minutes promise (25 → 35).
- `data/recipes/fixes/test_review_fixed.py` — 14 tests pinning the packet:
  base sha256, shape/title/step-text preservation, canon conversion rows,
  compiled vocabulary/claims/Atwater/timer/thermometer gates, food safety +
  allergens, kcal/sodium/protein bands, and the repo validator over the
  patched corpus.

## How I checked it

Commands and results (this sandbox, CPython 3.13):

- `python3 -I evaluation/recipe-quality/review_fixed.py` — writes the packet,
  prints the post-fix table; every recipe 150-1300 kcal, ≤ 2300 mg sodium.
- `python3 -m pytest data/recipes/fixes/test_review_fixed.py -q` — **14 passed**.
- `python3 -m py_compile evaluation/recipe-quality/review_fixed.py` — clean.
- `python3 -I data/recipes/tools/validate_corpus.py` over the **unmodified**
  corpus — exit 0 (base corpus untouched by this PR).
- Validator over the **patched** corpus (in the test) — reports exactly the
  three expected pre-apply rights-pin refusals (fl-original-0284/0297/0395)
  and nothing else; see "Couldn't check".

## What I couldn't check

- **The rights pins are not yet applied.** The three fixes that add ingredient
  lines change the records the pinned authoring records cover, so the rights
  gate refuses them until the packet is applied and
  `pin_rights_evidence.py` regenerates `data/recipes/evidence/rights.json`
  from this packet. The test pins that expected pre-apply state exactly
  (three refusals, no other errors); post-apply the gate is designed to clear.
- **No Xcode in this environment** — the iOS side was not built. These are
  data-only changes; the repository's hosted macOS CI exercises the Swift
  side, and the portable tests cover the data gates.

## Assumptions

- The repo's conversion canon wins over kitchen instinct (bread_slice 30 g,
  butter_tbsp 14 g, garlic_clove 3 g, dry_rice_cup 185 g, almonds_cup 145 g).
- For the ten braises, "servings 2 → 3" is the honest label for the pot as
  written; cutting the meat was the alternative and rejected.
- Household additions stay at quantities a home cook would actually use.
