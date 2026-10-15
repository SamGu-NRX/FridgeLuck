#!/usr/bin/env python3
"""Validate PR41's committed artifacts against the locked contract; emit counts.

Run from the repository root:
    python3 experiments/portion-intervals/check_inputs.py

Read-only: validates plate groups, units, and split provenance in
experiments/nutrition5k-portion (data + outputs), cross-checks the committed
counts against build_audit.json / MANIFEST.json / dev_metrics.csv, and writes
results/input_validation.json with eligible / unknown record counts.

Hard violations exit non-zero. Missing information is reported as unknown,
never guessed.
"""

from __future__ import annotations

import csv
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import reader  # noqa: E402
from protocol import eligible_calibration_rows  # noqa: E402

REPO = HERE.parents[1]
N5K = REPO / "experiments" / "nutrition5k-portion"
RESULTS = HERE / "results"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def cross_checks(target_rows, estimate_rows, audit, manifest, frozen) -> tuple[list[dict], dict]:
    """Count cross-checks against the committed audit/manifest numbers."""
    checks: list[dict] = []
    my_counts = Counter(r["my_split"] for r in target_rows)
    official_counts = Counter(r["official_rgb_split"] for r in target_rows)
    cafe_counts = Counter(r["cafe"] for r in target_rows)

    si = audit["split_integrity"]
    devc = audit["dev_carve"]

    def check(name: str, expected, actual):
        checks.append(
            {"name": name, "expected": expected, "actual": actual, "ok": expected == actual}
        )

    # my_split composition implied by the committed audit:
    #   train = official rgb_train minus dev dishes; test/no_rgb_split untouched.
    check(
        "my_split.train == rgb_train - dev_dishes",
        si["rgb_train"] - devc["dev_dishes"],
        my_counts.get("train", 0),
    )
    check("my_split.test == official rgb_test", si["rgb_test"], my_counts.get("test", 0))
    check(
        "my_split.dev == audit dev_dishes", devc["dev_dishes"], my_counts.get("dev", 0)
    )
    check(
        "my_split.no_rgb_split == dishes missing from rgb splits",
        si["count_metadata_missing_from_rgb_split"],
        my_counts.get("no_rgb_split", 0),
    )
    check("official_rgb_split.train", si["rgb_train"], official_counts.get("train", 0))
    check("official_rgb_split.test", si["rgb_test"], official_counts.get("test", 0))
    check(
        "official_rgb_split.no_rgb_split",
        si["count_metadata_missing_from_rgb_split"],
        official_counts.get("no_rgb_split", 0),
    )
    check("rows.cafe1", audit["rows"]["cafe1"], cafe_counts.get("cafe1", 0))
    check("rows.cafe2", audit["rows"]["cafe2"], cafe_counts.get("cafe2", 0))
    check(
        "total rows == dishes 5006 (manifest dishes_in_bucket + metadata-only dishes)",
        5006,
        len(target_rows),
    )

    # Zero-target audit agreement.
    zt = audit["zero_targets"]
    zero_mass = sum(1 for r in target_rows if float(r["total_mass_g"]) <= 0)
    zero_cal = sum(1 for r in target_rows if float(r["total_calories_kcal"]) <= 0)
    check("zero_targets.mass_leq_zero", zt["mass_leq_zero"], zero_mass)
    check("zero_targets.calories_leq_zero", zt["calories_leq_zero"], zero_cal)

    # Population sizes vs manifest: 507 = official rgb test with overhead imagery.
    est_counter = Counter(
        (r["population"], r["arm"], r["target"]) for r in estimate_rows
    )
    n_rgb_test = manifest["overhead_imagery_available"]["official_rgb_test"]
    for pop, arms in reader.POPULATION_ARMS.items():
        for arm in arms:
            for tgt in reader.TARGETS:
                expected = (
                    (n_rgb_test if pop != "rgb_test_plausible" else n_rgb_test - 1)
                    if pop in ("rgb_test", "rgb_test_plausible")
                    else n_rgb_test
                )
                actual = est_counter.get((pop, arm, tgt), 0)
                check(
                    f"estimates rows population={pop} arm={arm} target={tgt}",
                    expected,
                    actual,
                )

    # Median-arm anchor (frozen constants, up to the file's 2-decimal rounding).
    anchors = frozen["arms"]["median"]["train_medians"]
    for tgt, expected in sorted(anchors.items()):
        preds = [
            float(r["y_pred"])
            for r in estimate_rows
            if r["arm"] == "median" and r["target"] == tgt
        ]
        ok = bool(preds) and len(set(preds)) == 1 and all(
            abs(p - float(expected)) <= 0.005 + 1e-9 for p in preds
        )
        check(f"median anchor {tgt} == FROZEN train_medians (2-decimal rounding)", True, ok)

    # Dev-carve arithmetic: imagery dishes in official rgb train = 2,755;
    # PR41 fit on 2,360 (dev_metrics.fit_n) and used 395 dev rows for selection,
    # so 212 of the 607 committed dev dishes have UNKNOWN imagery membership.
    fit_n_mass = None
    dm = N5K / "outputs" / "dev_metrics.csv"
    if dm.exists():
        with open(dm, newline="") as fh:
            for row in csv.DictReader(fh):
                if row["arm"] == "rgb" and row["target"] == "mass_g":
                    fit_n_mass = int(row["fit_n"])
    imagery_train = manifest["overhead_imagery_available"]["in_official_rgb_splits"] - n_rgb_test
    check(
        "imagery dishes in official rgb train == fit_n(rgb,mass_g) + 395 dev (manifest dev carve)",
        imagery_train,
        (fit_n_mass + 395) if fit_n_mass is not None else None,
    )

    unknown = {
        "test_dishes_without_predictions": sum(
            1
            for r in target_rows
            if r["my_split"] == "test"
            and r["dish_id"] not in {e["dish_id"] for e in estimate_rows}
        ),
        "no_rgb_split_dishes": my_counts.get("no_rgb_split", 0),
        "dev_dishes_committed": my_counts.get("dev", 0),
        "dev_dishes_with_imagery_implied_by_manifest": 395,
        "dev_dishes_imagery_membership_unknown": max(my_counts.get("dev", 0) - 395, 0),
    }
    return checks, unknown


def main() -> int:
    targets_path = N5K / "data" / "dish_targets.csv"
    estimates_path = N5K / "outputs" / "estimates_test.csv"
    frozen_path = N5K / "FROZEN_CONFIG.json"
    audit_path = N5K / "data" / "build_audit.json"
    manifest_path = N5K / "MANIFEST.json"

    try:
        target_rows = reader.load_targets(targets_path)
        estimate_rows = reader.load_estimates(estimates_path, target_rows)
        unit_flags = reader.unit_flags(target_rows)
        provenance = reader.split_provenance(target_rows, estimate_rows)
        frozen = json.loads(frozen_path.read_text())
        anchors = reader.median_anchor_check(estimate_rows, frozen)
    except reader.ContractError as exc:
        print(f"HARD CONTRACT VIOLATION: {exc}")
        return 1

    audit = json.loads(audit_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    checks, unknown = cross_checks(target_rows, estimate_rows, audit, manifest, frozen)
    straddles = reader.cluster_straddle_details(target_rows)
    unknown["straddle_clusters_inherited"] = [s["plate_cluster"] for s in straddles]
    unknown["straddle_test_dishes_inherited"] = sorted(
        d for s in straddles for d in s["test_dishes"]
    )

    # Eligible test records per (population, arm, target) and zero exclusions.
    eligible: dict = defaultdict(dict)
    zeros: dict = defaultdict(int)
    for r in estimate_rows:
        key = (r["population"], r["arm"], r["target"])
        eligible[key][r["dish_id"]] = r
        if r["y_true"] <= 0:
            zeros[key] += 1
    eligible_counts = {
        f"{pop}/{arm}/{tgt}": {
            "n_records": len(records),
            "n_clusters": len({rec["plate_cluster"] for rec in records.values()}),
            "n_zero_excluded_from_coverage": zeros.get((pop, arm, tgt), 0),
        }
        for (pop, arm, tgt), records in sorted(eligible.items())
    }

    # Eligible calibration pool (median arm; the only arm whose dev predictions
    # are derivable from committed artifacts -- the frozen constants).
    dev_rows = [r for r in target_rows if r["my_split"] == "dev"]
    cal = {}
    for tgt, spec in reader.TARGETS.items():
        _, counts = eligible_calibration_rows(dev_rows, spec)
        cal[tgt] = counts

    report = {
        "experiment": "portion-intervals",
        "role": "read-only validation of PR41 locked outputs",
        "inputs": {
            str(p.relative_to(REPO)): {"sha256": sha256(p)}
            for p in (targets_path, estimates_path, frozen_path, audit_path, manifest_path)
        },
        "counts": {
            "dishes_total": len(target_rows),
            "my_split": dict(Counter(r["my_split"] for r in target_rows)),
            "official_rgb_split": dict(Counter(r["official_rgb_split"] for r in target_rows)),
            "cafe": dict(Counter(r["cafe"] for r in target_rows)),
            "estimates_rows_total": len(estimate_rows),
            "eligible_test_records": eligible_counts,
            "eligible_calibration_records_median_arm": cal,
            "unknown": unknown,
            "split_provenance": provenance,
            "cluster_straddles": straddles,
        },
        "unit_flags": unit_flags,
        "median_anchors": anchors,
        "cross_checks": checks,
    }
    failed = [c for c in checks if not c["ok"]]

    RESULTS.mkdir(parents=True, exist_ok=True)
    out_path = RESULTS / "input_validation.json"
    out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    print(f"validated {len(target_rows)} target rows, {len(estimate_rows)} estimate rows")
    print(f"eligible test records: {len(eligible_counts)} (population, arm, target) cells")
    for key, entry in eligible_counts.items():
        print(f"  {key}: n={entry['n_records']} clusters={entry['n_clusters']} zero={entry['n_zero_excluded_from_coverage']}")
    print("eligible calibration pool (median arm, dev rows, locked eligibility):")
    for tgt, counts in cal.items():
        print(f"  {tgt}: eligible={counts['n_eligible']} zero_excluded={counts['n_zero_excluded']} implausible_excluded={counts['n_implausible_excluded']}")
    print(f"unknown: {json.dumps(unknown, sort_keys=True)}")
    print(f"unit flags: mass implausible={unit_flags['mass_g']['implausible_outside_range']}, energy implausible={unit_flags['energy_kcal']['implausible_outside_range']} (flagged and kept)")
    if failed:
        print(f"FAILED cross-checks: {len(failed)}")
        for c in failed:
            print(f"  {c['name']}: expected={c['expected']!r} actual={c['actual']!r}")
        return 1
    print(f"OK: 0 hard violations, {len(checks)} cross-checks passed")
    print(f"wrote {out_path.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
