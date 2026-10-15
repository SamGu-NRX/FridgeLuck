#!/usr/bin/env python3
"""Planted-failure tests for check_packet.run_check.

Each test plants a specific defect in an in-memory copy of the built corpus
or its rights manifest and asserts the checker catches it. Run:

    python3 test_check_packet.py

Prints one line per planted failure (the violation class it triggered) and
exits 0 only when every plant is CAUGHT and the unmutated corpus is clean.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_packet as cp  # noqa: E402

PKG = HERE.parent


def load():
    records = [json.loads(line) for line in
               (PKG / "originals.jsonl").read_text().splitlines()
               if line.strip()]
    manifest = json.loads(
        (PKG / "evidence" / "originals-rights-manifest.json").read_text())
    return records, manifest


def find_with_ingredient(records, name):
    for r in records:
        for line in r["ingredients"]:
            if line["name"] == name:
                return r
    raise AssertionError(f"no record carries {name!r}")


def main() -> int:
    records, manifest = load()
    base = cp.run_check(copy.deepcopy(records), copy.deepcopy(manifest))
    if base:
        print(f"SETUP FAILED: unmutated corpus is not clean ({len(base)} "
              f"violations); fix the corpus before planting failures")
        for x in base[:5]:
            print("  " + x)
        return 2

    plants: list[tuple[str, str, list[dict], dict]] = []

    def plant(name, marker, mutate_records=None, mutate_manifest=None):
        rs2 = copy.deepcopy(records)
        mf2 = copy.deepcopy(manifest)
        if mutate_records:
            mutate_records(rs2)
        if mutate_manifest:
            mutate_manifest(mf2)
        plants.append((name, marker, rs2, mf2))

    # 1. a required safety check stripped from a step
    def strip_safety(rs_):
        r = find_with_ingredient(rs_, "chicken breast")
        for step in r["steps"]:
            if "safety" in step:
                del step["safety"]
                return
        raise AssertionError("no safety step found on chicken recipe")
    plant("stripped poultry safety check", "R3", mutate_records=strip_safety)

    # 2. a thermometer check deleted outright (whole recipe loses its check)
    def delete_check_step(rs_):
        r = find_with_ingredient(rs_, "ground beef")
        idx = next(i for i, s in enumerate(r["steps"]) if "safety" in s)
        del r["steps"][idx]
    plant("deleted ground-meat check step", "R3",
          mutate_records=delete_check_step)

    # 3. carried grams corrupted (no longer what the FNDDS row supports)
    def corrupt_grams(rs_):
        r = find_with_ingredient(rs_, "soy sauce")
        line = next(l for l in r["ingredients"]
                    if l["qty"]["kind"] == "household")
        line["qty"]["grams"] = round(line["qty"]["grams"] * 1.5 + 7, 1)
    plant("corrupted carried grams", "pinned FNDDS row",
          mutate_records=corrupt_grams)

    # 4. a forged conversion_ref
    def forge_ref(rs_):
        r = find_with_ingredient(rs_, "soy sauce")
        line = next(l for l in r["ingredients"]
                    if l["qty"]["kind"] == "household")
        line["qty"]["conversion_ref"] = "fndds:000000000"
    plant("forged conversion_ref", "is not the pinned row",
          mutate_records=forge_ref)

    # 5. rights-manifest entry deleted
    def drop_rights(mf_):
        mf_.pop(next(iter(mf_)))
    plant("deleted rights-manifest entry", "no rights-manifest entry",
          mutate_manifest=drop_rights)

    # 6. rights downgraded from original
    def downgrade_rights(mf_):
        mf_[next(iter(mf_))]["rights_status"] = "scraped"
    plant("downgraded rights_status", "is not 'original'",
          mutate_manifest=downgrade_rights)

    # 7. rights entry stripped of its author
    def blank_author(mf_):
        mf_[next(iter(mf_))]["author"] = "  "
    plant("blanked rights author", "missing 'author'",
          mutate_manifest=blank_author)

    # 8. unsupported cuisine value
    def bad_cuisine(rs_):
        rs_[0]["cuisine"] = "french"
    plant("unsupported cuisine 'french'", "outside the suite vocabulary",
          mutate_records=bad_cuisine)

    # 9. cuisine/world_cuisine mapping broken
    def swap_mapping(rs_):
        rs_[0]["cuisine"] = "italian"
    plant("broken cuisine/world_cuisine mapping", "does not match the region",
          mutate_records=swap_mapping)

    # 10. unquantified ingredient without a note
    def blank_note(rs_):
        for r in rs_:
            for line in r["ingredients"]:
                if line["qty"]["kind"] == "unknown":
                    line["qty"]["note"] = ""
                    return
        raise AssertionError("no unknown line in corpus")
    plant("unknown quantity with blank note", "carries no note",
          mutate_records=blank_note)

    # 11. non-positive source_grams
    def zero_grams(rs_):
        for r in rs_:
            for line in r["ingredients"]:
                if line["qty"]["kind"] == "source_grams":
                    line["qty"]["grams"] = 0
                    return
        raise AssertionError("no source_grams line in corpus")
    plant("zero source_grams", "not a positive mass",
          mutate_records=zero_grams)

    # 12. claims appear without substantiation
    def add_claims(rs_):
        rs_[0]["claims"] = [{"claim": "vegan"}]
    plant("unsubstantiated diet claim", "does not substantiate",
          mutate_records=add_claims)

    # 13. id sequence broken
    def break_ids(rs_):
        rs_[3]["id"] = "fl-world-9999"
    plant("broken id sequence", "breaks the fl-world-NNNN sequence",
          mutate_records=break_ids)

    # 14. meal slot outside the declared vocabulary
    def bad_slot(rs_):
        rs_[0]["meal_slots"] = ["brunch"]
    plant("meal slot 'brunch'", "outside the declared slots",
          mutate_records=bad_slot)

    failed = 0
    for name, marker, rs2, mf2 in plants:
        violations = cp.run_check(rs2, mf2)
        caught = [x for x in violations if marker in x]
        if caught:
            print(f"CAUGHT   {name} -> {caught[0]}")
        else:
            failed += 1
            print(f"MISSED   {name}: expected a violation containing "
                  f"{marker!r}; got {len(violations)} violation(s): "
                  f"{violations[:3]}")
    total = len(plants)
    print(f"{total - failed}/{total} planted failures caught")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
