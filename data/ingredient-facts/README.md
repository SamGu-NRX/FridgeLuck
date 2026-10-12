# data/ingredient-facts

Canonical ingredient-fact dataset for FridgeLuck. Owned by the `overhaul/ingredient-facts`
branch (draft PR into `alpha`). Read by the `FLIngredientFacts` Swift package and mirrored
independently by the TypeScript and Python conformance runners.

## Files

- `identities.json` — canonical ingredient keys → display name, synonyms/aliases,
  USDA FDC id (from `apps/ios/Resources/usda_ingredient_catalog.sqlite` and
  `scripts/data/catalog`), app local ids (from the `ingredients` map in
  `apps/ios/Resources/data.json`), and preparation forms (a form is a distinct
  entry when its facts differ, e.g. generic tamari vs certified gluten-free tamari). **Exists.**
- `facts.json` — per canonical key: components (for compounds) with a certainty level
  (`certain` / `typical` / `variable` / `unknown`) and evidence; allergen facts; diet
  facts. **Exists.**
- `coverage.json` — generated corpus coverage record (bundled recipes + originals
  branches). **Exists.**
- `tools/build_dataset.py` — generates and validates the two JSON files. **Exists.**
- `conformance/cases.json` — shared JSON cases (ingredient, restrictions, expected
  result) that Swift, TypeScript and Python consumers each run. **Exists** (43 cases).
- `conformance/runners/typescript/run_conformance.ts` — Bun runner, no npm
  dependencies. **Exists.**
- `conformance/runners/python/run_conformance.py` — Python runner, stdlib only.
  **Exists.**

## identities.json schema (pinned)

```jsonc
{
  "version": 1,
  "ingredients": [
    {
      "key": "tamari",                    // canonical key, kebab-case, unique
      "display": "Tamari",
      "synonyms": ["tamari sauce"],       // optional; globally unique across the dataset
      "usdaFdcId": 2644282,               // optional; REAL catalog id, omitted when absent
      "usdaRef": "Tamari (Soy Sauce)",    // optional; matched catalog row name
      "usdaNote": "...",                  // optional; why this row / why closest
      "appLocalIds": [7],                 // optional; ids from the data.json ingredients map
      "note": "...",                      // optional
      "forms": [                          // optional; distinct product/preparation forms
        { "key": "tamari-certified-gf", "display": "Tamari (certified gluten-free)",
          "synonyms": ["certified gluten-free tamari"] }
      ]
    }
  ]
}
```

Every key (identity or form) must have a fact entry; every form key is globally unique.
FDC ids are never invented: when the bundled catalog has no defensible match the fields
are omitted.

## facts.json schema (pinned)

```jsonc
{
  "version": 1,
  "facts": [
    {
      "key": "tamari",
      "class": "condiment",              // simple entries only; compounds omit this
      "components": [                    // compounds only
        { "key": "soybeans", "certainty": "certain", "evidence": { } }
      ],
      "compositionComplete": false,      // compounds only; true only when the component
                                         // list is closed for the generic product
      "allergens": {
        "soy": { "state": "contains", "evidence": { } }
        // state: contains | free | unknown
      },
      "gluten": { "state": "unknown", "evidence": { } },   // separate property, not an allergen
      "diets": {
        "vegetarian": { "state": "violated", "evidence": { } }
        // state: allowed | violated | unknown
      }
    }
  ]
}
```

## Evidence payload (pinned)

```jsonc
{ "kind": "usda", "ref": "2644282", "note": "catalog row: Tamari (Soy Sauce)" }
```

`kind` is one of `usda` (ref: fdc id), `label` (ref: the product or label claim),
`reference` (ref: URL or document title), `recipe` (ref: corpus path + recipe id),
`standard` (ref: short slug naming the composition or regulatory standard).
`ref` and `note` are always present.

**Absence never rests on catalog or recipe evidence.** A fact asserting absence —
allergen/gluten state `free` or diet state `allowed` — must carry kind `label`,
`reference` or `standard`. `usda` and `recipe` evidence may support presence
(`contains`/`violated`) and `unknown` states, but a nutrient-catalog mapping or a recipe
occurrence alone never proves an allergen is absent. The generator, the Swift loader
and both runners enforce this and reject violations at load time.

## Rules

- A variable or unsourced property is `unknown`, never `false`.
- Every non-unknown fact carries evidence.
- Evidence is complete: every evidence object — fact-level and component-level — carries
  a known `kind` and non-blank `ref` and `note`. The generator, the Swift loader and both
  runners reject violations at load time
  (`bash data/ingredient-facts/conformance/runners/negative_checks.sh` replays the
  mutations as a check).
- Evidence must be real: cite the catalog row, document, recipe corpus entry or label
  claim it came from. Never invent an fdc id or URL.
- **Wheat and gluten are independent axes.** Wheat is one of the nine FDA major
  allergens with its own evidence; gluten is a separate property with its own evidence.
  A gluten-free label supports the gluten property only — the FDA gluten-free labeling
  rule permits some processed wheat-derived ingredients in gluten-free foods, so the
  label never establishes wheat absence ([FDA gluten-free labeling Q&A, General
  question 6](https://www.fda.gov/food/nutrition-food-labeling-and-critical-foods/questions-and-answers-gluten-free-food-labeling-final-rule)).
  Wheat evidence never substitutes for gluten evidence, in either direction.
- The nine FDA major allergens (milk, egg, fish, crustacean shellfish, tree nuts,
  peanuts, wheat, soy, sesame) plus gluten as a separate property. Diets: vegetarian,
  vegan, pescatarian, gluten-free, dairy-free.
- Generic tamari is not gluten-free without product evidence, and no gluten-free label
  settles its wheat status — only a product ingredient declaration does. Stock cubes
  and bouillon vary by product, so their uncertain facts stay unknown.

## Sources

- `apps/ios/Resources/usda_ingredient_catalog.sqlite` (`ingredient_catalog` table:
  `fdc_id`, `normalized_name`, `alt_names_json`, …)
- `scripts/data/catalog` (catalog build scripts and overrides)
- `apps/ios/Resources/data.json` (bundled: 166 recipes, 50 core ingredients)
- Original recipe corpora on `fleet/fl-recipe-originals*` branches
- Product label claims, cited as such
