#!/usr/bin/env python3
"""Build the learn-card ingredient universe.

Frequency sources (both read-only, neither owned by this task):
  1. apps/ios/Resources/data.json recipes (the bundled catalog on alpha):
     element index 4 of each recipe holds [[ingredientId, grams], ...];
     ingredient ids are ints into the `ingredients` dict (50 core entries).
  2. evaluation/suites/recipes/corpus/{authored,composed}.json on branch
     eval/scorecard-runner (PR #88): 530 rights-clear RS recipes that are
     the seed of the recipe corpus overhaul. Ingredients there are names.

The bundled catalog references only 47 distinct ingredient ids, all inside
the core 50, so the "next 300 by frequency" of the brief cannot be filled
from data.json alone. We cover instead: every core ingredient plus every
distinct ingredient of the rights-clear seed corpus (names normalised and
merged per MERGE below). The real numbers land in index.json coverage.

Output: universe.json next to this file, and a printed summary.
"""
import json
import subprocess
import collections
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SEED_BRANCH = "origin/eval/scorecard-runner"
SEED_PATHS = [
    "evaluation/suites/recipes/corpus/authored.json",
    "evaluation/suites/recipes/corpus/composed.json",
]

# seed-corpus name (lower case, as written in the RS corpus) -> card id.
# "same ingredient, different wording or form" merges into one card; the
# note records why. A name not listed becomes its own card id (snake_case).
MERGE = {
    "all-purpose flour": ("all_purpose_flour", "slug normalised to underscores"),
    "flattened rice (poha)": ("flattened_rice", "slug normalised; poha is the alias"),
    "olive oil":        ("olive_oil", "core olive_oil"),
    "soy sauce":        ("soy_sauce", "core soy_sauce"),
    "sesame oil":       ("sesame_oil", "core sesame_oil"),
    "coconut milk":     ("coconut_milk", "core coconut_milk"),
    "peanut butter":    ("peanut_butter", "core peanut_butter"),
    "vegetable oil":    ("vegetable_oil", "blanket cooking oil; card covers common vegetable oils"),
    "potatoes":         ("potato", "plural of core potato"),
    "roasted potatoes": ("potato", "potato used roasted; same ingredient"),
    "sweet potatoes":   ("sweet_potato", "plural of core sweet_potato"),
    "mushrooms":        ("mushroom", "plural of core mushroom"),
    "carrots":          ("carrot", "plural of core carrot"),
    "tomatoes":         ("tomato", "plural of core tomato"),
    "green onions":     ("green_onion", "plural of core green_onion"),
    "chickpeas":        ("chickpea", "plural of core chickpea"),
    "black beans":      ("black_beans", "core black_beans"),
    "ground beef":      ("ground_beef", "core ground_beef"),
    "chicken breast":   ("chicken_breast", "core chicken_breast"),
    "eggs":             ("egg", "plural of core egg"),
    "bell peppers":     ("bell_pepper", "plural of core bell_pepper"),
    "flour tortillas":  ("tortilla", "core tortilla is flour tortillas"),
    "peas":             ("frozen_peas", "core frozen_peas card covers peas fresh and frozen"),
    "rolled oats":      ("oats", "rolled oats are the common oat form; core oats"),
    "cooked rice":      ("rice", "rice used cooked; same ingredient"),
    "red onion":        ("onion", "onion colour variety, 1 line; core onion card covers it"),
    "salmon fillets":   ("salmon", "fillet is the standard retail cut of core salmon"),
    "cod fillets":      ("cod", "fillet is the standard retail cut"),
    "tilapia fillets":  ("tilapia", "fillet is the standard retail cut"),
    "chili flakes":     ("red_pepper_flakes", "chili flakes = crushed red pepper flakes; core"),
    "chipotle in adobo": ("chipotle", "chipotle canned in adobo is the standard form"),
    "lentils":          ("red_lentils", "generic lentil lines in the seed corpus are red lentil dals"),
}

def load_seed():
    out = collections.Counter()
    for p in SEED_PATHS:
        blob = subprocess.run(
            ["git", "show", f"{SEED_BRANCH}:{p}"],
            cwd=REPO, capture_output=True, text=True, check=True).stdout
        for r in json.loads(blob)["recipes"]:
            for ing in r["ingredients"]:
                out[ing["name"].lower()] += 1
    return out

def main():
    data = json.load(open(os.path.join(REPO, "apps/ios/Resources/data.json")))
    core = {k: v[0] for k, v in data["ingredients"].items()}  # id -> name
    # frequency of core ids from the bundled catalog recipes
    core_freq = collections.Counter()
    for r in data["recipes"]:
        for pair in r[4]:
            core_freq[str(pair[0])] += 1

    seed = load_seed()
    cards = {}
    # core cards: id = core name; frequency = bundled-catalog recipe lines
    for cid, name in core.items():
        cards[name] = {
            "id": name, "displayName": name.replace("_", " ").title(),
            "isCore": True, "frequencyInBundledRecipes": core_freq.get(cid, 0),
            # Seed-corpus frequency is added exactly once, by the seed loop
            # below (an earlier version looked it up here AND again in the
            # loop, double-counting exact-name matches).
            "frequencyInSeedCorpus": 0,
            "aliases": [],
        }
    # seed-corpus cards not merging into a core card
    for name, count in sorted(seed.items(), key=lambda x: -x[1]):
        target, note = MERGE.get(name, (name.replace(" ", "_"), "own card"))
        if target in cards:
            cards[target]["frequencyInSeedCorpus"] += count
            if target != name.replace(" ", "_"):
                cards[target]["aliases"].append(name)
        else:
            cards[target] = {
                "id": target, "displayName": target.replace("_", " ").title(),
                "isCore": False, "frequencyInBundledRecipes": 0,
                "frequencyInSeedCorpus": count, "aliases": [],
                "mergeNote": MERGE.get(name, [None, note])[1],
            }
            # if target == slug of a non-merged name, mergeNote is noise
            if MERGE.get(name) and target == MERGE[name][0] and not name.replace(" ", "_") == target:
                pass
            else:
                cards[target].pop("mergeNote", None)

    used = len([c for c in cards.values() if c["frequencyInBundledRecipes"] + c["frequencyInSeedCorpus"] > 0])
    summary = {
        "coreCards": sum(1 for c in cards.values() if c["isCore"]),
        "nonCoreCards": sum(1 for c in cards.values() if not c["isCore"]),
        "total": len(cards),
        "bundledDistinctIngredientIds": len(core_freq),
        "seedDistinctNames": len(seed),
        "unusedCoreIds": sorted(cid for cid in core if core_freq[cid] == 0),
    }
    json.dump({"summary": summary, "cards": dict(sorted(cards.items()))},
              open(os.path.join(HERE, "universe.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))
    print("non-core ids:", sorted(c["id"] for c in cards.values() if not c["isCore"]))

if __name__ == "__main__":
    main()
