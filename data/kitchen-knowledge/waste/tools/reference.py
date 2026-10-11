#!/usr/bin/env python3
"""Reference implementation of the FridgeLuck waste-accounting model.

Normative for the arithmetic in data/kitchen-knowledge/waste/model.md.
Loads the three factor files and hand_computed_examples.json, computes every
example from its inline factors, and asserts the result matches the expected
ledger exactly at the specified rounding (grams 1 dp, USD 2 dp, kg CO2e 3 dp,
half-up, decimal arithmetic throughout).

Run from the repo root: python3 data/kitchen-knowledge/waste/tools/reference.py
Exit 0 = all examples reproduce exactly AND every negative case
(negative_cases.json) is refused with its expected reason.

The input contract (model.md section 1) is enforced strictly: a malformed
date or a non-positive grams value refuses the whole event stream, loudly.
"""
import datetime
import json
import math
import os
import re
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


class EventError(ValueError):
    """A malformed or out-of-contract event: the whole event stream is refused."""


REFUSAL_MALFORMED_DATE = "malformed-date"
REFUSAL_NON_POSITIVE_GRAMS = "non-positive-grams"

EVENT_KINDS = ("add", "consume", "adjust", "discard", "expire")

ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_strict_date(value, field, where):
    """Strict ISO calendar date: exactly YYYY-MM-DD and a real calendar day.

    Absent (a missing key or an explicit null) returns None — that is the
    only way to leave a date unset. Anything else raises EventError: a
    malformed date must never be compared as a raw string (lexicographic
    order would happily read "" or " 2026-10-02" or "0000-01-01" as
    on-or-before a real use-by) and must never be treated as absent.
    """
    if value is None:
        return None
    if not isinstance(value, str) or not ISO_DATE_RE.match(value):
        raise EventError(
            f"{REFUSAL_MALFORMED_DATE}: {where}.{field} must be an ISO YYYY-MM-DD "
            f"string or null, got {value!r}"
        )
    year, month, day = (int(part) for part in value.split("-"))
    try:
        datetime.date(year, month, day)
    except ValueError:
        raise EventError(
            f"{REFUSAL_MALFORMED_DATE}: {where}.{field} is not a real calendar "
            f"date: {value!r}"
        ) from None
    return value


def validate_event(event, where):
    """Enforce the model.md section 1 input contract on one event.

    Returns (kind, ingredientKey, grams, on, lotUseBy) with grams a positive
    Decimal. A non-positive grams value (a negative outcome is a data error,
    not savings) or a malformed date refuses the whole stream, loudly —
    never loads as 0 or nil, never reaches the buckets.
    """
    if not isinstance(event, dict):
        raise EventError(f"bad-event: {where} must be an object")
    kind = event.get("kind")
    if kind not in EVENT_KINDS:
        raise EventError(
            f"bad-event: {where}.kind must be one of {EVENT_KINDS}, got {kind!r}"
        )
    key = event.get("ingredientKey")
    if not isinstance(key, str) or not key:
        raise EventError(
            f"bad-event: {where}.ingredientKey must be a non-empty string, got {key!r}"
        )
    grams = event.get("grams")
    if isinstance(grams, bool) or not isinstance(grams, (int, float)) or not math.isfinite(grams):
        raise EventError(
            f"{REFUSAL_NON_POSITIVE_GRAMS}: {where}.grams must be a finite number, got {grams!r}"
        )
    if grams <= 0:
        raise EventError(
            f"{REFUSAL_NON_POSITIVE_GRAMS}: {where}.grams must be positive — a negative "
            f"or zero outcome is a data error, never classified, got {grams!r}"
        )
    on = parse_strict_date(event.get("on"), "on", where)
    use_by = parse_strict_date(event.get("lotUseBy"), "lotUseBy", where)
    return kind, key, D(grams), on, use_by


def bucket_for(kind, on, use_by):
    """Bucket assignment per model.md section 2 (event already validated)."""
    if kind in ("add", "adjust"):
        return "notCounted"
    if kind in ("discard", "expire"):
        return "wasted"
    # kind == "consume"
    if use_by is None or on is None:
        return "consumedUnknown"
    return "saved" if on <= use_by else "usedLate"


def compute_ledger(events, factors):
    """Compute the unrounded ledger plus refusal bookkeeping.

    Every event is validated first (validate_event); a stream containing one
    malformed event is refused in full — no partial ledger, no silent zero.
    """
    buckets = {
        "saved": {}, "usedLate": {}, "consumedUnknown": {}, "wasted": {}, "notCounted": {},
    }
    for i, event in enumerate(events):
        kind, key, grams, on, use_by = validate_event(event, f"events[{i}]")
        target = buckets[bucket_for(kind, on, use_by)]
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


def run_negative_cases(path=None):
    """Run the negative-case suite: malformed input must be refused, loudly.

    Each case's event stream is fed to compute_ledger; the case passes only
    if the engine raises EventError carrying the case's expectedRefusalCode.
    A refused stream produces no ledger at all (fail closed), so a malformed
    date can never fall through a string comparison into "saved" and a
    negative outcome can never be laundered into positive grams. Returns
    the number of failed cases (0 = all refused as required).
    """
    path = path or os.path.join(WASTE_DIR, "negative_cases.json")
    with open(path) as fh:
        doc = json.load(fh)
    cases = doc["data"]["cases"]
    failures = 0
    for case in cases:
        cid, code = case["id"], case["expectedRefusalCode"]
        try:
            compute_ledger(case["events"], case.get("factors", {}))
        except EventError as exc:
            got = str(exc).split(":", 1)[0]
            if got == code:
                print(f"PASS {cid}: refused ({code}) — {case['description']}")
            else:
                failures += 1
                print(f"FAIL {cid}: refused as {got!r}, expected {code!r}")
        except (KeyError, AssertionError, ValueError) as exc:
            failures += 1
            print(f"FAIL {cid}: wrong error kind ({type(exc).__name__}: {exc}), "
                  f"expected EventError ({code})")
        else:
            failures += 1
            print(f"FAIL {cid}: NOT refused — {case['description']} "
                  "(a ledger was produced; malformed input loaded instead of failing loudly)")
    print()
    if failures:
        print(f"FAILED: {failures}/{len(cases)} negative cases were not refused as required")
    else:
        print(f"OK: all {len(cases)} negative cases refused with their expected reason — "
              "malformed dates and non-positive outcomes can never load, never count as saved.")
    return failures


def main():
    if "--negative-cases" in sys.argv[1:]:
        sys.exit(1 if run_negative_cases() else 0)

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
    print()
    negative_failures = run_negative_cases()
    if negative_failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
