#!/usr/bin/env python3
"""Machine-check the recipe-system spec contracts.

Usage: python3 check.py            (from docs/spec/recipes/contracts or anywhere)
Exit 0 = all green, 1 = failure. Requires: python3.11+, jsonschema.
Tamper suite: python3 tamper-tests.py
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.exit("jsonschema is required: pip install -r requirements.txt")

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
CONTRACTS = HERE
EXAMPLES = HERE / "examples"
DATA_JSON = REPO / "apps/ios/Resources/data.json"
CATALOG_SQLITE = REPO / "apps/ios/Resources/usda_ingredient_catalog.sqlite"

failures: list[str] = []


def check(label: str, fn) -> None:
    try:
        fn()
    except AssertionError as e:
        failures.append(f"FAIL {label}: {e}")
    except Exception as e:  # noqa: BLE001
        failures.append(f"ERROR {label}: {type(e).__name__}: {e}")
    else:
        print(f"ok   {label}")


def load(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


bundle_schema = load(CONTRACTS / "recipe-bundle-v2.schema.json")
identity_schema = load(CONTRACTS / "ingredient-identity.schema.json")
events_schema = load(CONTRACTS / "taste-events-v1.schema.json")
bundle = load(EXAMPLES / "bundle-v2.sample.json")
identity = load(EXAMPLES / "ingredient-identity-map.sample.json")
events = load(EXAMPLES / "taste-events-v1.sample.json")


def meta_schema(name: str, schema):
    Draft202012Validator.check_schema(schema)


def validate(name: str, schema, instance):
    errors = sorted(
        Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(instance),
        key=lambda e: e.path,
    )
    if errors:
        msgs = "; ".join(f"{list(e.path)}: {e.message}" for e in errors[:5])
        raise AssertionError(f"{len(errors)} error(s): {msgs}")


def check_bundle_example():
    validate("recipe bundle", bundle_schema, bundle)
    keys = [i["key"] for i in bundle["ingredients"]]
    assert len(keys) == len(set(keys)), "duplicate ingredient keys"
    ing_by_key = {i["key"]: i for i in bundle["ingredients"]}
    con = sqlite3.connect(CATALOG_SQLITE)
    for i in bundle["ingredients"]:
        if i["fdc_id"] is not None:
            row = con.execute(
                "select 1 from ingredient_catalog where fdc_id=?", (i["fdc_id"],)
            ).fetchone()
            assert row, f"bundle ingredient {i['key']}: fdc_id {i['fdc_id']} not in bundled catalog"
    con.close()
    idset = {r["catalog_id"] for r in bundle["recipes"]}
    assert len(idset) == len(bundle["recipes"]), "duplicate catalog_id"
    for r in bundle["recipes"]:
        assert r["cuisine"] in bundle["cuisines"], f"{r['catalog_id']}: cuisine not declared"
        for n, line in enumerate(r["ingredients"]):
            assert line["key"] in keys, f"{r['catalog_id']}: unknown ingredient key {line['key']}"
        for n, step in enumerate(r["steps"]):
            for u in step["uses"]:
                assert 0 <= u < len(r["ingredients"]), f"{r['catalog_id']} step {n}: uses index {u} out of range"
        assert len(r["steps"]) >= 2, f"{r['catalog_id']}: needs >= 2 steps"
        assert len(r["keywords"]) >= 3, f"{r['catalog_id']}: needs >= 3 keywords"
        if r["nutrition_per_serving"]["coverage"] == "computed":
            for line in r["ingredients"]:
                g = line["quantity"].get("grams")
                if g is None:
                    continue
                assert ing_by_key[line["key"]]["per_100g"] is not None, (
                    f"{r['catalog_id']}: coverage computed but weighed line "
                    f"{line['key']} ({g} g) has no per-100g row"
                )


def check_identity_example():
    validate("identity map", identity_schema, identity)
    legacy = load(DATA_JSON)["ingredients"]
    assert len(legacy) == 50, f"data.json has {len(legacy)} legacy ingredients, expected 50"
    seen = set()
    for e in identity["entries"]:
        lid = e["legacy_id"]
        assert lid not in seen, f"duplicate legacy_id {lid}"
        seen.add(lid)
        assert e["legacy_name"] == legacy[str(lid)][0], f"legacy {lid}: name mismatch with data.json"
        if e["status"] in ("resolved", "proposed"):
            assert e["fdc_id"] is not None, f"legacy {lid}: {e['status']} without fdc_id"
        else:
            assert e["fdc_id"] is None, f"legacy {lid}: unresolved with fdc_id"
    assert seen == set(range(1, 51)), "legacy ids 1..50 must each appear exactly once"
    con = sqlite3.connect(CATALOG_SQLITE)
    for e in identity["entries"]:
        if e["fdc_id"] is not None:
            row = con.execute(
                "select 1 from ingredient_catalog where fdc_id=?", (e["fdc_id"],)
            ).fetchone()
            assert row, f"legacy {e['legacy_id']}: fdc_id {e['fdc_id']} not in bundled catalog"
    con.close()


def check_events_example():
    validate("taste events", events_schema, events)
    recipe_ids = {r["catalog_id"] for r in bundle["recipes"]}
    revision = {r["catalog_id"]: r["revision"] for r in bundle["recipes"]}
    ingredient_keys = {i["key"] for i in bundle["ingredients"]}
    for ev in events:
        rid = ev["recipe_catalog_id"]
        assert rid in recipe_ids, f"event references unknown recipe {rid}"
        assert 1 <= ev["recipe_revision"] <= revision[rid], (
            f"event on {rid}: revision {ev['recipe_revision']} outside shipped revisions 1..{revision[rid]}"
        )
        for sub in ev["substitutions"] or []:
            assert sub["from_key"] in ingredient_keys, f"unknown substitution key {sub['from_key']}"
            assert sub["to_key"] in ingredient_keys, f"unknown substitution key {sub['to_key']}"
    by_type = {e["type"] for e in events}
    expected = {"cook_started", "cook_completed", "cook_abandoned", "recipe_rated",
                "suggestion_accepted", "suggestion_dismissed"}
    assert by_type == expected, f"sample should cover all six event types, missing: {expected - by_type}"
    assert any(ev["recipe_catalog_id"] == "rcp-000002" and ev["recipe_revision"] == 2 for ev in events), (
        "sample must exercise the revision-drift scenario (an event bound to rcp-000002 revision 2)"
    )


def check_spec_consistency():
    spec = (HERE.parent / "SPEC.md").read_text(encoding="utf-8")
    m = re.search(r"`status:\s*([a-z_| ]+?)\s*`", spec)
    assert m, "SPEC.md: rights status list not found"
    spec_statuses = {s.strip() for s in m.group(1).split("|")}
    enum = set(bundle_schema["$defs"]["rights"]["properties"]["status"]["enum"])
    assert spec_statuses == enum, (
        f"SPEC rights statuses {sorted(spec_statuses)} != schema enum {sorted(enum)}"
    )


check("bundle schema is valid JSON Schema 2020-12", lambda: meta_schema("bundle", bundle_schema))
check("identity schema is valid JSON Schema 2020-12", lambda: meta_schema("identity", identity_schema))
check("taste-events schema is valid JSON Schema 2020-12", lambda: meta_schema("events", events_schema))
check("bundle-v2.sample.json validates against recipe-bundle-v2.schema.json", check_bundle_example)
check("ingredient-identity-map.sample.json validates against ingredient-identity.schema.json", check_identity_example)
check("taste-events-v1.sample.json validates against taste-events-v1.schema.json", check_events_example)
check("SPEC rights statuses match the bundle schema enum", check_spec_consistency)

if failures:
    print()
    for f in failures:
        print(f)
    sys.exit(1)
print(f"\nall checks passed ({len(identity['entries'])} identity entries, "
      f"{len(bundle['recipes'])} recipes, {len(events)} events)")
