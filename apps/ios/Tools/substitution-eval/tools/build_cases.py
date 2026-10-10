#!/usr/bin/env python3
"""Build recipe-context substitution cases from bundled production data.

Inputs (all read from the repo, nothing hand-transcribed):
  * apps/ios/Resources/data.json               - bundled recipes + ingredient catalog
  * apps/ios/Platform/Persistence/Services/SubstitutionService.swift - production pair map
  * evidence/pair_evidence.csv                 - per-pair evidence verdicts

Output:
  * evidence/context_cases.csv - one row per (production pair, recipe context).
    A case is a CONTEXT, not a recipe-level claim: the same pair gets one case
    per recipe where the ORIGINAL ingredient appears (required or optional),
    with the culinary function the original plays in that recipe.

Function vocabulary: binding | fat | liquid | thickening | garnish | main |
sweetener | acid | aromatic | unknown. The task's five categories
(binding / fat / liquid / thickening / garnish) are distinguished explicitly;
the rest record other real functions so nothing is silently mislabeled.

Verdicts (from pair evidence, never from taste):
  verified   - context function is in the pair's supported_functions AND the
               pair's ratio is sourced
  partial    - function is supported but the amount (ratio) is convention,
               unsupported, or conflicts with evidence
  unsupported - context function is in the pair's unsuitable_functions
               (evidence contradicts the swap in this context)
  unverified - function could not be determined from the recipe steps, or is
               not covered by any evidence (left unverified on purpose)

Determinism: same inputs -> byte-identical CSV. check_evidence.py regenerates
and diffs against the committed file.
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

VERDICTS = ["verified", "partial", "unsupported", "unverified"]
FUNCTIONS = [
    "binding", "fat", "liquid", "thickening", "garnish",
    "main", "sweetener", "acid", "aromatic", "unknown",
]

# Step-line mention patterns per ingredient id, in priority order.
# Patterns are applied to the lowercased instruction lines.
MENTION_RE = {
    1: re.compile(r"\beggs?\b"),
    2: re.compile(r"\brice\b"),
    4: re.compile(r"\bchicken\b"),
    5: re.compile(r"(?<!green )(?<!spring )\bonions?\b"),
    9: re.compile(r"\bpasta\b|\bnoodles?\b|\bspaghetti\b"),
    10: re.compile(r"(?<!sweet )\bpotatoes?\b"),
    12: re.compile(r"\bcheese\b"),
    13: re.compile(r"(?<!coconut )\bmilk\b"),
    14: re.compile(r"\bbutter\b"),
    15: re.compile(r"\bbread\b"),
    16: re.compile(r"\bolive oil\b|\boil\b"),
    17: re.compile(r"\blemon\b"),
    20: re.compile(r"\bbananas?\b"),
    21: re.compile(r"\bgreen onions?\b|\bscallions?\b|\bspring onions?\b"),
    23: re.compile(r"\btofu\b"),
    24: re.compile(r"\bbroccoli\b"),
    26: re.compile(r"\bavocados?\b"),
    27: re.compile(r"\bblack beans?\b"),
    28: re.compile(r"\btortillas?\b"),
    29: re.compile(r"\blime\b"),
    31: re.compile(r"\boats?\b|\boatmeal\b"),
    32: re.compile(r"\byogurt\b"),
    33: re.compile(r"\bhoney\b"),
    35: re.compile(r"\bchickpeas?\b|\bgarbanzos?\b"),
    36: re.compile(r"\bsalmon\b"),
    37: re.compile(r"\bsweet potatoes?\b"),
    38: re.compile(r"\bground beef\b|\bbeef\b"),
    39: re.compile(r"\blettuce\b"),
    43: re.compile(r"\btuna\b"),
    45: re.compile(r"\bzucchini\b|\bzoodles?\b"),
    49: re.compile(r"\bcoconut milk\b"),
    50: re.compile(r"\bsour cream\b"),
}

GARNISH_RE = re.compile(
    r"garnish|sprinkle|top with|topped|scatter|finish|dollop|drizzle over"
)
BINDING_RE = re.compile(
    r"dough|batter|patt|coat|crust|\bbind|fritter|meatball|meatloaf|stuffed|breaded|crumb"
)
THICKEN_RE = re.compile(r"thicken|roux|slurry|porridge|congee|mash|puree|blend|reduce")
SWEETEN_RE = re.compile(r"sweet|glaze|honey")
ACID_RE = re.compile(r"juice|squeeze|zest|acid|dress|marinade|ceviche|pickle")
FAT_RE = re.compile(
    r"\bfry|saut|sear|grease|drizzle|\boil|melt|cream the|wok|buttered|griddle"
)
LIQUID_RE = re.compile(
    r"simmer|boil|broth|soup|sauce|pour|whisk|marinade|steam|stew|braise|soak|poach"
)
COOK_RE = re.compile(r"cook|bake|roast|grill|toast|heat|boil|simmer|steam|fry|saut|scramble|beat|whisk|poach")

BATTER_NOUN_RE = re.compile(r"batter|dough|patty|meatball|meatloaf|fritter|coat|breaded|crumb")
MIX_RE = re.compile(r"mix|beat|whisk|stir|fold|combine|press")

# Ingredient classes
STAPLES = {2, 9, 10, 15, 28, 31, 37}
PROTEINS = {1, 4, 36, 38, 43, 23, 27, 35}
FAT_INGREDIENTS = {14, 16}
DAIRY = {12, 13, 32, 49, 50}
ALLIUMS = {5, 21}
CITRUS = {17, 29}
SWEETENERS = {20, 33}

MAX_CASES_PER_PAIR = 14


def strip_step_numbering(line: str) -> str:
    return re.sub(r"^\s*\d+\s*[.)]\s*", "", line)


def split_steps(instructions: str):
    return [strip_step_numbering(l).strip() for l in instructions.splitlines() if l.strip()]


def classify_function(ingredient_id: int, ingredient_name: str, recipe_title: str, steps):
    """Return (function, basis) for the ORIGINAL ingredient in this recipe."""
    title_lc = recipe_title.lower()
    name_lc = ingredient_name.replace("_", " ").lower()
    name_core = name_lc.split()[-1] if name_lc.split() else name_lc
    mention_lines = [
        (i, l) for i, l in enumerate(steps) if MENTION_RE[ingredient_id].search(l.lower())
    ]
    if not mention_lines:
        # Ingredient never named in the steps: decide from ingredient class.
        if ingredient_id in STAPLES or ingredient_id in PROTEINS:
            if ingredient_id in CITRUS:
                return ("acid", "not mentioned in steps; citrus default")
            if name_core and name_core in title_lc:
                return ("main", f"'{recipe_title}' names the ingredient; steps never mention it")
            return ("main", "staple/protein present but never mentioned in steps")
        return ("unknown", "ingredient never mentioned in steps")

    for i, line in mention_lines:
        lc = line.lower()
        if GARNISH_RE.search(lc):
            return ("garnish", f"step {i + 1}: garnish verb in '{line[:80]}'")
    for i, line in mention_lines:
        lc = line.lower()
        if ingredient_id in PROTEINS or ingredient_id in STAPLES:
            if BINDING_RE.search(lc) or (
                any(BATTER_NOUN_RE.search(s.lower()) for s in steps)
                and MIX_RE.search(lc)
            ):
                return ("binding", f"step {i + 1}: binding use in '{line[:80]}'")
    for i, line in mention_lines:
        lc = line.lower()
        if THICKEN_RE.search(lc):
            return ("thickening", f"step {i + 1}: thickening verb in '{line[:80]}'")
    for i, line in mention_lines:
        lc = line.lower()
        if ingredient_id in CITRUS and ACID_RE.search(lc):
            return ("acid", f"step {i + 1}: acid use in '{line[:80]}'")
        if ingredient_id in SWEETENERS and SWEETEN_RE.search(lc):
            return ("sweetener", f"step {i + 1}: sweetener use in '{line[:80]}'")
        if ingredient_id in FAT_INGREDIENTS and FAT_RE.search(lc):
            return ("fat", f"step {i + 1}: fat use in '{line[:80]}'")
    for i, line in mention_lines:
        lc = line.lower()
        if ingredient_id in DAIRY and LIQUID_RE.search(lc):
            return ("liquid", f"step {i + 1}: liquid use in '{line[:80]}'")
    for i, line in mention_lines:
        lc = line.lower()
        if ingredient_id in FAT_INGREDIENTS and LIQUID_RE.search(lc):
            return ("fat", f"step {i + 1}: melted-fat use in '{line[:80]}'")
        if ingredient_id in DAIRY and FAT_RE.search(lc):
            return ("fat", f"step {i + 1}: fat use in '{line[:80]}'")
        if ingredient_id in ALLIUMS:
            return ("aromatic", f"step {i + 1}: cooked aromatic in '{line[:80]}'")
        if ingredient_id in CITRUS:
            return ("acid", f"step {i + 1}: citrus use in '{line[:80]}'")
        if ingredient_id in SWEETENERS:
            return ("sweetener", f"step {i + 1}: sweetener use in '{line[:80]}'")
        if ingredient_id in DAIRY:
            return ("liquid", f"step {i + 1}: dairy use in '{line[:80]}'")
        if ingredient_id in STAPLES or ingredient_id in PROTEINS:
            if COOK_RE.search(lc):
                return ("main", f"step {i + 1}: cooked as the dish base in '{line[:80]}'")
    # Final fallbacks by ingredient class: butter/oil in a recipe functions as
    # fat; staples and proteins are the dish base; dairy is liquid.
    for i, line in mention_lines:
        if ingredient_id in FAT_INGREDIENTS:
            return ("fat", f"step {i + 1}: fat ingredient in '{line[:80]}'")
        if ingredient_id in STAPLES or ingredient_id in PROTEINS:
            return ("main", f"step {i + 1}: staple/protein present in '{line[:80]}'")
        if ingredient_id in DAIRY:
            return ("liquid", f"step {i + 1}: dairy present in '{line[:80]}'")
    return ("unknown", "mention lines carry no function keyword")


def verdict_for(pair_evidence_row, function):
    supported = set(filter(None, pair_evidence_row["supported_functions"].split(";")))
    unsuitable = set(filter(None, pair_evidence_row["unsuitable_functions"].split(";")))
    if function == "unknown":
        return "unverified"
    if function in unsuitable:
        return "unsupported"
    if function in supported:
        if pair_evidence_row["ratio_status"] == "sourced" and pair_evidence_row["evidence_level"] == "sourced":
            return "verified"
        return "partial"
    return "unverified"


def parse_service_pairs(service_path: Path):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from extract_production_map import parse_service

    return parse_service(service_path)[0]


def load_pair_evidence(path: Path):
    with path.open(newline="", encoding="utf-8") as f:
        return {row["pair_id"]: row for row in csv.DictReader(f)}


def build_cases(repo_root: Path):
    data = json.loads((repo_root / "apps/ios/Resources/data.json").read_text())
    ingredients = data["ingredients"]
    service_pairs = parse_service_pairs(
        repo_root / "apps/ios/Platform/Persistence/Services/SubstitutionService.swift"
    )
    evidence = load_pair_evidence(repo_root / "apps/ios/Tools/substitution-eval/evidence/pair_evidence.csv")

    name_of = {int(k): v[0] for k, v in ingredients.items()}
    pair_of = {}
    for p in service_pairs:
        pair_of[(p["originalId"], p["substituteId"])] = p

    cases = []
    for pair_id, ev in sorted(evidence.items()):
        orig_id, sub_id = (int(x) for x in pair_id.split("-"))
        if (orig_id, sub_id) not in pair_of:
            raise SystemExit(f"pair_evidence row {pair_id} is not a production pair")
        prod = pair_of[(orig_id, sub_id)]
        contexts = []
        for recipe in data["recipes"]:
            rid, title, _time, _serv, required, optional, instructions, _tags = recipe
            steps = split_steps(instructions)
            for role, groups in (("required", required), ("optional", optional)):
                for iid, grams in groups:
                    if iid == orig_id:
                        fn, basis = classify_function(orig_id, name_of[orig_id], title, steps)
                        contexts.append(
                            {
                                "pair_id": pair_id,
                                "original_id": orig_id,
                                "original_name": name_of[orig_id],
                                "substitute_id": sub_id,
                                "substitute_name": name_of[sub_id],
                                "recipe_id": rid,
                                "recipe_title": title,
                                "ingredient_role": role,
                                "original_grams": grams,
                                "context_function": fn,
                                "function_basis": basis,
                                "verdict": verdict_for(ev, fn),
                                "production_ratio": prod["ratio"],
                            }
                        )
        contexts.sort(key=lambda c: c["recipe_id"])
        cases.extend(contexts[:MAX_CASES_PER_PAIR])

    cases.sort(key=lambda c: (c["pair_id"], c["recipe_id"], c["ingredient_role"]))
    for i, c in enumerate(cases, start=1):
        c["case_id"] = f"case-{i:04d}"
    return cases


COLUMNS = [
    "case_id", "pair_id", "original_id", "original_name", "substitute_id",
    "substitute_name", "recipe_id", "recipe_title", "ingredient_role",
    "original_grams", "context_function", "function_basis", "verdict",
    "production_ratio",
]


def write_cases_csv(cases, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--out", default="apps/ios/Tools/substitution-eval/evidence/context_cases.csv")
    args = ap.parse_args()
    repo_root = Path(args.repo_root).resolve()

    cases = build_cases(repo_root)
    out = repo_root / args.out
    write_cases_csv(cases, out)

    counts = {}
    for c in cases:
        counts[c["verdict"]] = counts.get(c["verdict"], 0) + 1
    fcounts = {}
    for c in cases:
        fcounts[c["context_function"]] = fcounts.get(c["context_function"], 0) + 1
    print(f"wrote {out} ({len(cases)} cases over "
          f"{len({(c['pair_id']) for c in cases})} pairs)")
    print("verdicts:", json.dumps(counts, sort_keys=True))
    print("functions:", json.dumps(fcounts, sort_keys=True))
    if len(cases) < 200:
        print("ERROR: fewer than 200 cases", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
