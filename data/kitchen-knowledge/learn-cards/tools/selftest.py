#!/usr/bin/env python3
"""Selftest for learn-cards/tools/validate.py (stdlib only).

Copies the real cards and index into a temp directory, applies one mutation
per case, and runs the validator against the copy via --data-dir; the
validator must refuse exactly the broken shapes. tools/ itself stays put so
the universe conservation check reads its real universe.json and seed.

Run: python3 selftest.py   (exit 0 = all cases green)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LEARN_CARDS_DIR = os.path.dirname(HERE)
CARDS_DIR = os.path.join(LEARN_CARDS_DIR, "cards")
INDEX = os.path.join(LEARN_CARDS_DIR, "index.json")

failures = []


def run_validator(data_dir):
    return subprocess.run(
        [sys.executable, os.path.join(HERE, "validate.py"), "--data-dir", data_dir],
        capture_output=True, text=True,
    )


def copied_tree():
    tmp = tempfile.mkdtemp(prefix="learn-cards-selftest-")
    cards = os.path.join(tmp, "cards")
    os.makedirs(cards)
    for fn in os.listdir(CARDS_DIR):
        shutil.copy(os.path.join(CARDS_DIR, fn), cards)
    shutil.copy(INDEX, os.path.join(tmp, "index.json"))
    return tmp


def first_card_with_nutrition(tmp):
    for fn in sorted(os.listdir(os.path.join(tmp, "cards"))):
        path = os.path.join(tmp, "cards", fn)
        doc = json.load(open(path))
        if doc["data"].get("nutritionPer100g"):
            return path, doc
    raise SystemExit("selftest: no card with nutritionPer100g found")


def case(name, mutate, expect_substr, expect_pass=False):
    tmp = copied_tree()
    try:
        mutate(tmp)
        result = run_validator(tmp)
        if expect_pass:
            if result.returncode != 0:
                failures.append(f"{name}: validator rejected a VALID tree:\n{result.stdout[-800:]}")
            else:
                print(f"  ok  {name} (validator passes a valid tree)")
        else:
            if result.returncode == 0:
                failures.append(f"{name}: validator ACCEPTED a broken tree (expected {expect_substr!r})")
            elif expect_substr not in result.stdout:
                failures.append(f"{name}: validator failed with an unexpected message; "
                                f"wanted {expect_substr!r}, got:\n{result.stdout[-800:]}")
            else:
                print(f"  ok  {name}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def nutrient_mutation(nutrient, value):
    def apply(tmp):
        path, doc = first_card_with_nutrition(tmp)
        doc["data"]["nutritionPer100g"]["nutrients"][nutrient] = value
        with open(path, "w") as f:
            json.dump(doc, f)
    return apply


def first_card(tmp):
    return os.path.join(tmp, "cards", sorted(os.listdir(os.path.join(tmp, "cards")))[0])


def write_card(path, doc):
    with open(path, "w") as f:
        json.dump(doc, f)


def storage_ref_mutation():
    def apply(tmp):
        path = first_card(tmp)
        doc = json.load(open(path))
        doc["data"]["sections"]["storage"]["foodSafetyRef"] = {
            "path": "data/food-safety/rules.json", "note": "rulebook"}
        write_card(path, doc)
    return apply


def storage_text_mutation():
    def apply(tmp):
        path = first_card(tmp)
        doc = json.load(open(path))
        st = doc["data"]["sections"]["storage"]
        st["text"] = st["text"].rstrip(".") + ". The rulebook has the details."
        write_card(path, doc)
    return apply


def main():
    print("learn-cards validator selftest:")
    case("valid copy passes", lambda tmp: None, "", expect_pass=True)
    # Numeric contract (SCHEMA.md): negative, over-scale and non-finite
    # per-100 g values refuse — they must never load as 0 or nil.
    case("negative nutrient refuses",
         nutrient_mutation("proteinG", -1.0),
         "outside the plausible per-100 g range")
    case("negative energyKcal refuses",
         nutrient_mutation("energyKcal", -5),
         "outside the plausible per-100 g range")
    case("over-cap nutrient refuses",
         nutrient_mutation("energyKcal", 5000),
         "outside the plausible per-100 g range")
    case("NaN nutrient refuses",
         nutrient_mutation("energyKcal", float("nan")),
         "not finite")
    case("boolean nutrient refuses",
         nutrient_mutation("proteinG", True),
         "not numeric")

    # Storage safety references fail closed while the food-safety rulebook is
    # absent from this tree: a storage section may neither link to it nor lean
    # on it, in the data and at build time. The same cases skip cleanly (and
    # need re-deriving) once the rulebook lands and the checks flip back to
    # requiring the reference.
    import build_cards
    rulebook_absent = not os.path.exists(
        os.path.join(build_cards.REPO_ROOT, build_cards.FOOD_SAFETY_PATH))
    if rulebook_absent:
        case("dangling foodSafetyRef refuses", storage_ref_mutation(), "fail-closed")
        case("rulebook pointer in storage text refuses", storage_text_mutation(), "fail-closed")

        poisoned = {"x": {"data": {"sections": {"storage": {
            "text": "keep cool", "citations": [],
            "foodSafetyRef": {"path": "data/food-safety/rules.json", "note": "n"}}}}}}
        try:
            build_cards.assert_resolvable_safety_references(poisoned)
            failures.append("build gate accepted an unresolvable rulebook reference")
        except SystemExit:
            print("  ok  build gate refuses unresolvable rulebook reference")
        try:
            build_cards.assert_resolvable_safety_references(
                {"x": {"data": {"sections": {"storage": {
                    "text": "keep cool", "citations": []}}}}})
            print("  ok  build gate passes rule-free cards")
        except SystemExit as e:
            failures.append(f"build gate rejected a rule-free card: {e}")
    else:
        print("  ok  fail-closed cases skipped (rulebook present in tree)")
    if failures:
        print(f"\nSELFTEST FAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("\nSELFTEST PASS: the validator refuses every broken shape and passes the valid tree")


if __name__ == "__main__":
    main()
