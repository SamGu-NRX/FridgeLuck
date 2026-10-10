#!/usr/bin/env python3
"""Validate the substitution evidence set and print coverage counts.

Checks, in order:
  1. Production ground truth: re-parse SubstitutionService.swift and compare
     with the committed pairs snapshot (drift / missing-reference control).
  2. Pair evidence table: exactly the production pairs, one row each, schema
     valid, every cited source id present in sources.csv.
  3. Context cases: >= 200 rows; every row grounded in the bundled recipes
     (recipe exists, original ingredient present in the stated role with the
     stated grams); verdicts recomputed from pair evidence match.
  4. Built-in negative controls (always run):
       a. missing-reference control  - a case citing a non-production pair or
          a non-bundled recipe must be rejected;
       b. incompatible-function control - a case whose context function the
          pair's evidence marks unsuitable must yield verdict 'unsupported',
          and a row claiming 'verified' for it must be rejected.

Exit code 0 = all checks pass. Prints counts at the end.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "tools"))
from build_cases import COLUMNS, build_cases, verdict_for, FUNCTIONS  # noqa: E402
from extract_production_map import parse_service  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[4]  # file -> substitution-eval -> Tools -> ios -> apps -> repo
TOOL_DIR = Path(__file__).resolve().parent
EVIDENCE_DIR = TOOL_DIR / "evidence"
CONTEXTS_CSV = EVIDENCE_DIR / "context_cases.csv"


def fail(errors: list, msg: str):
    errors.append(msg)


def norm_pairs(pairs):
    return sorted(
        (p["originalId"], p["substituteId"], round(p["ratio"], 6)) for p in pairs
    )


def check_pair_level(errors):
    service = REPO_ROOT / "apps/ios/Platform/Persistence/Services/SubstitutionService.swift"
    snapshot_path = EVIDENCE_DIR / "pairs.snapshot.json"
    service_pairs, _region_hash = parse_service(service)
    snap = json.loads(snapshot_path.read_text())

    if norm_pairs(service_pairs) != norm_pairs(snap["pairs"]):
        fail(errors, "pairs.snapshot.json does not match SubstitutionService.swift (drift)")
    if snap.get("pair_count") != len(service_pairs):
        fail(errors, "pair_count field disagrees with pairs list")
    # The generated Swift fixtures must match the evidence byte-for-byte, or
    # the Swift replay tests and the Python evidence set disagree.
    from render_swift_fixture import render, render_contexts  # noqa: PLC0415

    fixtures = [
        (REPO_ROOT / "apps/ios/Tests/SubstitutionEvidencePairs+Generated.swift", render(snap)),
        (None, None),  # placeholder replaced below
    ]
    import csv  # noqa: PLC0415

    with open(CONTEXTS_CSV, newline="", encoding="utf-8") as f:
        contexts = list(csv.DictReader(f))
    fixtures[1] = (
        REPO_ROOT / "apps/ios/Tests/SubstitutionEvidenceContexts+Generated.swift",
        render_contexts(contexts),
    )
    for fixture_path, rendered in fixtures:
        if not fixture_path.exists():
            fail(errors, f"generated Swift fixture missing: {fixture_path.name}; run render_swift_fixture.py")
            continue
        actual = fixture_path.read_text(encoding="utf-8")
        if rendered != actual:
            fail(errors, f"generated Swift fixture is stale: {fixture_path.name}; rerun render_swift_fixture.py")
    return service_pairs


def check_pair_evidence(errors, service_pairs):
    prod = {(p["originalId"], p["substituteId"]) for p in service_pairs}
    with (EVIDENCE_DIR / "pair_evidence.csv").open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    seen = set()
    sources = set()
    with (EVIDENCE_DIR / "sources.csv").open(newline="", encoding="utf-8") as f:
        for s in csv.DictReader(f):
            sources.add(s["source_id"])

    required_cols = {
        "pair_id", "original_id", "original_name", "substitute_id", "substitute_name",
        "production_ratio", "evidence_level", "supported_functions",
        "unsuitable_functions", "ratio_status", "expected_ratio",
        "evidence_sources", "assessment",
    }
    for row in rows:
        pid = row["pair_id"]
        key = tuple(int(x) for x in pid.split("-"))
        if key not in prod:
            fail(errors, f"pair_evidence row {pid} is not a production pair (missing reference)")
        if key in seen:
            fail(errors, f"pair_evidence row {pid} duplicated")
        seen.add(key)
        missing = required_cols - set(row)
        if missing:
            fail(errors, f"pair_evidence row {pid} missing columns {sorted(missing)}")
        if row["evidence_level"] not in ("sourced", "partial", "unsupported"):
            fail(errors, f"pair_evidence row {pid}: bad evidence_level {row['evidence_level']!r}")
        if row["ratio_status"] not in ("sourced", "convention", "conflict", "unsupported"):
            fail(errors, f"pair_evidence row {pid}: bad ratio_status {row['ratio_status']!r}")
        for fn in filter(None, (row["supported_functions"] + ";" + row["unsuitable_functions"]).split(";")):
            if fn not in FUNCTIONS:
                fail(errors, f"pair_evidence row {pid}: unknown function {fn!r}")
        for sid in filter(None, row["evidence_sources"].split(";")):
            if sid not in sources:
                fail(errors, f"pair_evidence row {pid}: unknown source id {sid!r}")
        if row["evidence_level"] == "sourced" and row["ratio_status"] != "sourced":
            fail(errors, f"pair_evidence row {pid}: evidence_level sourced requires ratio_status sourced")

    missing_pairs = prod - seen
    if missing_pairs:
        fail(errors, f"production pairs with no evidence row: {sorted(missing_pairs)}")
    return {row["pair_id"]: row for row in rows}


def _load_catalog():
    data = json.loads((REPO_ROOT / "apps/ios/Resources/data.json").read_text())
    recipes = {r[0]: r for r in data["recipes"]}
    ingredients = {int(k): v[0] for k, v in data["ingredients"].items()}
    return recipes, ingredients


def check_case_rows(rows, errors, pair_evidence, recipes, ingredients):
    """Validate case rows against the bundled catalog and pair evidence.

    Split out from check_cases so the negative controls can inject synthetic
    rows without touching the committed CSVs.
    """
    seen_ids = set()
    for row in rows:
        cid = row["case_id"]
        if cid in seen_ids:
            fail(errors, f"case id {cid} duplicated")
        seen_ids.add(cid)

        rid = int(row["recipe_id"])
        if rid not in recipes:
            fail(errors, f"{cid}: recipe {rid} not in bundled data (missing reference)")
            continue
        recipe = recipes[rid]
        title, required, optional = recipe[1], recipe[4], recipe[5]
        if row["recipe_title"] != title:
            fail(errors, f"{cid}: recipe_title does not match bundled data")
        if row["original_name"] != ingredients.get(int(row["original_id"]), "?"):
            fail(errors, f"{cid}: original_name does not match catalog")
        if row["substitute_name"] != ingredients.get(int(row["substitute_id"]), "?"):
            fail(errors, f"{cid}: substitute_name does not match catalog")

        role_groups = {"required": required, "optional": optional}
        group = role_groups.get(row["ingredient_role"])
        if group is None:
            fail(errors, f"{cid}: bad ingredient_role {row['ingredient_role']!r}")
            continue
        present = [grams for iid, grams in group if iid == int(row["original_id"])]
        if not present:
            fail(errors, f"{cid}: original ingredient not in recipe {rid} {row['ingredient_role']} list")
        elif abs(present[0] - float(row["original_grams"])) > 1e-9:
            fail(errors, f"{cid}: original_grams does not match bundled data")

        if row["context_function"] not in FUNCTIONS:
            fail(errors, f"{cid}: unknown context_function {row['context_function']!r}")
        ev = pair_evidence.get(row["pair_id"])
        if ev is None:
            fail(errors, f"{cid}: pair {row['pair_id']} has no evidence row (missing reference)")
            continue
        expected = verdict_for(ev, row["context_function"])
        if row["verdict"] != expected:
            fail(
                errors,
                f"{cid}: verdict {row['verdict']!r} inconsistent with pair evidence "
                f"(expected {expected!r} for function {row['context_function']!r})",
            )


def check_cases(errors, pair_evidence):
    with (EVIDENCE_DIR / "context_cases.csv").open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if tuple(reader.fieldnames) != tuple(COLUMNS):
            fail(errors, "context_cases.csv columns do not match the expected schema")
            return None
        rows = list(reader)

    if len(rows) < 200:
        fail(errors, f"context_cases.csv has {len(rows)} rows; need >= 200")

    recipes, ingredients = _load_catalog()
    check_case_rows(rows, errors, pair_evidence, recipes, ingredients)
    return rows


def run_controls(pair_evidence, recipes=None, ingredients=None):
    """Negative controls. Returns (missing_reference_ok, incompatible_function_ok, detail)."""
    detail = {}

    # (a) missing-reference control: cases citing a non-production pair and a
    # non-bundled recipe must be rejected by the row-level validator. Two
    # synthetic rows so each bad reference is independently tripped.
    recipes, ingredients = recipes or {}, ingredients or {}
    if not recipes:
        recipes, ingredients = _load_catalog()
    bad_pair_row = {
        "case_id": "ctrl-missing-ref-pair", "pair_id": "99-98",
        "original_id": "14", "original_name": "butter", "substitute_id": "16",
        "substitute_name": "olive_oil", "recipe_id": "2", "recipe_title": "t",
        "ingredient_role": "required", "original_grams": "1",
        "context_function": "fat", "function_basis": "control",
        "verdict": "verified", "production_ratio": "1.0",
    }
    bad_recipe_row = {
        "case_id": "ctrl-missing-ref-recipe", "pair_id": "14-16",
        "original_id": "14", "original_name": "butter", "substitute_id": "16",
        "substitute_name": "olive_oil", "recipe_id": "99999", "recipe_title": "x",
        "ingredient_role": "required", "original_grams": "1",
        "context_function": "fat", "function_basis": "control",
        "verdict": "verified", "production_ratio": "1.0",
    }
    ctrl_errors = []
    check_case_rows([bad_pair_row, bad_recipe_row], ctrl_errors, pair_evidence, recipes, ingredients)
    flagged_pair = any("no evidence row" in e for e in ctrl_errors)
    flagged_recipe = any("not in bundled data" in e for e in ctrl_errors)
    missing_ref_ok = flagged_pair and flagged_recipe
    detail["missing_reference"] = (
        "ok: bogus pair and recipe both flagged"
        if missing_ref_ok
        else f"FAIL: pair_flagged={flagged_pair} recipe_flagged={flagged_recipe} errors={ctrl_errors}"
    )

    # (b) incompatible-function control: butter->olive oil marks 'binding'
    # unsuitable; a 'verified' row claiming binding must be rejected.
    ev = pair_evidence["14-16"]
    verdict = verdict_for(ev, "binding")
    if verdict != "unsupported":
        detail["incompatible_function"] = (
            f"FAIL: butter->olive_oil in a binding context computed verdict {verdict!r}"
        )
    else:
        detail["incompatible_function"] = "ok: binding context for butter->olive_oil computes 'unsupported'"
    incompatible_ok = verdict == "unsupported"
    return missing_ref_ok, incompatible_ok, detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    errors = []
    service_pairs = check_pair_level(errors)
    pair_evidence = check_pair_evidence(errors, service_pairs)
    rows = check_cases(errors, pair_evidence)
    missing_ok, incompatible_ok, control_detail = run_controls(pair_evidence)
    if not missing_ok:
        fail(errors, "missing-reference control failed")
    if not incompatible_ok:
        fail(errors, "incompatible-function control failed")

    for e in errors:
        print("ERROR:", e)
    if not args.quiet:
        for k, v in control_detail.items():
            print(f"control[{k}]: {v}")

    if rows:
        counts = {}
        functions = {}
        for r in rows:
            counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
            functions[r["context_function"]] = functions.get(r["context_function"], 0) + 1
        print(f"pairs: {len(service_pairs)}  contexts: {len(rows)}")
        print("verdict counts:", json.dumps(counts, sort_keys=True))
        print("function counts:", json.dumps(functions, sort_keys=True))
        sourced = counts.get("verified", 0)
        print(f"sourced ratio: {sourced}/{len(rows)} = {sourced / len(rows):.4f}")

    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
