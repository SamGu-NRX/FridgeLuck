#!/usr/bin/env python3
"""Selftest for packs/tools/validate.py (stdlib only).

Builds synthetic pack trees in a temp directory, feeds each mutation to the
validator via --packs-dir, and asserts the validator refuses exactly the
broken shapes. Run: python3 selftest.py   (exit 0 = all cases green)
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
CATALOG = os.path.join(REPO_ROOT, "apps/ios/Resources/usda_ingredient_catalog.sqlite")

failures = []


def catalog_fdc_id():
    conn = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    try:
        row = conn.execute("SELECT fdc_id FROM ingredient_catalog ORDER BY fdc_id LIMIT 1").fetchone()
    finally:
        conn.close()
    if row is None:
        raise SystemExit("selftest: catalog sqlite has no rows")
    return int(row[0])


def source(sid="s1"):
    return {
        "id": sid, "title": "Example source", "publisher": "Example publisher",
        "url": "https://example.com/source", "retrieved": "2026-10-11",
        "licence": "Public domain (U.S. government work)",
    }


def item(fdc, price=2.0, **extra):
    d = {
        "ingredientKey": "onion", "displayName": "Onion",
        "usdaFdcId": fdc, "quantity": "2 lb", "quantityKg": 0.9,
        "priceUsd": price, "priceSourceId": "s1", "citationIds": ["s1"],
    }
    d.update(extra)
    return d


def budget_file(fdc):
    return {
        "schemaVersion": 1, "kind": "budget-packs", "retrieved": "2026-10-11",
        "data": {
            "region": "United States, national average", "priceDate": "2026-09",
            "packs": [{
                "id": "test_pack", "name": "Test pack", "budgetUsd": 50.0,
                "region": "United States, national average", "priceDate": "2026-09",
                "items": [item(fdc, price=1.0 + i * 0.5) for i in range(6)],
                "totalCostUsd": round(sum(1.0 + i * 0.5 for i in range(6)), 4),
                "citationIds": ["s1"],
            }],
            "sources": [source()],
        },
    }


def foodbank_file(fdc):
    return {
        "schemaVersion": 1, "kind": "food-bank-packs", "retrieved": "2026-10-11",
        "data": {
            "packs": [{
                "id": "basket_one", "name": "Basket",
                "items": [item(fdc, price=None, quantityKg=1.0, typicalForm="whole")
                          for _ in range(3)],
                "citationIds": ["s1"], "distributionNote": "Note",
            }],
            "sources": [source()],
        },
    }


def useitup_file(fdc, pack_id="rescue_wilted"):
    return {
        "schemaVersion": 1, "kind": "use-it-up-packs", "retrieved": "2026-10-11",
        "data": {
            "packs": [{
                "id": pack_id, "name": "Rescue", "situation": "Situation",
                "ingredients": [item(fdc, price=None)],
                "tactic": "Whip the soft produce into a frittata or a week of fried rice, freeze what you cannot cook in time, and label the leftovers with the date so nothing hides in the back of the fridge again.",
                "citationIds": ["s1"],
            } for pack_id in [f"rescue_{i}" for i in range(8)]],
            "sources": [source()],
        },
    }


def seasonal_file(fdc):
    regions = [f"region_{i}" for i in range(4)]
    months = [{
        "month": m,
        "packs": [{
            "regionId": r, "name": f"Region {r} month {m}",
            "produce": [{"ingredientKey": "onion", "displayName": "Onion", "usdaFdcId": fdc}],
            "citationIds": ["s1"],
        } for r in regions],
    } for m in range(1, 13)]
    return {
        "schemaVersion": 1, "kind": "seasonal-packs", "retrieved": "2026-10-11",
        "data": {
            "regions": [{"id": r, "name": r, "states": {"IA": [m for m in range(1, 13)]},
                         "definitionCitation": "s1"} for r in regions],
            "months": months,
            "sources": [source()],
        },
    }


def write_tree(directory, files):
    for name, doc in files.items():
        with open(os.path.join(directory, name), "w") as f:
            json.dump(doc, f)


def run_validator(packs_dir):
    return subprocess.run(
        [sys.executable, os.path.join(HERE, "validate.py"),
         "--packs-dir", packs_dir, "--catalog", CATALOG],
        capture_output=True, text=True,
    )


def case(name, mutate, expect_substr, expect_pass=False):
    tmp = tempfile.mkdtemp(prefix="packs-selftest-")
    try:
        fdc = catalog_fdc_id()
        files = {
            "budget_packs.json": budget_file(fdc),
            "food_bank_packs.json": foodbank_file(fdc),
            "seasonal_packs.json": seasonal_file(fdc),
            "use_it_up_packs.json": useitup_file(fdc),
        }
        mutate(files)
        write_tree(tmp, files)
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


def main():
    print("packs validator selftest:")
    case("valid tree passes", lambda f: None, "", expect_pass=True)
    case("duplicate budget pack id refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"].append(
             dict(f["budget_packs.json"]["data"]["packs"][0])),
         "duplicate pack id")
    case("cross-file duplicate pack id refuses",
         lambda f: f["use_it_up_packs.json"]["data"]["packs"][0].update(id="test_pack"),
         "duplicate pack id across files")
    case("malformed pack id refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0].update(id="Bad Id!"),
         "invalid pack id")
    case("unknown pack citation refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0].update(citationIds=["sX"]),
         "cites unknown citationId")
    case("budget breach refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0].update(
             budgetUsd=1.0, totalCostUsd=round(sum(1.0 + i * 0.5 for i in range(6)), 4)),
         "exceeds budget")
    case("duplicate source record id refuses",
         lambda f: f["budget_packs.json"]["data"]["sources"].append(source()),
         "duplicate source id")
    case("unknown seasonal regionId refuses",
         lambda f: f["seasonal_packs.json"]["data"]["months"][0]["packs"][0].update(regionId="nowhere"),
         "unknown regionId")
    case("unknown item citation in use-it-up refuses",
         lambda f: f["use_it_up_packs.json"]["data"]["packs"][0]["ingredients"][0].update(
             citationIds=["sX"]),
         "cites unknown citationId")
    # Numeric contract (SCHEMA.md): negative money/mass and non-finite
    # floats refuse — a NaN slips past `<= 0` comparisons otherwise.
    case("negative item price refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0]["items"][0].update(priceUsd=-1.0),
         "priceUsd not positive")
    case("negative budgetUsd refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0].update(budgetUsd=-50.0),
         "budgetUsd negative")
    case("NaN quantityKg refuses",
         lambda f: f["budget_packs.json"]["data"]["packs"][0]["items"][0].update(
             quantityKg=float("nan")),
         "quantityKg not a finite number")
    if failures:
        print(f"\nSELFTEST FAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("\nSELFTEST PASS: the validator refuses every broken shape and passes the valid tree")


if __name__ == "__main__":
    main()
