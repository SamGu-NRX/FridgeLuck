# Validation — breakfast-2026-10 originals packet

Every command below was run in this packet directory. Recorded outputs are
verbatim from the final verification pass on 2026-10-16.

## Environment

- Repo checkout: `SamGu-NRX/FridgeLuck`, branch
  `obv/burst11-fridgeluck-recipes-breakfast`, based on `alpha` @ `ef236fc`.
- Pinned recipes suite at `/tmp/fl-suite/evaluation/suites/recipes`
  (`rs.py`, `bands.py`, `allergens.json` are the pinned copies from
  `data/recipe-sources/world-2026-10/src/` — this checkout's
  `data/recipes/suite` copy predates the pinned snapshot; the pinned
  `canon/rules.json` snapshot is from
  `overhaul/food-safety-canon @ 2e03467d:data/food-safety/rules.json`).
  The suite directory is session-local under `/tmp`; the restore commands
  are in README "Verifying".
- Pinned FNDDS household-measure table from PR #50's MassConversionKit
  evidence at `/tmp/mck.json` (7,288 portion rows), restored with
  `git show origin/obv/fl-l2-mass-evidence:scripts/data/reference/household_measures/mass_conversion_table.json`.

## 1. Build

```
$ python3 src/build_batch.py
canon: canon rulebook: suite-pinned snapshot canon/rules.json (overhaul/food-safety-canon @ 2e03467d)
built 30 recipes -> .../breakfast-2026-10/originals.jsonl
lines: 205/234 resolved; vegetarian 28/30; fast15 19; vegan-or-gf-known 22
```

205 of 234 ingredient lines resolve through record-carried FNDDS
conversions; the remaining 29 are recipe-stated metric masses and unknown
("to taste") lines, each carrying its own evidence kind or note.

**Determinism:** a second build produces a byte-identical
`originals.jsonl` — sha256 `d47783add5b53130fc5d9a5563dbd1f8d9b2aca52bf90fc6b3f3ee33efac622c`
before and after.

## 2. Packet checker (rights, recomputed quantities, pinned lint, gates)

```
$ python3 src/check_batch.py
checked 30 records
vegetarian 28/30 (93.3%); slots {'breakfast': 30}; fast15 19
PASS: rights, quantities, pinned lint, and release gates all clean
```

The checker independently recomputes every household-line grams value from
the pinned FNDDS table and validates each `conversion_ref` against the row
that supports it (fdcId-checked), runs the pinned `rs.lint_recipe` over all
30 records with the fixture-plus-extension classification table and the
pinned canon, enforces the rights manifest, and applies the release gates
(vegetarian ≥ 1/3, claims gate, FSIS-noted extension classes, ≥12 recipes
at ≤15 minutes, >10 known-composition vegan/GF recipes, no title
collisions inside the batch or against `data/recipes/corpus.jsonl`).
Exit code 0.

## 3. Planted-failure tests

```
$ python3 src/test_check_batch.py
CAUGHT   stripped egg safety check -> fl-bfast-0002: R3 required doneness class egg (minimum 160 F, rest 0 min) has no thermometer check naming that class and minimum — checks must cover each ingredient's ACTUAL class, not an unrelated one
CAUGHT   deleted check step -> fl-bfast-0002: R3 required doneness class egg (minimum 160 F, rest 0 min) has no thermometer check naming that class and minimum — checks must cover each ingredient's ACTUAL class, not an unrelated one
CAUGHT   corrupted carried grams -> fl-bfast-0001: ingredient[1] 'spinach' carries grams 82.0, but the pinned FNDDS row fdcId 2709614 supports 50.0
CAUGHT   forged conversion_ref -> fl-bfast-0001: ingredient[1] 'spinach' cites conversion_ref 'fndds:000000000', which is not the pinned row fndds:2709614 supporting it
CAUGHT   deleted rights-manifest entry -> fl-bfast-0001: source_ref 'fl-breakfast:spinach-tofu-scramble-with-rice' has no rights-manifest entry
CAUGHT   downgraded rights_status -> fl-bfast-0001: rights_status 'scraped' is not 'original'
CAUGHT   blanked rights author -> fl-bfast-0001: rights-manifest entry 'fl-breakfast:spinach-tofu-scramble-with-rice' missing 'author'
CAUGHT   unsupported cuisine 'french' -> fl-bfast-0001: cuisine 'french' outside the suite vocabulary
CAUGHT   broken cuisine/world_cuisine mapping -> fl-bfast-0001: cuisine 'italian' does not match the region mapping for 'korean'
CAUGHT   unknown packet region 'french' -> fl-bfast-0001: world_cuisine 'french' is not a packet region
CAUGHT   unknown quantity with blank note -> fl-bfast-0001: ingredient[8] 'salt' unknown quantity carries no note
CAUGHT   zero source_grams -> fl-bfast-0001: ingredient[0] 'tofu' source_grams 0 is not a positive mass
CAUGHT   unsubstantiated diet claim -> fl-bfast-0001: ships claims the packet does not substantiate
CAUGHT   broken id sequence -> record[4]: id 'fl-bfast-9999' breaks the fl-bfast-NNNN sequence
CAUGHT   meal slot 'brunch' -> fl-bfast-0001: meal_slots ['brunch'] outside the declared slots
CAUGHT   fast15 pool shrunk below 12 -> brief gate: only 7 recipes are 15 minutes or less; at least 12 are required
CAUGHT   known vegan/GF pool shrunk to 10 -> brief gate: only 10 recipes have known composition and are intended vegan or gluten-free; more than 10 are required
CAUGHT   title colliding with data/recipes/corpus.jsonl -> brief gate: fl-bfast-0001 title 'Ackee And Saltfish' collides with a title already in data/recipes/corpus.jsonl
CAUGHT   duplicate title inside the batch -> brief gate: duplicate normalized title 'spinach tofu scramble with rice' inside the batch
19/19 planted failures caught
```

Exit code 0. `python3 -m py_compile src/*.py` also passes.

## 4. Pantry reach (informational, not a gate)

```
$ python3 src/reach_report.py
recipes: 30; pantries: 10
  starter_apartment: now 1, near 3
  family_freezer: now 0, near 3
  vegan_pantry: now 0, near 5
  gluten_free_household: now 1, near 3
  student_minimal: now 1, near 4
  baker: now 1, near 4
  pescatarian: now 0, near 3
  keto_household: now 0, near 4
  south_asian: now 0, near 5
  empty_nesters: now 0, near 3
```

Method and disclosures are in `reach-report.json` (`method` field) and the
README: staples = `compile_bundle.STAPLE_KEYS`, pantry candidates =
reach-v2 exact written-name transforms, line identity = the app's
`name-mappings.json` (comma-head fold disclosed), exact = 0 required lines
missing, near = at most 2 (the reach-v2 tiers), no similarity guessing,
unresolved lines fail closed. No recipe carries an unresolved line. The
low cookable-now counts are a property of the fixture set — the ten
pantries were authored for the lunch/dinner packet (pantry-2026-10) and
carry almost no breakfast-specific ingredients — not a defect of the
packet; per-pantry `top_missing_ingredients` in `reach-report.json` lists
what a breakfast-oriented fixture set would need.

## 5. Composition

```
regions: american 4, british 1, caribbean 2, chinese 1, eastern_european 1,
         indian 4, japanese 3, korean 2, latin_american 2, mediterranean 2,
         middle_eastern 4, north_african 1, thai 1, vietnamese 1,
         west_african 1
cuisines: american 7, asian 8, indian 5, italian 1, mediterranean 7, mexican 2
slots: breakfast 30
vegetarian (canon-aware, conservative): 28/30 (93.3%)
fast15 (15 minutes or less): 19/30
vegan-or-GF with known composition: 22/30
minutes: min 5, max 35
rights entries: 30; FNDDS extract: 36 portion rows; extension: 35 rows + 36 aliases
```

## Not checked

- No Apple host in this environment: the corpus is data-only (Python build +
  JSONL), so nothing here exercises Xcode or hosted macOS CI. The records
  are RS v1 and were validated with the pinned recipes suite, but no
  bundle-v2 compile of this packet (through the bundle compiler) has been
  run — that integration is deliberately not attempted here because this
  packet ships originals, not a compiled bundle.
- The suite-runner validator from PR #113 cannot run on this packet as-is
  (hardcoded `fl-original-NNNN` IDs and `overhaul/original-recipes`
  provenance form); see README "Suite-runner integration gap". The packet
  checker covers the same checks with packet-local evidence paths, and the
  planted-failure tests demonstrate it detects the defect classes that
  matter.
- Sensory plausibility of 30 recipes was not taste-tested; the quantities
  are internally consistent with pinned conversions, but flavor-level
  accuracy is the author's judgment.
- The `/tmp` pinned inputs (suite snapshot, MCK table) are session-local;
  they were re-verified against their pinned git sources in this pass, and
  the restore commands are recorded in README "Verifying".
