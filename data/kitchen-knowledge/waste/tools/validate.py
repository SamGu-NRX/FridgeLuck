#!/usr/bin/env python3
"""Validate the FridgeLuck waste factor files (data/kitchen-knowledge/waste/).

Checks envelope conformance, citation resolution, value ranges, and uniqueness.
Run from the repo root: python3 data/kitchen-knowledge/waste/tools/validate.py
Exit 0 = all green.
"""
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.dirname(HERE)

# Selftest hook: --dir points the validator at a mutated copy of the waste
# directory. reference.py still runs against the real tree beside this file,
# so the example reproduction is unaffected by factor mutations.
if "--dir" in sys.argv[1:]:
    DIR = os.path.abspath(sys.argv[sys.argv.index("--dir") + 1])

REQUIRED_SOURCE_FIELDS = ["citationId", "title", "publisher", "url", "retrieved", "licence"]

errors = []
notes = []


def err(msg):
    errors.append(msg)


def load(name):
    path = os.path.join(DIR, name)
    if not os.path.exists(path):
        err(f"{name}: missing file")
        return None
    with open(path) as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError as exc:
            err(f"{name}: invalid JSON ({exc})")
            return None


def finite_number(v):
    """Booleans and non-finite floats are not numbers a factor table may
    carry: True is an int in Python and a NaN slips past `< 0` comparisons
    (SCHEMA.md numeric contract)."""
    return (not isinstance(v, bool) and isinstance(v, (int, float))
            and math.isfinite(v))


def check_source(name, src, where):
    if not isinstance(src, dict):
        err(f"{name}: {where} must be an object")
        return None
    for field in REQUIRED_SOURCE_FIELDS:
        if not src.get(field):
            err(f"{name}: {where}.{field} missing or empty")
    return src.get("citationId")


def citation_ids(name, data):
    if "source" in data:
        cid = check_source(name, data["source"], "data.source")
        return [cid] if cid else []
    if "sources" in data:
        return [c for c in (check_source(name, s, "data.sources[]") for s in data["sources"]) if c]
    err(f"{name}: data.source or data.sources required")
    return []


def check_common_envelope(name, doc, kind):
    if doc is None:
        return None
    if doc.get("schemaVersion") != 1:
        err(f"{name}: schemaVersion must be 1")
    if doc.get("kind") != kind:
        err(f"{name}: kind must be '{kind}', got {doc.get('kind')!r}")
    if not doc.get("retrieved"):
        err(f"{name}: retrieved date missing")
    if not isinstance(doc.get("data"), dict):
        err(f"{name}: data object missing")
        return None
    return doc["data"]


def validate_emission(doc):
    data = check_common_envelope("emission_factors.json", doc, "emission-factors")
    if data is None:
        return set()
    ids = citation_ids("emission_factors.json", data)
    if not data.get("method"):
        err("emission_factors.json: data.method missing")
    keys = set()
    for i, row in enumerate(data.get("factors", [])):
        key = row.get("ingredientKey", "")
        where = f"emission_factors.json factors[{i}] ({key or 'missing key'})"
        if not key:
            err(f"{where}: ingredientKey missing")
        if key in keys:
            err(f"{where}: duplicate ingredientKey")
        keys.add(key)
        if not row.get("owidEntity"):
            err(f"{where}: owidEntity missing")
        rng = row.get("kgCo2ePerKg")
        if not isinstance(rng, dict) or not all(k in rng for k in ("low", "central", "high")):
            err(f"{where}: kgCo2ePerKg must have low/central/high")
        else:
            for k in ("low", "central", "high"):
                if not finite_number(rng[k]) or rng[k] < 0:
                    err(f"{where}: kgCo2ePerKg.{k} must be a finite number >= 0")
            if not rng["low"] <= rng["central"] <= rng["high"]:
                err(f"{where}: kgCo2ePerKg must satisfy low <= central <= high")
        if row.get("rangeBasis") not in ("point", "cited-range"):
            err(f"{where}: rangeBasis must be 'point' or 'cited-range'")
        if row.get("citationId") not in ids:
            err(f"{where}: citationId {row.get('citationId')!r} does not resolve")
        if not row.get("note"):
            err(f"{where}: note missing (mapping provenance required)")
    if not data.get("factors"):
        err("emission_factors.json: no factors")
    return keys


def validate_price(doc):
    data = check_common_envelope("price_factors.json", doc, "price-factors")
    if data is None:
        return set()
    ids = citation_ids("price_factors.json", data)
    if not data.get("method"):
        err("price_factors.json: data.method missing")
    if data.get("region") != "United States, national average":
        err("price_factors.json: data.region must be 'United States, national average'")
    if not data.get("asOf"):
        err("price_factors.json: data.asOf missing (month)")
    keys = set()
    for i, row in enumerate(data.get("prices", [])):
        key = row.get("ingredientKey", "")
        where = f"price_factors.json prices[{i}] ({key or 'missing key'})"
        if not key:
            err(f"{where}: ingredientKey missing")
        if key in keys:
            err(f"{where}: duplicate ingredientKey")
        keys.add(key)
        if not finite_number(row.get("usdPerKg")) or row["usdPerKg"] < 0:
            err(f"{where}: usdPerKg must be a finite number >= 0")
        if not row.get("displayQuantity"):
            err(f"{where}: displayQuantity missing")
        if not finite_number(row.get("displayPriceUsd")) or row["displayPriceUsd"] < 0:
            err(f"{where}: displayPriceUsd must be a finite number >= 0")
        if not row.get("sourceSeries"):
            err(f"{where}: sourceSeries missing (BLS series id or ERS table)")
        if row.get("citationId") not in ids:
            err(f"{where}: citationId {row.get('citationId')!r} does not resolve")
    if not data.get("prices"):
        err("price_factors.json: no prices")
    return keys


def validate_loss(doc):
    data = check_common_envelope("loss_factors.json", doc, "loss-factors")
    if data is None:
        return set()
    ids = citation_ids("loss_factors.json", data)
    if not data.get("method"):
        err("loss_factors.json: data.method missing")
    keys = set()
    for i, row in enumerate(data.get("factors", [])):
        key = row.get("ingredientKey", "")
        where = f"loss_factors.json factors[{i}] ({key or 'missing key'})"
        if not key:
            err(f"{where}: ingredientKey missing")
        if key in keys:
            err(f"{where}: duplicate ingredientKey")
        keys.add(key)
        share = row.get("edibleSharePct")
        if share is not None and (not finite_number(share) or not 0 <= share <= 100):
            err(f"{where}: edibleSharePct must be null or 0..100")
        loss = row.get("consumerLevelLossPct")
        if not finite_number(loss) or not 0 <= loss <= 100:
            err(f"{where}: consumerLevelLossPct must be 0..100")
        if not row.get("note"):
            err(f"{where}: note missing (table/column provenance required)")
        if row.get("citationId") not in ids:
            err(f"{where}: citationId {row.get('citationId')!r} does not resolve")
    if not data.get("factors"):
        err("loss_factors.json: no factors")
    return keys


def validate_examples_envelope():
    path = os.path.join(DIR, "hand_computed_examples.json")
    if not os.path.exists(path):
        notes.append("hand_computed_examples.json: not present yet (milestone 2)")
        return
    doc = load("hand_computed_examples.json")
    if doc is None:
        return
    data = check_common_envelope("hand_computed_examples.json", doc, "hand-computed-examples")
    if data is None:
        return
    examples = data.get("examples", [])
    if len(examples) != 21:
        err(f"hand_computed_examples.json: expected exactly 21 examples, found {len(examples)}")
    seen = set()
    for ex in examples:
        eid = ex.get("id", "?")
        if eid in seen:
            err(f"hand_computed_examples.json: duplicate id {eid}")
        seen.add(eid)
        for section in ("inputs", "expected", "workings"):
            if section not in ex:
                err(f"hand_computed_examples.json {eid}: {section} missing")


def main():
    em = validate_emission(load("emission_factors.json"))
    pr = validate_price(load("price_factors.json"))
    lo = validate_loss(load("loss_factors.json"))
    validate_examples_envelope()
    # Reproduce every hand-computed example through the reference
    # implementation (stdlib Decimal, half-up, sums unrounded and rounded
    # once). This is what pins the refusal round-once rule: ex-21's binding
    # totals (100.04 + 200.04 -> 300.1, not 300.0) only reproduce when grams
    # are summed unrounded across ingredients before the single rounding.
    ref = subprocess.run(
        [sys.executable, os.path.join(HERE, "reference.py")],
        capture_output=True, text=True,
    )
    if ref.returncode != 0:
        err("reference.py did not reproduce all hand-computed examples:\n"
            + (ref.stdout or "")[-2000:] + (ref.stderr or "")[-500:])
    notes.append(f"key coverage: emission={len(em)} price={len(pr)} loss={len(lo)}")
    overlap = len(em & pr & lo)
    notes.append(f"keys present in all three files: {overlap}")
    for n in notes:
        print(f"note: {n}")
    if errors:
        print(f"\nFAIL ({len(errors)} error(s)):")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("\nOK: factor files conform")


if __name__ == "__main__":
    main()
