"""Build the Nutrition5k per-dish target table with official splits and plate clusters.

Inputs (downloaded from gs://nutrition5k_dataset/nutrition5k_dataset/, CC BY 4.0):
  metadata/dish_metadata_cafe1.csv, dish_metadata_cafe2.csv
  dish_ids/splits/rgb_train_ids.txt, rgb_test_ids.txt,
  dish_ids/splits/depth_train_ids.txt, depth_test_ids.txt

Outputs (committed under experiments/nutrition5k-portion/data/):
  dish_targets.csv      one row per dish: targets, split membership, plate_cluster
  build_audit.json      row-format checks, zero-target counts, cluster stats, split integrity

Plate clusters: the official split keeps all incremental scans of a unique plate in
the same split (README, "Train/Test Splits"), but no explicit plate mapping is
published. We reconstruct plate groups inside the training pool by chain-clustering
dish scan timestamps (unix seconds) within a cafe with a 20-second link threshold,
then verify (nearly) no reconstructed cluster straddles an official split boundary.
Dev-set candidates are plate clusters that lie ENTIRELY inside the official training
split; any cluster that straddles an official boundary is assigned to training so a
dev plate can never be a near-duplicate of a test plate.
"""

from __future__ import annotations

import csv
import json
import sys
from collections import Counter
from pathlib import Path

GAP_SECONDS = 20  # chain-link threshold; see ATTEMPTS.md for the 900s first-attempt failure
DEV_FRACTION = 0.15
SEED = 20261009
# Implausible-target flags (kept in the test set, excluded from fitting; see audit).
MASS_PLAUSIBLE_G = 2000
CAL_PLAUSIBLE_KCAL = 5000

RAW = Path("/home/user/work/n5k-data/raw")
OUT = Path(__file__).resolve().parents[1] / "data"

PREFIX_FIELDS = 6  # dish_id, total_calories, total_mass, total_fat, total_carb, total_protein
CHUNK_FIELDS = 7   # ingr_id, ingr_name, grams, calories, fat, carb, protein


def read_dish_rows() -> tuple[list[dict], dict]:
    rows: list[dict] = []
    audit = {"rows": {}, "format": {}, "zero_targets": {}, "totals_vs_ingredients": {}}
    for cafe in ("cafe1", "cafe2"):
        path = RAW / f"dish_metadata_{cafe}.csv"
        n_rows = 0
        prefix_len_seen: Counter[int] = Counter()
        chunk_ok = 0
        chunk_bad = 0
        with path.open() as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                fields = line.split(",")
                # Auto-detect the prefix length so the README's variable schema
                # (with or without a num_ingrs field) cannot silently corrupt rows.
                detected = None
                for k in (6, 7, 5):
                    if (len(fields) - k) % CHUNK_FIELDS == 0:
                        detected = k
                        break
                if detected is None:
                    chunk_bad += 1
                    audit["format"].setdefault("unparseable_rows", []).append(
                        {"cafe": cafe, "dish_id": fields[0], "n_fields": len(fields)}
                    )
                    continue
                prefix_len_seen[detected] += 1
                (
                    dish_id,
                    total_cal,
                    total_mass,
                    total_fat,
                    total_carb,
                    total_protein,
                ) = fields[:PREFIX_FIELDS]
                ingredients = []
                tail = fields[detected:]
                for i in range(0, len(tail), CHUNK_FIELDS):
                    chunk = tail[i : i + CHUNK_FIELDS]
                    ingredients.append(
                        {
                            "ingr_id": chunk[0],
                            "name": chunk[1],
                            "grams": float(chunk[2]),
                            "calories": float(chunk[3]),
                        }
                    )
                rows.append(
                    {
                        "dish_id": dish_id,
                        "cafe": cafe,
                        "scan_ts": int(dish_id.split("_")[1]),
                        "total_calories": float(total_cal),
                        "total_mass": float(total_mass),
                        "total_fat": float(total_fat),
                        "total_carb": float(total_carb),
                        "total_protein": float(total_protein),
                        "ingredients": ingredients,
                        "n_ingredients": len(ingredients),
                    }
                )
                n_rows += 1
        audit["rows"][cafe] = n_rows
        audit["format"][f"{cafe}_prefix_len_seen"] = dict(prefix_len_seen)
        audit["format"][f"{cafe}_chunk_pad_errors"] = chunk_bad
    return rows, audit


def split_ids(name: str) -> set[str]:
    return set((RAW / name).read_text().split())


def cluster_plates(rows: list[dict]) -> dict[str, str]:
    """Cluster dish ids by scan-time proximity within a cafe."""
    clusters: dict[str, str] = {}
    for cafe in ("cafe1", "cafe2"):
        cafe_rows = sorted((r for r in rows if r["cafe"] == cafe), key=lambda r: r["scan_ts"])
        cluster_idx = 0
        prev_ts = None
        for r in cafe_rows:
            new_cluster = prev_ts is None or r["scan_ts"] - prev_ts > GAP_SECONDS
            if new_cluster:
                cluster_idx += 1
            clusters[r["dish_id"]] = f"{cafe}_c{cluster_idx:05d}"
            prev_ts = r["scan_ts"]
    return clusters


def main() -> int:
    rows, audit = read_dish_rows()
    rgb_train = split_ids("rgb_train_ids.txt")
    rgb_test = split_ids("rgb_test_ids.txt")
    depth_train = split_ids("depth_train_ids.txt")
    depth_test = split_ids("depth_test_ids.txt")

    known = rgb_train | rgb_test
    meta_ids = {r["dish_id"] for r in rows}
    audit["split_integrity"] = {
        "rgb_train": len(rgb_train),
        "rgb_test": len(rgb_test),
        "depth_train": len(depth_train),
        "depth_test": len(depth_test),
        "dishes_with_metadata_missing_from_rgb_split": sorted(meta_ids - known)[:20],
        "count_metadata_missing_from_rgb_split": len(meta_ids - known),
        "rgb_split_ids_missing_metadata": len(known - meta_ids),
        "depth_test_subset_of_rgb_test": depth_test <= rgb_test,
        "depth_train_subset_of_rgb_train": depth_train <= rgb_train,
        "rgb_train_test_overlap": len(rgb_train & rgb_test),
    }

    clusters = cluster_plates(rows)

    # Verify reconstructed clusters never straddle official splits.
    straddle = 0
    cluster_splits: dict[str, set[str]] = {}
    for r in rows:
        cluster_splits.setdefault(clusters[r["dish_id"]], set()).add(
            "train" if r["dish_id"] in rgb_train else "test"
        )
    for cid, splits in cluster_splits.items():
        if len(splits) > 1:
            straddle += 1
    audit["split_integrity"]["clusters_straddling_official_split"] = straddle

    # Zero-target audit: keep them in the test set, handle explicitly in metrics.
    zero_mass = [r["dish_id"] for r in rows if r["total_mass"] <= 0]
    zero_cal = [r["dish_id"] for r in rows if r["total_calories"] <= 0]
    audit["zero_targets"] = {
        "mass_leq_zero": len(zero_mass),
        "calories_leq_zero": len(zero_cal),
        "examples_mass_zero": zero_mass[:10],
        "examples_cal_zero": zero_cal[:10],
        "mass_zero_in_test": sorted(set(zero_mass) & rgb_test)[:10],
    }

    # Do reported totals equal the ingredient sums? (Determines whether a
    # fully-weighed arm would be a trivial oracle.)
    max_mass_gap = 0.0
    max_cal_gap = 0.0
    for r in rows:
        if r["ingredients"]:
            s_mass = sum(i["grams"] for i in r["ingredients"])
            s_cal = sum(i["calories"] for i in r["ingredients"])
            max_mass_gap = max(max_mass_gap, abs(s_mass - r["total_mass"]))
            max_cal_gap = max(max_mass_gap, abs(s_cal - r["total_calories"]))
    audit["totals_vs_ingredients"] = {
        "max_abs_mass_gap": round(max_mass_gap, 6),
        "max_abs_cal_gap": round(max_cal_gap, 6),
    }

    # Dev carve: plate clusters that lie entirely inside official rgb_train.
    # (Straddling clusters go to training so a dev plate can never be a
    #  near-duplicate of an official-test plate.)
    import random

    rng = random.Random(SEED)
    clusters_fully_train = sorted(
        cid for cid, splits in cluster_splits.items() if splits == {"train"}
    )
    rng.shuffle(clusters_fully_train)
    n_dev = round(len(clusters_fully_train) * DEV_FRACTION)
    dev_clusters = set(clusters_fully_train[:n_dev])

    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "dish_targets.csv").open("w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writerow(
            [
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
            ]
        )
        for r in sorted(rows, key=lambda r: r["dish_id"]):
            did = r["dish_id"]
            official = (
                "test"
                if did in rgb_test
                else "train"
                if did in rgb_train
                else "no_rgb_split"
            )
            depth_split = (
                "test"
                if did in depth_test
                else "train"
                if did in depth_train
                else "none"
            )
            if official == "train":
                my_split = "dev" if clusters[did] in dev_clusters else "train"
            else:
                my_split = official  # test / no_rgb_split untouched
            names = "|".join(i["name"] for i in r["ingredients"])
            w.writerow(
                [
                    did,
                    r["cafe"],
                    r["scan_ts"],
                    official,
                    depth_split,
                    clusters[did],
                    my_split,
                    r["total_mass"],
                    r["total_calories"],
                    r["n_ingredients"],
                    names,
                ]
            )

    audit["dev_carve"] = {
        "seed": SEED,
        "dev_fraction": DEV_FRACTION,
        "clusters_fully_inside_official_train": len(clusters_fully_train),
        "dev_plate_clusters": n_dev,
        "dev_dishes": sum(
            1 for r in rows if r["dish_id"] in rgb_train and clusters[r["dish_id"]] in dev_clusters
        ),
    }
    implausible_mass = [r["dish_id"] for r in rows if not (0 < r["total_mass"] <= MASS_PLAUSIBLE_G)]
    implausible_cal = [
        r["dish_id"] for r in rows if not (0 < r["total_calories"] <= CAL_PLAUSIBLE_KCAL)
    ]
    audit["implausible_targets"] = {
        "mass_outside_(0,2000g]": len(implausible_mass),
        "calories_outside_(0,5000kcal]": len(implausible_cal),
        "examples": sorted(set(implausible_mass + implausible_cal))[:10],
        "policy": "flagged; excluded from model fitting; still evaluated in the official test set with a sensitivity breakdown",
    }
    cluster_sizes = Counter(clusters[r["dish_id"]] for r in rows)
    size_hist = Counter(cluster_sizes.values())
    audit["plate_clusters"] = {
        "n_clusters": len(cluster_sizes),
        "size_histogram": {str(k): v for k, v in sorted(size_hist.items())},
        "gap_seconds": GAP_SECONDS,
    }
    (OUT / "build_audit.json").write_text(json.dumps(audit, indent=2))
    print(json.dumps({k: audit[k] for k in ("rows", "split_integrity", "zero_targets", "totals_vs_ingredients", "dev_carve", "plate_clusters")}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
