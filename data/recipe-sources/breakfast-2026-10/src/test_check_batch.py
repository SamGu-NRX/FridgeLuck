#!/usr/bin/env python3
"""Planted-failure tests for check_batch.run_check.

Each test plants a specific defect in an in-memory copy of the built corpus
or its rights manifest and asserts the checker catches it. Run:

    python3 test_check_batch.py

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
import check_batch as cb  # noqa: E402
import build_batch as bb  # noqa: E402

PKG = HERE.parent


def load():
    records = [json.loads(line) for line in
               (PKG / "originals.jsonl").read_text().splitlines()
               if line.strip()]
    manifest = json.loads(
        (PKG / "evidence" / "originals-rights-manifest.json").read_text())
    return records, manifest


def first_with_safety(records):
    for r in records:
        for i, step in enumerate(r["steps"]):
            if "safety" in step:
                return r, i
    raise AssertionError("no safety step in corpus")


def first_household_line(records):
    for r in records:
        for line in r["ingredients"]:
            if line["qty"]["kind"] == "household":
                return r, line
    raise AssertionError("no household line in corpus")


def main() -> int:
    records, manifest = load()
    base = cb.run_check(copy.deepcopy(records), copy.deepcopy(manifest))
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
        r, i = first_with_safety(rs_)
        del r["steps"][i]["safety"]
    plant("stripped egg safety check", "R3", mutate_records=strip_safety)

    # 2. a thermometer check step deleted outright
    def delete_check_step(rs_):
        r, i = first_with_safety(rs_)
        del r["steps"][i]
    plant("deleted check step", "R3", mutate_records=delete_check_step)

    # 3. carried grams corrupted (no longer what the FNDDS row supports)
    def corrupt_grams(rs_):
        _, line = first_household_line(rs_)
        line["qty"]["grams"] = round(line["qty"]["grams"] * 1.5 + 7, 1)
    plant("corrupted carried grams", "supports", mutate_records=corrupt_grams)

    # 4. a forged conversion_ref
    def forge_ref(rs_):
        _, line = first_household_line(rs_)
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

    # 10. world_cuisine outside the packet's regions
    def bad_region(rs_):
        rs_[0]["world_cuisine"] = "french"
    plant("unknown packet region 'french'", "not a packet region",
          mutate_records=bad_region)

    # 11. unquantified ingredient without a note
    def blank_note(rs_):
        for r in rs_:
            for line in r["ingredients"]:
                if line["qty"]["kind"] == "unknown":
                    line["qty"]["note"] = ""
                    return
        raise AssertionError("no unknown line in corpus")
    plant("unknown quantity with blank note", "carries no note",
          mutate_records=blank_note)

    # 12. non-positive source_grams
    def zero_grams(rs_):
        for r in rs_:
            for line in r["ingredients"]:
                if line["qty"]["kind"] == "source_grams":
                    line["qty"]["grams"] = 0
                    return
        raise AssertionError("no source_grams line in corpus")
    plant("zero source_grams", "not a positive mass",
          mutate_records=zero_grams)

    # 13. claims appear without substantiation
    def add_claims(rs_):
        rs_[0]["claims"] = [{"claim": "vegan"}]
    plant("unsubstantiated diet claim", "does not substantiate",
          mutate_records=add_claims)

    # 14. id sequence broken
    def break_ids(rs_):
        rs_[3]["id"] = "fl-bfast-9999"
    plant("broken id sequence", "breaks the fl-bfast-NNNN sequence",
          mutate_records=break_ids)

    # 15. meal slot outside the declared vocabulary
    def bad_slot(rs_):
        rs_[0]["meal_slots"] = ["brunch"]
    plant("meal slot 'brunch'", "outside the declared slots",
          mutate_records=bad_slot)

    # 16. brief gate: fewer than 12 recipes at 15 minutes or less
    def slow_down(rs_):
        changed = 0
        for r in rs_:
            if isinstance(r["minutes"], int) and r["minutes"] <= 15:
                r["minutes"] = 20
                changed += 1
                if changed >= 12:
                    return
        raise AssertionError("not enough fast recipes to plant")
    plant("fast15 pool shrunk below 12", "15 minutes or less",
          mutate_records=slow_down)

    # 17. brief gate: known-composition vegan/GF pool shrunk to 10 or fewer
    def degrade_composition(rs_):
        surface_map, entries = bb.load_vocab()
        known_ids = []
        for r in rs_:
            comp = bb.diet_composition([l["name"] for l in r["ingredients"]],
                                       surface_map, entries)
            if comp["vegan_known"] or comp["gluten_free_known"]:
                known_ids.append(r["id"])
        need = len(known_ids) - 10
        if need <= 0:
            raise AssertionError("known-composition pool already at the edge")
        target = set(known_ids[:need])
        for r in rs_:
            if r["id"] in target:
                r["ingredients"].append(
                    {"name": "unmapped mystery powder",
                     "qty": {"kind": "unknown", "note": "to taste"}})
    plant("known vegan/GF pool shrunk to 10", "more than 10 are required",
          mutate_records=degrade_composition)

    # 18. brief gate: title collides with the repo corpus
    corpus = cb.corpus_titles()
    if corpus:
        def collide_corpus(rs_):
            rs_[0]["title"] = next(iter(sorted(corpus))).title()
        plant("title colliding with data/recipes/corpus.jsonl",
              "collides with a title already in",
              mutate_records=collide_corpus)
    else:
        print("SKIP     corpus-collision plant: data/recipes/corpus.jsonl "
              "has no titles")

    # 19. brief gate: duplicate title inside the batch
    def collide_batch(rs_):
        rs_[1]["title"] = rs_[0]["title"]
    plant("duplicate title inside the batch", "duplicate normalized title",
          mutate_records=collide_batch)

    failed = 0
    for name, marker, rs2, mf2 in plants:
        violations = cb.run_check(rs2, mf2)
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
