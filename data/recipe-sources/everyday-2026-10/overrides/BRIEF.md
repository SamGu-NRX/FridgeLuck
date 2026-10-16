# Authoring brief: PR #144 rewrites (everyday-2026-10)

You are writing the JSON fragment that gives fresh cook-facing text to legacy
recipe records. The fragment is one JSON object whose keys are the legacy
numeric recipe ids (as strings) from your assigned range, each mapping to:

```json
{
  "167": {
    "title": "Fresh, specific dish name",
    "steps": [
      {"text": "Do some prep."},
      {"text": "Cook until a food thermometer reads 165 °F in the thickest piece.",
       "safety": {"class": "meat_poultry", "temp_f": 165, "method": "thermometer",
                  "source": "USDA FSIS Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11"}}
    ]
  }
}
```

## Inputs

- `overrides/recipes-144.tsv` — your recipes: `id  legacy-title  minutes  servings  ingredient-names`.
- `legacy-144.json` — full legacy rows: `[id, title, minutes, servings, [[ing_id, grams]...], [tags...], "1. step\n2. step...", x]`.
- The shipped #113 corpus (`data/recipes/corpus.jsonl` on branch
  `obv/burst5-fridgeluck-spec-recipes`) — the 12-word overlap reference.

The ingredient list is FIXED. You never change it; steps may only name those
foods (the only exceptions are "water" and "ice").

## Title rules

- Fresh and specific; never the legacy title, never a light rewording of it.
- Banned words in the title: casserole, gratin, lasagna/lasagne, strata,
  hotdish, shepherd's pie, cottage pie, fish pie, pot pie, moussaka,
  stuffing, and the word "bake" (the word "baked" is fine).
- No two recipes in your fragment may share a title.

## Step rules

- 4–8 steps per recipe, each 1–2 sentences, plain competent home-cook voice,
  concrete cues (sizzle, aroma, softened onion) for ordinary doneness.
- Restructure freely: combine legacy steps, reorder, reword. The checker
  fails on ANY 9-word run shared with the legacy instruction text and any
  12-word run shared with the #113 corpus — verify programmatically (below).
- Only name foods in the ingredient list (vocab names may be written with
  spaces: "soy_sauce" → "soy sauce"). Water and ice are the only extras.
- Proteins and their endpoints: egg 160, chicken 165, salmon 145,
  ground beef 160. Canned tuna, smoked salmon, and stocks are ready-to-eat
  (no check needed). Every other protein word is refused by the gate.
- Each protein gets ONE doneness step with a safety object, and the step
  text must be an affirmative thermometer sentence: it names "thermometer",
  a measuring verb (reads/reaches/registers), and the endpoint temperature.
- Never put two different proteins in the same step, and never use mixing
  verbs (mix, fold, combine, beat, stir in) in a step that names a protein.
- Banned on steps WITHOUT a safety object: the word "reheat"/"rewarm";
  any internal temperature (e.g. "160 °F"); doneness-by-look-or-touch on
  protein steps — "no longer pink", "juices run clear", "cooked through",
  "until set/done/firm", "are set", "is set", "fully set", "opaque",
  "no longer translucent", "flakes easily". All protein doneness lives in
  the thermometer step.
- Batch-leftovers-category recipes end with a storage step: chill extras,
  then a flagged reheat, e.g.
  `{"text": "Chill leftovers up to four days; reheat portions until a food thermometer reads 165 °F.", "reheat": true, "safety": {"class": "leftovers", "temp_f": 165, "method": "thermometer", "source": "…FSIS…"}.`
  Recipes in other categories must NOT use the word reheat.
- Vary the thermometer sentences across recipes; never reuse a 12-word
  sentence inside your own fragment.
- Ground beef: also fine to phrase "until a food thermometer reads 160 °F,
  crumbling as it browns". Salmon: 145 °F. Eggs: 160 °F, yolk and white firm.

## Verify before reporting done

```python
import json, re
def ngrams(t, n):
    w = re.findall(r"[a-z0-9]+", t.lower())
    return {" ".join(w[i:i+n]) for i in range(len(w)-n+1)}
legacy = json.load(open("legacy-144.json"))["recipes"]
rows = {r[0]: r for r in legacy}
mine = json.load(open("overrides/144-<LO>-<HI>.json"))
for rid, rec in mine.items():
    text = " ".join(s["text"] for s in rec["steps"])
    if ngrams(text, 9) & ngrams(str(rows[int(rid)][6]).replace("\n", " "), 9):
        print("9-gram overlap:", rid)
```

Fix every flagged recipe. Also spot-check: no banned words in titles, every
protein has exactly one check step, no reheat outside batch-leftovers.

## Report

Write the fragment file, then report the number of recipes written and any
recipe you could not complete (with the reason).
