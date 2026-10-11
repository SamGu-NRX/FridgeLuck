#!/usr/bin/env python3
"""Reference implementation of the FridgeLuck waste-accounting model.

Normative for the arithmetic in data/kitchen-knowledge/waste/model.md.
Loads the three factor files and hand_computed_examples.json, computes every
example from its inline factors, and asserts the result matches the expected
ledger exactly at the specified rounding (grams 1 dp, USD 2 dp, kg CO2e 3 dp,
half-up, decimal arithmetic throughout).

Run from the repo root: python3 data/kitchen-knowledge/waste/tools/reference.py
Exit 0 = all 20 examples reproduce.
"""
import json
import os
import sys
from decimal import Decimal, ROUND_HALF_UP

HERE = os.path.dirname(os.path.abspath(__file__))
WASTE_DIR = os.path.dirname(HERE)

GRAMS_DP = Decimal("0.1")
USD_DP = Decimal("0.01")
CO2_DP = Decimal("0.001")

LEDGER_FIELDS = [
    "savedGrams", "savedMoneyUsd", "savedKgCo2eLow", "savedKgCo2eCentral", "savedKgCo2eHigh",
    "usedLateGrams", "usedLateMoneyUsd", "usedLateKgCo2eLow", "usedLateKgCo2eCentral", "usedLateKgCo2eHigh",
    "consumedUnknownGrams", "consumedUnknownMoneyUsd", "consumedUnknownKgCo2eLow",
    "consumedUnknownKgCo2eCentral", "consumedUnknownKgCo2eHigh",
    "wastedGrams", "wastedMoneyUsd", "wastedKgCo2eLow", "wastedKgCo2eCentral", "wastedKgCo2eHigh",
    "notCountedGrams",
]

GRAMS_DP_FIELDS = {
    "savedGrams", "usedLateGrams", "consumedUnknownGrams", "wastedGrams", "notCountedGrams",
    "unpricedGrams", "missingEmissionFactorGrams",
}
USD_DP_FIELDS = {
    "savedMoneyUsd", "usedLateMoneyUsd", "consumedUnknownMoneyUsd", "wastedMoneyUsd",
}
CO2_DP_FIELDS = {
    "savedKgCo2eLow", "savedKgCo2eCentral", "savedKgCo2eHigh",
    "usedLateKgCo2eLow", "usedLateKgCo2eCentral", "usedLateKgCo2eHigh",
    "consumedUnknownKgCo2eLow", "consumedUnknownKgCo2eCentral", "consumedUnknownKgCo2eHigh",
    "wastedKgCo2eLow", "wastedKgCo2eCentral", "wastedKgCo2eHigh",
}


def D(value):
    """Exact decimal from a JSON number's string form (never a binary float)."""
    return Decimal(str(value))


def round_field(field, value):
    if field in GRAMS_DP_FIELDS:
        return value.quantize(GRAMS_DP, rounding=ROUND_HALF_UP)
    if field in USD_DP_FIELDS:
        return value.quantize(USD_DP, rounding=ROUND_HALF_UP)
    if field in CO2_DP_FIELDS:
        return value.quantize(CO2_DP, rounding=ROUND_HALF_UP)
    raise AssertionError(f"unknown ledger field: {field}")


def bucket_for(event):
    """Bucket assignment per model.md section 2."""
    kind = event["kind"]
    if kind in ("add", "adjust"):
        return "notCounted"
    if kind in ("discard", "expire"):
        return "wasted"
    if kind == "consume":
        use_by = event.get("lotUseBy")
        on = event.get("on")
        if use_by is None or on is None:
            return "consumedUnknown"
        return "saved" if on <= use_by else "usedLate"
    raise AssertionError(f"unknown event kind: {kind}")


def compute_ledger(events, factors):
    """Compute the unrounded ledger plus refusal bookkeeping."""
    buckets = {
        "saved": {}, "usedLate": {}, "consumedUnknown": {}, "wasted": {}, "notCounted": {},
    }
    for event in events:
        key = event["ingredientKey"]
        grams = D(abs(event["grams"]))
        target = buckets[bucket_for(event)]
        target[key] = target.get(key, Decimal(0)) + grams

    ledger = {name: Decimal(0) for name in LEDGER_FIELDS}
    unpriced_keys, missing_ef_keys = set(), set()
    unpriced_grams, missing_ef_grams = Decimal(0), Decimal(0)

    for bucket, per_key in buckets.items():
        if bucket == "notCounted":
            ledger["notCountedGrams"] = sum(per_key.values(), Decimal(0))
            continue
        prefix = {
            "saved": "saved", "usedLate": "usedLate",
            "consumedUnknown": "consumedUnknown", "wasted": "wasted",
        }[bucket]
        for key, grams in per_key.items():
            factor = factors.get(key, {})
            ledger[f"{prefix}Grams"] += grams
            usd = factor.get("usdPerKg")
            if usd is None:
                unpriced_keys.add(key)
                unpriced_grams += grams
            else:
                ledger[f"{prefix}MoneyUsd"] += grams / Decimal(1000) * D(usd)
            co2 = factor.get("kgCo2ePerKg")
            if co2 is None:
                missing_ef_keys.add(key)
                missing_ef_grams += grams
            else:
                kg = grams / Decimal(1000)
                ledger[f"{prefix}KgCo2eLow"] += kg * D(co2["low"])
                ledger[f"{prefix}KgCo2eCentral"] += kg * D(co2["central"])
                ledger[f"{prefix}KgCo2eHigh"] += kg * D(co2["high"])

    rounded = {name: round_field(name, value) for name, value in ledger.items()}
    rounded["unpricedIngredientKeys"] = sorted(unpriced_keys)
    rounded["unpricedGrams"] = round_field("unpricedGrams", unpriced_grams)
    rounded["missingEmissionFactorKeys"] = sorted(missing_ef_keys)
    rounded["missingEmissionFactorGrams"] = round_field("missingEmissionFactorGrams", missing_ef_grams)
    return rounded


def check_factor_file(name, kind):
    with open(os.path.join(WASTE_DIR, name)) as fh:
        doc = json.load(fh)
    assert doc.get("schemaVersion") == 1, f"{name}: schemaVersion"
    assert doc.get("kind") == kind, f"{name}: kind"
    assert isinstance(doc.get("data"), dict), f"{name}: data"
    return doc


def main():
    emission = check_factor_file("emission_factors.json", "emission-factors")
    price = check_factor_file("price_factors.json", "price-factors")
    loss = check_factor_file("loss_factors.json", "loss-factors")
    with open(os.path.join(WASTE_DIR, "hand_computed_examples.json")) as fh:
        examples = json.load(fh)

    real_prices = {row["ingredientKey"]: row for row in price["data"]["prices"]}
    real_co2 = {row["ingredientKey"]: row for row in emission["data"]["factors"]}

    assert examples.get("schemaVersion") == 1, "examples: schemaVersion"
    assert examples.get("kind") == "hand-computed-examples", "examples: kind"
    data = examples["data"]
    examples_list = data["examples"]
    assert len(examples_list) == 20, f"expected 20 examples, found {len(examples_list)}"

    failures = 0
    for ex in examples_list:
        ex_id = ex["id"]

        # The inline factors must agree with the shipped factor files where both exist.
        for key, f in ex["inputs"]["factors"].items():
            if "usdPerKg" in f and key in real_prices:
                assert D(f["usdPerKg"]) == D(real_prices[key]["usdPerKg"]), (
                    f"{ex_id}: usdPerKg for {key} disagrees with price_factors.json"
                )
            if "kgCo2ePerKg" in f and key in real_co2:
                for bound in ("low", "central", "high"):
                    assert D(f["kgCo2ePerKg"][bound]) == D(real_co2[key]["kgCo2ePerKg"][bound]), (
                        f"{ex_id}: kgCo2ePerKg.{bound} for {key} disagrees with emission_factors.json"
                    )

        computed = compute_ledger(ex["inputs"]["events"], ex["inputs"]["factors"])
        expected = ex["expected"]

        # The expected block must carry the full field set.
        missing_fields = [f for f in LEDGER_FIELDS if f not in expected]
        assert not missing_fields, f"{ex_id}: expected missing fields {missing_fields}"

        problems = []
        for field in LEDGER_FIELDS:
            got, want = computed[field], D(expected[field])
            if got != want:
                problems.append(f"{field}: computed {got}, expected {want}")
        for field in ("unpricedIngredientKeys", "missingEmissionFactorKeys"):
            got, want = sorted(computed[field]), sorted(expected.get(field, []))
            if got != want:
                problems.append(f"{field}: computed {got}, expected {want}")
        for field in ("unpricedGrams", "missingEmissionFactorGrams"):
            got, want = computed[field], D(expected.get(field, 0))
            if got != want:
                problems.append(f"{field}: computed {got}, expected {want}")

        if problems:
            failures += 1
            print(f"FAIL {ex_id}: {ex['description']}")
            for problem in problems:
                print(f"     {problem}")
        else:
            print(f"PASS {ex_id}: {ex['description']}")

    print()
    if failures:
        print(f"FAILED: {failures}/{len(examples_list)} examples did not reproduce")
        sys.exit(1)
    print(f"OK: all {len(examples_list)} hand-computed examples reproduce exactly "
          f"under the stated rounding (grams 1 dp, USD 2 dp, kg CO2e 3 dp, half-up, decimal).")
    print(f"factor files loaded: emission={len(emission['data']['factors'])} rows, "
          f"price={len(price['data']['prices'])} rows, loss={len(loss['data']['factors'])} rows.")


if __name__ == "__main__":
    main()
