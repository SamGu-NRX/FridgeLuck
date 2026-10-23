#!/usr/bin/env python3
"""Selftest for waste/tools/validate.py (stdlib only).

Copies the real factor files into a temp directory, applies one mutation per
case, and runs the validator against the copy via --dir; the validator must
refuse exactly the broken shapes. reference.py keeps reading the real tree
beside this script, so the 21-example reproduction is unaffected by the
mutations.

Run: python3 selftest.py   (exit 0 = all cases green)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WASTE_DIR = os.path.dirname(HERE)
FILES = [
    "emission_factors.json",
    "price_factors.json",
    "loss_factors.json",
    "hand_computed_examples.json",
]

failures = []


def run_validator(data_dir):
    return subprocess.run(
        [sys.executable, os.path.join(HERE, "validate.py"), "--dir", data_dir],
        capture_output=True, text=True,
    )


def copied_tree():
    tmp = tempfile.mkdtemp(prefix="waste-selftest-")
    for fn in FILES:
        shutil.copy(os.path.join(WASTE_DIR, fn), tmp)
    return tmp


def case(name, filename, mutate, expect_substr, expect_pass=False):
    tmp = copied_tree()
    try:
        path = os.path.join(tmp, filename)
        doc = json.load(open(path))
        mutate(doc)
        with open(path, "w") as f:
            json.dump(doc, f)
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
    print("waste validator selftest:")
    case("valid copy passes", "emission_factors.json", lambda d: None,
         "", expect_pass=True)
    # Numeric contract (SCHEMA.md): ranges must satisfy low <= central <= high
    # with finite non-negative values; money and percentages refuse booleans
    # and non-finite floats.
    case("misordered emission range refuses", "emission_factors.json",
         lambda d: d["data"]["factors"][0]["kgCo2ePerKg"].update(low=99.49),
         "must satisfy low <= central <= high")
    case("negative emission factor refuses", "emission_factors.json",
         lambda d: d["data"]["factors"][0]["kgCo2ePerKg"].update(low=-1.0),
         "must be a finite number >= 0")
    case("boolean emission factor refuses", "emission_factors.json",
         lambda d: d["data"]["factors"][0]["kgCo2ePerKg"].update(low=True),
         "must be a finite number >= 0")
    case("negative usdPerKg refuses", "price_factors.json",
         lambda d: d["data"]["prices"][0].update(usdPerKg=-1.0),
         "must be a finite number >= 0")
    case("NaN usdPerKg refuses", "price_factors.json",
         lambda d: d["data"]["prices"][0].update(usdPerKg=float("nan")),
         "must be a finite number >= 0")
    case("negative consumer loss refuses", "loss_factors.json",
         lambda d: d["data"]["factors"][0].update(consumerLevelLossPct=-5),
         "must be 0..100")
    case("over-cap emission factor refuses", "emission_factors.json",
         lambda d: d["data"]["factors"][0]["kgCo2ePerKg"].update(high=300.0),
         "implausibly large")
    case("over-cap usdPerKg refuses", "price_factors.json",
         lambda d: d["data"]["prices"][0].update(usdPerKg=2000.0),
         "implausibly large")
    if failures:
        print(f"\nSELFTEST FAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("\nSELFTEST PASS: the validator refuses every broken shape and passes the valid tree")


if __name__ == "__main__":
    main()
