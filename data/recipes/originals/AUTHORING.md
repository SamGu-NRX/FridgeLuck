# Authoring guide — FridgeLuck original recipe corpus

You are writing **original recipes** for the FridgeLuck corpus: your own words,
your own method, evidence-backed quantities. Format is **RS** (the corpus grammar
defined by `evaluation/suites/recipes/rs.py`, suite C, PR #88). Read a working
example in `evaluation/suites/recipes/authored.json` and this directory's
smoke-test files before your first batch.

Everything here is enforced by tooling: `tools/validate.py` is the gate, and it
never opens unless `tools/nutrition.py --write` ran first.

## 1. Absolute rules

1. **Original writing.** Every `title`, `step.text`, and ingredient phrasing is
   yours. No copying from bundled recipes, no BBC text, no scraped pages. Never
   fetch or scrape recipe websites (SPEC 10). Bundled dishes are read via
   `tools/bundled.py --dump` only, for the Part 1 rewrite.
2. **Untested marking.** Every file carries `"test_status": "untested"`. These
   recipes have not been cooked. Never claim otherwise. The corpus ships with
   untested recipes and honest claims.
3. **Rights.** Each recipe records `"source_ref": "orig:authored:<id>"` and an
   entry in `<part>/tables/rights-manifest.json`:
   `{"schema": "fl-rights-manifest/1", "records": {"orig:authored:<id>":
   {"kind": "original-authorship", "origin": "authored-for-frideluck", "status": "clear", "access_date": "<ISO date>"}}}`.
   One record per recipe, status clear, fail-closed otherwise.
4. **Safety over looks.** FSIS thermometer checks (suite R3 + the strict layer)
   are mandatory where flesh, eggs, or leftovers appear. Use the temperature
   table in section 5.
5. **Claims only when machine-true.** Only these claim names exist:
   `vegetarian`, `vegan`, `gluten-free`, `dairy-free`, `nut-free` (hyphenated) — and only
   when BOTH the suite scanner AND the compound table recompute them clean.
   Evidence format: `{"kind": "allergen_scan", "conflicts": []}`. If the tools
   disagree with your intuition, the tools win.
6. **Honest unknowns.** `qty.kind = "unknown"` is reserved for true
   to-taste/garnish lines (salt to taste, cilantro for garnish). Never use it
   to dodge a conversion. Every recipe keeps ≥ 95% of lines resolved to grams.

## 2. File layout — one file per recipe, per part

    data/recipes/originals/<part>/<id>.json
    data/recipes/originals/<part>/tables/conversions.json        # reviewed gram refs
    data/recipes/originals/<part>/tables/nutrition-map.json      # name -> fdc_id
    data/recipes/originals/<part>/tables/compound-allergens.json # optional extras
    data/recipes/originals/<part>/tables/rights-manifest.json
    data/recipes/originals/<part>/tables/cost-assumptions.json   # for budget meals
    data/recipes/originals/<part>/README.md                      # part-specific notes

Parts and id prefixes (ids are `<prefix>-<kebab-title>`, unique corpus-wide):

| Part dir | prefix | cuisine (suite value) | covers |
|---|---|---|---|
| `part1-rewrite` | `rw-` | any of the six | rewrites of the 166 bundled recipes |
| `east-southeast-asian` | `ea-` | `asian` | Chinese, Japanese, Korean, Thai, Vietnamese, Filipino, Indonesian, Malaysian |
| `south-asian` | `sa-` | `indian` | Indian (all regions), Pakistani, Sri Lankan, Bangladeshi, Nepali |
| `middle-east-north-africa` | `me-` | `mediterranean` | Levant, Turkey, Greece, Iran, Maghreb, Egypt |
| `latin-american` | `la-` | `mexican` | Mexico, Peru, Brazil, Argentina, Caribbean, Central America |
| `european-american` | `eu-` | `american` or `italian` | US, Italy, France, Spain, Portugal, UK, Ireland, Germany, Eastern Europe, Nordic |

The suite's cuisine field is coarse by design (fixture constraint): put the
true cuisine in `cuisine_detail` (e.g. `"french"`, `"sichuan"`, `"oaxacan"`).

## 3. Recipe shape (additive fields beyond RS)

RS core: `rs_version`, `id`, `title`, `cuisine`, `minutes`, `servings`,
`ingredients[]` (name, qty), `steps[]` (text, optional timer_min), optional
`cuisine_note`, `meal_slots`, `safety`, `source_ref`, `claims[]`,
`rights`, `provenance`. Suite linter rules R1–R5 apply.

Originals add (all hard-checked unless noted):

- `"family"`: the part's family label (validator warns).
- `"cuisine_detail"`: string, required.
- `"equipment"`: list of strings, required, ≥ 1 (e.g. `["skillet", "chef's knife"]`).
- `"nutrition_per_serving"`: written by `tools/nutrition.py --write`. Never
  hand-edit; recompute is checked.
- `"test_status": "untested"`: required.
- `"tags"`: subset of `weeknight, budget, high-protein, one-pot, sheet-pan,
  leftovers, make-ahead, freezer-friendly, use-it-up` plus
  `use-it-up:<ingredient>` companions (e.g. `use-it-up:spinach`). Diet claims do
  NOT go here — they live in `claims`.
- `"cost_per_serving_usd"`: `{"value": 2.1, "assumptions_ref": "tables/cost-assumptions.json"}`
  — required for budget-tagged recipes; arithmetic shown in the part README.
- `"replaces": {"bundled_id": ..., "change": "<what you fixed>"}` — Part 1 only.

Ingredient lines: lowercase, singular-ish canonical names (`chicken thighs`,
`soy sauce`), one line per ingredient (repeats are summed — write them once).
Quantity `kind`: `household` (value + unit + conversion_ref + grams_per_unit),
`weighed`/`source_grams` (grams only — only for actually-weighed things), or
`unknown` (rare, honest). If `value × grams_per_unit` disagrees with `grams`
by >5%, the validator soft-flags it — prefer omitting `grams` and letting the
conversion table speak.

## 4. Conversions and nutrition

- Suite fixture conversions exist for the 50 core ingredients — reuse those refs.
  New refs go in your part's `tables/conversions.json` shard with a
  `basis` note (e.g. "1 medium carrot ~61g USDA"). Never redefine a suite ref.
- Nutrition mapping: for every quantifiable ingredient name, add
  `"maps": {"carrot": {"fdc_id": 170899}}` in `tables/nutrition-map.json`,
  chosen from in-repo committed data only (`tools/bundled.py` dumps names +
  fdc_ids; or `sqlite3` the extracted catalog). Match the closest plain form
  (fresh → raw entries, cooked rice → cooked). Record matches you were unsure
  about in the part README. Unmapped lines are listed in the recipe's
  `nutrition_per_serving.unmapped_ingredients` and drag `coverage` down.
  Two sources are accepted, both committed in-repo (never the live web):
  - `{"fdc_id": 170899}` — a row of the bundled USDA catalog sqlite.
  - `{"bundled_id": "1"}` — the app's shipped 50-ingredient table in
    `data.json` (per-100g macros at the pinned alpha). Use it when the
    catalog has no clean row (e.g. plain whole eggs) and data.json has the
    exact ingredient.
  Known catalog traps (do not map into these):
  - fdc 168883 "White Rice (Cooked)" carries DRY-rice macros (370 kcal,
    81.7 g carbs per 100 g). Measure rice dry (`dry_rice_cup`,
    fdc 168877) instead.
  - There is no plain whole-egg row; use `{"bundled_id": "1"}` for eggs.
- **Sodium honesty.** If an ingredient matching a salty pattern (fish sauce,
  soy, stock, salt, cheese, cured meats, ...) is unmapped, the computed
  sodium under-counts. `tools/nutrition.py` writes
  `"sodium_basis": "incomplete-salty-unmapped"` with the offending list, and
  `tools/validate.py` recomputes and enforces it — the app must not present
  that sodium as a trustworthy number. Do not "fix" it by mapping fish sauce
  to soy sauce: leave it unmapped and let the flag speak.
- `coverage ≥ 0.8` is the craft target; below 0.65 explain why in the README.
- **One corpus, one source.** The corpus-wide merge rejects an ingredient
  name mapped to different sources in two parts. Before adding a mapping
  for a name that likely appears in other parts (ground beef, potatoes,
  rice, chili flakes, eggs, soy sauce, ...), check the existing parts'
  `tables/nutrition-map.json` shards and reuse their source. Conflicts
  found at join time are resolved by the lead: catalog row first
  (`fdc_id`), the app's bundled row (`bundled_id`) when the catalog has no
  clean match for the plain form (e.g. only a 70/30 ground-beef variant);
  the minority shards are then realigned and recomputed.

## 5. Food safety (the FSIS ladder)

Thermometer checks are `safety` objects on the step where doneness matters:
`{"class": "meat_poultry", "temp_f": 165}` — with the C in the text, e.g.
"Chicken registers 165°F (74°C) at the thickest piece on a thermometer."

| class | temp_f | covers |
|---|---|---|
| `meat_poultry` | 165 | chicken, turkey, duck — including GROUND poultry |
| `meat_ground` | 160 | ground beef/pork/lamb, fresh sausage |
| `meat_whole_cut_pork` | 145 | pork chops, tenderloin (rest is fine) |
| `meat_whole_cut_red` | 145 | beef/lamb whole cuts |
| `flesh_fish` | 145 | fish flesh |
| `flesh_shellfish` | 145 | shrimp/prawns |
| `egg` | 160 | dishes where eggs set; for runny yolks use pasteurized eggs and say so |

Leftover-reheat steps: `{"class": "leftover", "temp_f": 165}` and
`"reheat": true` on the step, text naming 165°F (74°C).

Forbidden phrasing (suite regex will reject): "cook until done", "until no
longer pink" is fine ONLY with a check… (run the linter; it tells you), avoid
"cooked through", "fully cooked" without a thermometer check. Prefer
observable cues + a check: "until golden, about 4 minutes" + thermometer line.

Eggs in sauces (carbonara, custards): temper gently, target 160-165°F, or use
pasteurized eggs for anything deliberately runny — the step text says which.

## 6. Step craft

- Use the suite's exact ingredient-alias names for core ingredients
  (`eggs`, `cooked rice`, `green onions`, `soy sauce`, ...) — the suite scanner
  matches names exactly; part-specific names carry no suite class (your strict
  shard must map any flesh-variant name to a flesh class).
- Split steps at real action boundaries: a step does one or two things. If a
  reader pauses, that's two steps. Aim 8-12 steps for a weeknight dish; hard
  cap 320 characters per step.
- Timers only where a real one helps: 1-240 min, `timer_min` integer. Passive
  simmers get timers; "stir for 30 seconds" does not. Sum of timers may not
  exceed `minutes + 30` (soft).
- Text reads at arm's length: imperative, concrete, no marketing voice, no
  "simply", no "delicious". Explain the WHY when it changes behavior ("stir
  constantly or the roux will scorch").
- Doneness cues > clocks where possible; clocks > vague adverbs.

## 7. Titles, names, dedupe

- Real dish names as a cook would say them; no clickbait, no ALL-CAPS, ≤ 80
  chars. Never reuse a bundled dish name verbatim — check
  `BUNDLED-TITLES.txt` (refresh with `python3 tools/bundled.py --titles`).
- No two original recipes may share a normalized title; near-duplicates
  (title ≥ 60% token overlap AND ≥ 50% ingredient overlap) get flagged by
  `tools/dedupe_check.py` and resolved by the join step. When a dish is
  genuinely the same as a sister-part's dish, drop yours.

## 8. Workflow (every batch)

1. Write 8-10 recipe files in `<part>/` + extend your `tables/` shards.
2. `python3 data/recipes/originals/tools/nutrition.py --write --part <part>`
3. `python3 data/recipes/originals/tools/validate.py --part <part>` → exit 0, zero HARD lines.
4. `python3 data/recipes/originals/tools/dedupe_check.py --part <part>` → review flags.
5. Commit (Sam Gu author + the co-author trailer; see the branch's git log for
   the exact trailer), push to the part branch, keep the draft PR current.

Never commit with `HARD` violations present. Soft warnings are logged and
addressed in batches; recompute drift in `--check` mode is hard.
