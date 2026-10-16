# everyday-2026-10 — validation run record

Run date: 2026-10-15 (Linux sandbox, Python 3.13, no Xcode —
this slice is data + Python tooling only; Swift-side verification is hosted CI).

## Recipe files

- originals.jsonl sha256 `ffd7d6c9818b0ffd147c50d1e41a69925f461881e43ac92f625068004d9b040d` (24 recipes)
- converted-144.jsonl sha256 `df44d18e08ac067fdd560f7f2a0c8b5fb5ceac33b7a185fad04fa82f47a46fe9` (161 recipes)
- rights evidence regenerated for all 185 recipes; per-file hashes in
  evidence/rights.json match the two files above.

## Inputs

- USDA catalog: `apps/ios/Resources/usda_ingredient_catalog.sqlite`
- bundled legacy names: `apps/ios/Resources/data.json`
- #113 shipped corpus (dedupe + 12-word overlap reference): branch
  `obv/burst5-fridgeluck-spec-recipes`, `data/recipes/corpus.jsonl`
- legacy #144 source (dedupe + 9-word overlap reference): `legacy-144.json`
  (rows 167-327 of PR #144's apps/ios/Resources/data.json, byte-equal)
- pinned suite: revision `26c7004` (allergen classes, conversions, validator helpers)

## Commands and results

1. Unit tests (`python3 tools/test_check_everyday.py`):

    Ran 32 tests in 0.009s

OK

   32 tests: 23 original planted-failure/controls plus 9 regression tests from
   the PR #163 review (evidence portability, legacy row-array dedupe input,
   loud external-input skips, word-boundary protein matching). Before the
   fixes, the new tests fail: the committed evidence pins absolute paths, the
   dedupe input raises AttributeError on PR #144's row array, fish sauce
   reclassifies a poultry endpoint, and `external_skips` does not exist.

2. Slice checker + pinned validator:

```
python3 tools/check_everyday.py --dir . \
  --catalog ../../../apps/ios/Resources/usda_ingredient_catalog.sqlite \
  --bundled ../../../apps/ios/Resources/data.json \
  --corpus113 <#113 checkout>/data/recipes/corpus.jsonl \
  --legacy144 legacy-144.json \
  --validate-suite <suite checkout at 26c7004> \
  --corpus-tools <#113 checkout>/data/recipes/tools
```

        slice-local checker: 0 error(s)
    slice: 24 originals + 161 converted = 185 recipes
    VALIDATION GREEN: rights-clear corpus lints clean, claims verified, ids unique and in-scheme, no quarantined recipe in corpus.jsonl
    measured: recipes=185 resolved_pct=100.0 bands=14/14

3. Without the external dedupe inputs, every skipped check is printed and
   counted (excerpt from a bare `--dir . --catalog ...` run):

    SKIPPED R-E #113-corpus dedupe + 12-word overlap (pass --corpus113)
SKIPPED R-E #144-legacy dedupe + 9-word overlap (pass --legacy144)
SKIPPED bundled-catalog legacy names + overlap (pass --bundled)
...
slice-local checker: 196 error(s) (3 external check(s) skipped)

## Review-fix verification

- evidence/rights.json diff vs the originally committed file is exactly the
  two `recipes_file` lines (absolute dev paths -> bare filenames); the
  recipes_sha256 values are unchanged.
- `python3 tools/build_slice.py` after the protein-matching fix reproduces
  converted-144.jsonl byte-identical (sha256 -c OK), so no shipped recipe
  changed.
- The checker passes on a fresh checkout of this branch at an arbitrary
  filesystem path (verified in a detached worktree), which the committed
  evidence previously prevented.
