"""Contract reader for the Nutrition5k portion-estimation outputs (PR 41).

This module READ-ONLY validates the locked output contract committed by
``experiments/nutrition5k-portion`` (PR 41, branch ``obv/fl-next-portion-estimates``):
plate groups, units, and split provenance. It never writes to, re-fits, or
re-scores that experiment's data, models, or scorer.

What "unit validation" can mean here, stated precisely: grams and kcal overlap
in magnitude on this dataset (typical plates are 30-800 on both scales), so no
per-value magnitude heuristic can certify a unit by itself. Units are validated
by contract anchoring instead:

1. cross-file equality -- every estimates row's ``y_true`` must equal the
   ``dish_targets.csv`` value for the same (dish, target) exactly;
2. locked plausibility ranges from ``FROZEN_CONFIG.json`` (mass in (0, 2000] g,
   energy in (0, 5000] kcal) -- violations are flagged and COUNTED, never
   deleted (the locked policy keeps implausible targets in the official
   numbers); a gross scale error (e.g. grams stored as milligrams) trips a
   hard tripwire when more than half the column falls outside the range;
3. locked median anchors -- ``median``-arm predictions must equal the frozen
   ``train_medians`` constants.

Negative controls for all three live in ``tests/``: a leaked test group
(a dev row scored as test -- hard-rejected) and two swapped gram/kcal
controls (a column swap in the target table; a per-row y_true swap in the
estimates file) must all be rejected. Plate clusters that straddle the
OFFICIAL rgb split are an inherited property of PR41's committed data (the
official split is by dish, not by plate): they are REPORTED with full
member detail, never silently fixed and never silently ignored.
"""

from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path

TARGETS = {
    "mass_g": {
        "unit": "grams",
        "lo_exclusive": 0.0,
        "hi_inclusive": 2000.0,
        "targets_column": "total_mass_g",
    },
    "energy_kcal": {
        "unit": "kcal",
        "lo_exclusive": 0.0,
        "hi_inclusive": 5000.0,
        "targets_column": "total_calories_kcal",
    },
}

# Populations committed by PR41's evaluate.py, and the arms each may contain.
# rgbd exists only where raw depth exists (the depth_test population).
POPULATION_ARMS = {
    "rgb_test": ("median", "rgb", "foodlist"),
    "rgb_test_plausible": ("median", "rgb", "foodlist"),
    "depth_test": ("median", "rgb", "rgbd", "foodlist"),
}

MY_SPLITS = ("train", "dev", "test", "no_rgb_split")
# my_split must be consistent with the official RGB split it derives from.
MY_SPLIT_TO_OFFICIAL = {
    "train": "train",
    "dev": "train",
    "test": "test",
    "no_rgb_split": "no_rgb_split",
}

TARGET_COLUMNS = {
    "dish_id",
    "cafe",
    "scan_ts",
    "official_rgb_split",
    "official_depth_split",
    "plate_cluster",
    "my_split",
    "total_mass_g",
    "total_calories_kcal",
    "n_ingredients",
    "ingredient_names",
}

ESTIMATE_COLUMNS = {
    "dish_id",
    "plate_cluster",
    "population",
    "arm",
    "target",
    "y_true",
    "y_pred",
}

CAFES = ("cafe1", "cafe2")


class ContractError(ValueError):
    """A locked-contract violation in the read-only inputs."""


def _read_csv(path: Path, required: set[str], label: str) -> list[dict]:
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        header = set(reader.fieldnames or ())
        if header != required:
            missing = sorted(required - header)
            extra = sorted(header - required)
            raise ContractError(
                f"{label}: column contract mismatch (missing={missing}, unexpected={extra})"
            )
        return list(reader)


def _finite(value: str, label: str) -> float:
    try:
        x = float(value)
    except (TypeError, ValueError):
        raise ContractError(f"{label}: not a finite number ({value!r})") from None
    if x != x or x in (float("inf"), float("-inf")):
        raise ContractError(f"{label}: not a finite number ({value!r})")
    return x


def load_targets(path: Path) -> list[dict]:
    """Load and structurally validate dish_targets.csv (raises ContractError)."""
    rows = _read_csv(path, TARGET_COLUMNS, "dish_targets.csv")
    seen: set[str] = set()
    for i, r in enumerate(rows, start=2):  # start=2: header is line 1
        label = f"dish_targets.csv row {i}"
        did = (r["dish_id"] or "").strip()
        if not did:
            raise ContractError(f"{label}: empty dish_id")
        if did in seen:
            raise ContractError(f"{label}: duplicate dish_id {did!r}")
        seen.add(did)

        cluster = (r["plate_cluster"] or "").strip()
        if not cluster:
            raise ContractError(f"{label}: empty plate_cluster (plate groups are contract)")

        if r["cafe"] not in CAFES:
            raise ContractError(f"{label}: unknown cafe {r['cafe']!r}")
        try:
            int(r["scan_ts"])
        except ValueError:
            raise ContractError(f"{label}: scan_ts not an int ({r['scan_ts']!r})") from None

        if r["my_split"] not in MY_SPLITS:
            raise ContractError(f"{label}: unknown my_split {r['my_split']!r}")
        expected_official = MY_SPLIT_TO_OFFICIAL[r["my_split"]]
        if r["official_rgb_split"] != expected_official:
            raise ContractError(
                f"{label}: split provenance broken -- my_split={r['my_split']!r} "
                f"requires official_rgb_split={expected_official!r}, "
                f"found {r['official_rgb_split']!r}"
            )
        if r["official_rgb_split"] not in ("train", "test", "no_rgb_split"):
            raise ContractError(f"{label}: unknown official_rgb_split {r['official_rgb_split']!r}")

        for tname, spec in TARGETS.items():
            _finite(r[spec["targets_column"]], f"{label} {tname}")

        try:
            if int(r["n_ingredients"]) < 0:
                raise ValueError
        except ValueError:
            raise ContractError(f"{label}: n_ingredients not a non-negative int") from None
    return rows


def cluster_straddle_details(rows: list[dict]) -> list[dict]:
    """Clusters whose plate appears in more than one official rgb split.

    Inherited-data property (PR41's official split is by dish, not by plate):
    reported, never silently fixed and never silently ignored. The scored test
    dishes of such clusters get a straddle-excluded sensitivity population;
    calibration pools are dev-only and checked for overlap separately (the
    dev/scored-test overlap remains a hard ContractError in split_provenance).
    """
    cluster_splits: dict[str, set[str]] = defaultdict(set)
    for r in rows:
        if r["official_rgb_split"] != "none":
            cluster_splits[r["plate_cluster"]].add(r["official_rgb_split"])
    out = []
    for cluster in sorted(c for c, s in cluster_splits.items() if len(s) > 1):
        members = [
            {"dish_id": r["dish_id"], "official_rgb_split": r["official_rgb_split"], "my_split": r["my_split"]}
            for r in rows
            if r["plate_cluster"] == cluster
        ]
        out.append(
            {
                "plate_cluster": cluster,
                "official_rgb_splits": sorted(cluster_splits[cluster]),
                "members": members,
                "test_dishes": [m["dish_id"] for m in members if m["my_split"] == "test"],
            }
        )
    return out


def unit_flags(target_rows: list[dict]) -> dict:
    """Count unit-range violations per target (flagged and kept, locked policy).

    Raises ContractError only on a gross scale error: more than half the column
    outside the locked plausibility range means the column cannot be the unit
    it claims (swapped-unit tripwire). Moderate implausibility (the committed
    data has e.g. 6 mass and 243 kcal outliers across 5,006 dishes) is reported,
    never deleted.
    """
    flags: dict = {}
    for tname, spec in TARGETS.items():
        col = spec["targets_column"]
        vals = [float(r[col]) for r in target_rows]
        n = len(vals)
        lo, hi = spec["lo_exclusive"], spec["hi_inclusive"]
        n_implausible = sum(1 for v in vals if not (lo < v <= hi))
        n_leq_lo = sum(1 for v in vals if v <= lo)
        entry = {
            "unit": spec["unit"],
            "n": n,
            "implausible_outside_range": n_implausible,
            "n_leq_zero": n_leq_lo,
            "implausible_fraction": (n_implausible / n) if n else 0.0,
            "policy": "flagged and kept (locked policy); excluded from fitting by PR41",
        }
        if n and entry["implausible_fraction"] > 0.5:
            raise ContractError(
                f"unit tripwire: {tname} column has {n_implausible}/{n} values outside the "
                f"locked {spec['unit']} plausibility range ({lo}, {hi}] -- scale error or "
                f"swapped units suspected"
            )
        flags[tname] = entry
    return flags


def load_estimates(path: Path, target_rows: list[dict]) -> list[dict]:
    """Load and validate estimates_test.csv against the target table (raises ContractError)."""
    raw = _read_csv(path, ESTIMATE_COLUMNS, "estimates_test.csv")
    tby = {r["dish_id"]: r for r in target_rows}
    out: list[dict] = []
    for i, r in enumerate(raw, start=2):
        label = f"estimates_test.csv row {i}"
        pop = r["population"]
        arm = r["arm"]
        tgt = r["target"]
        if pop not in POPULATION_ARMS:
            raise ContractError(f"{label}: unknown population {pop!r}")
        if tgt not in TARGETS:
            raise ContractError(f"{label}: unknown target {tgt!r}")
        if arm not in POPULATION_ARMS[pop]:
            raise ContractError(
                f"{label}: arm {arm!r} is not part of population {pop!r} "
                f"(allowed: {POPULATION_ARMS[pop]})"
            )
        y_true = _finite(r["y_true"], f"{label} y_true")
        y_pred = _finite(r["y_pred"], f"{label} y_pred")

        t = tby.get(r["dish_id"])
        if t is None:
            raise ContractError(f"{label}: dish {r['dish_id']!r} not in dish_targets.csv")
        if t["my_split"] != "test":
            raise ContractError(
                f"{label}: split provenance broken -- estimates row for dish "
                f"{r['dish_id']!r} whose my_split is {t['my_split']!r} "
                f"(predictions are test-only)"
            )
        if r["plate_cluster"] != t["plate_cluster"]:
            raise ContractError(
                f"{label}: plate group mismatch for {r['dish_id']!r} "
                f"(estimates {r['plate_cluster']!r} vs targets {t['plate_cluster']!r})"
            )
        expected = float(t[TARGETS[tgt]["targets_column"]])
        if y_true != expected:
            raise ContractError(
                f"{label}: y_true {y_true!r} != dish_targets {expected!r} for "
                f"{r['dish_id']!r} / {tgt} -- unit or provenance error"
            )
        out.append(
            {
                "dish_id": r["dish_id"],
                "plate_cluster": r["plate_cluster"],
                "population": pop,
                "arm": arm,
                "target": tgt,
                "y_true": y_true,
                "y_pred": y_pred,
            }
        )
    return out


def split_provenance(target_rows: list[dict], estimate_rows: list[dict]) -> dict:
    """Check dev/test plate-group disjointness and score-set composition.

    Raises ContractError on leakage (a plate cluster shared between dev rows
    and scored test rows, or between dev and my_split=test rows). Returns a
    report dict with populations, strata, and unknown-prediction counts.
    """
    dev_clusters = {r["plate_cluster"] for r in target_rows if r["my_split"] == "dev"}
    test_clusters = {r["plate_cluster"] for r in target_rows if r["my_split"] == "test"}
    pred_clusters = {r["plate_cluster"] for r in estimate_rows}

    leaked_dev_vs_pred = dev_clusters & pred_clusters
    if leaked_dev_vs_pred:
        raise ContractError(
            "plate-group leakage: "
            f"{len(leaked_dev_vs_pred)} cluster(s) appear in both dev rows and scored "
            f"test predictions: {sorted(leaked_dev_vs_pred)[:5]}"
        )
    leaked_dev_vs_test = dev_clusters & test_clusters
    if leaked_dev_vs_test:
        raise ContractError(
            "plate-group leakage: "
            f"{len(leaked_dev_vs_test)} cluster(s) appear in both dev and my_split=test "
            f"rows: {sorted(leaked_dev_vs_test)[:5]}"
        )

    test_dishes = {r["dish_id"] for r in target_rows if r["my_split"] == "test"}
    pred_dishes = {r["dish_id"] for r in estimate_rows}

    dishes_by_pop: dict[str, set] = defaultdict(set)
    clusters_by_pop: dict[str, set] = defaultdict(set)
    for r in estimate_rows:
        dishes_by_pop[r["population"]].add(r["dish_id"])
        clusters_by_pop[r["population"]].add(r["plate_cluster"])

    # Strata available on the scored set: plate-cluster size within the scored
    # test dishes (singleton scans vs multi-dish plates). Cafes do NOT vary on
    # the scored set (cafe2 has no official rgb split), so no cafe strata exist.
    size_by_cluster: dict[str, int] = defaultdict(int)
    for r in estimate_rows:
        size_by_cluster[r["plate_cluster"]] += 1
    # cluster size should come from the scored population's dish count per cluster
    strata = {
        "size1": sum(1 for c, k in size_by_cluster.items() if k == 1),
        "size_ge2": sum(1 for c, k in size_by_cluster.items() if k >= 2),
    }
    size_histogram = defaultdict(int)
    for k in size_by_cluster.values():
        size_histogram[k] += 1

    return {
        "dev_clusters": len(dev_clusters),
        "scored_test_clusters": len(pred_clusters),
        "test_dishes_in_targets": len(test_dishes),
        "test_dishes_with_predictions": len(pred_dishes & test_dishes),
        "test_dishes_without_predictions_unknown": len(test_dishes - pred_dishes),
        "populations": {
            pop: {"n_dishes": len(dishes_by_pop[pop]), "n_clusters": len(clusters_by_pop[pop])}
            for pop in sorted(dishes_by_pop)
        },
        "strata_on_scored_set": strata,
        "cluster_size_histogram_on_scored_set": {
            str(k): v for k, v in sorted(size_histogram.items())
        },
    }


def median_anchor_check(estimate_rows: list[dict], frozen: dict) -> dict:
    """Median-arm predictions must be constant and equal the frozen medians.

    The committed estimates file stores median predictions rounded to 2
    decimals (e.g. 206.37 for frozen 206.369995), so the anchor holds up to
    that rounding: |pred - frozen| <= 0.005 for every row AND every row's
    prediction is identical (the frozen-constant property).
    """
    medians = frozen["arms"]["median"]["train_medians"]
    result: dict = {}
    for tgt, expected in sorted(medians.items()):
        preds = {float(r["y_pred"]) for r in estimate_rows if r["arm"] == "median" and r["target"] == tgt}
        if not preds:
            result[tgt] = {"status": "no_median_rows", "expected": expected}
            continue
        if len(preds) != 1:
            result[tgt] = {
                "status": "not_constant",
                "expected": expected,
                "n_distinct_predictions": len(preds),
            }
            continue
        actual = preds.pop()
        max_dev = abs(actual - float(expected))
        if max_dev > 0.005 + 1e-9:
            raise ContractError(
                f"median anchor broken for {tgt}: prediction {actual!r} != frozen "
                f"train_medians {expected!r} beyond the estimates file's 2-decimal "
                f"rounding (max |dev| {max_dev:.6f})"
            )
        result[tgt] = {
            "status": "ok",
            "expected": float(expected),
            "observed": actual,
            "max_abs_deviation": max_dev,
            "tolerance": "estimates file stores median predictions rounded to 2 decimals",
        }
    return result


def validate(
    targets_path: Path, estimates_path: Path, frozen_path: Path | None = None
) -> dict:
    """Full contract validation; raises ContractError on any hard violation."""
    target_rows = load_targets(targets_path)
    estimate_rows = load_estimates(estimates_path, target_rows)
    report: dict = {
        "unit_flags": unit_flags(target_rows),
        "split_provenance": split_provenance(target_rows, estimate_rows),
        "cluster_straddles": cluster_straddle_details(target_rows),
    }
    if frozen_path is not None:
        import json

        frozen = json.loads(Path(frozen_path).read_text())
        report["median_anchors"] = median_anchor_check(estimate_rows, frozen)
    return report
