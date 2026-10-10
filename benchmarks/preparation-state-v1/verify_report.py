#!/usr/bin/env python3
"""Independent verifier for preparation-state-v1 committed results.

Recomputes everything that can be recomputed from committed artifacts and
compares against the committed reports:

  text arms (results/text_arms/)
    - per-prediction outcome re-classification (classify, no model needed)
    - per-arm outcome / per-family / state-confusion / alternative-selection
      summaries vs report.json
    - manifest and predictions sha256 vs report.json
    - per-arm probe counts vs the manifest
    - unrun-arm status recording

  image arm (results/image_inference/)
    - image_report.json input/prediction hashes vs the files on disk
    - metrics recomputed from image_predictions.jsonl vs image_report.json
      (the predictions file stores per-image expected groups, so metrics are
      recomputable without the dataset or taxonomy)

  nutrient consequences (results/nutrient_consequences.json)
    - total wrong_state pairs vs the text predictions
    - image ungrounded-binding counts vs image_predictions.jsonl

Exit 0 = all checks pass; exit 1 = any mismatch (each printed).
Run: python3 verify_report.py [--bench-root benchmarks/preparation-state-v1]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

BENCH_DEFAULT = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH_DEFAULT))

from run import catalog_rows, classify  # noqa: E402


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Checker:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passes = 0

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passes += 1
            print(f"PASS {name}")
        else:
            self.failures.append(f"{name}: {detail}")
            print(f"FAIL {name}: {detail}")


def state_confusion(recs: list[dict], groups_by_base: dict, id_to_group: dict) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in recs:
        if r["outcome"] != "wrong_state":
            continue
        pred_states = ["stateless"]
        pred_group = id_to_group.get(r["predicted_record_id"])
        if pred_group:
            for m in groups_by_base[pred_group]["members"]:
                if m["catalog_id"] == r["predicted_record_id"] and m["states"]:
                    pred_states = m["states"]
        key = f"{r['target_state']}->{','.join(pred_states)}"
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def per_family(recs: list[dict]) -> dict:
    fam: dict[str, dict] = {}
    for name in ("identity", "state", "unknown_state"):
        fr = [r for r in recs if r["family"] == name]
        if not fr:
            continue
        fam[name] = {
            "n": len(fr),
            "correct_incl_abstain": sum(1 for r in fr if r["outcome"] in ("correct", "correct_abstain")),
            "abstain": sum(1 for r in fr if r["outcome"] == "abstain"),
            "wrong_state": sum(1 for r in fr if r["outcome"] == "wrong_state"),
            "wrong_identity": sum(1 for r in fr if r["outcome"] == "wrong_identity"),
            "curated_cross": sum(1 for r in fr if r["outcome"] == "curated_cross"),
        }
    return fam


def alternative_selection(recs: list[dict]) -> dict:
    multi = [r for r in recs if r["family"] in ("state", "unknown_state")]
    return {
        "probes_on_multi_member_test_groups": len(multi),
        "group_correct": sum(1 for r in multi if r["outcome"] not in ("abstain", "wrong_identity", "curated_cross")),
        "exact_record": sum(1 for r in multi if r["outcome"] == "correct"),
        "state_family_exact": sum(1 for r in multi if r["family"] == "state" and r["outcome"] == "correct"),
        "state_family_wrong_state": sum(1 for r in multi if r["family"] == "state" and r["outcome"] == "wrong_state"),
        "unknown_state_correct_abstain": sum(
            1 for r in multi if r["family"] == "unknown_state" and r["outcome"] == "correct_abstain"
        ),
        "unknown_state_wrong_state": sum(
            1 for r in multi if r["family"] == "unknown_state" and r["outcome"] == "wrong_state"
        ),
    }


def verify_text(bench: Path, c: Checker) -> None:
    report = json.loads((bench / "results" / "text_arms" / "report.json").read_text())
    prep = json.loads((bench / "manifest.json").read_text())
    probes_by_id = {p["probe_id"]: p for p in prep["probes"]}
    groups_by_base = {g["group_id"]: g for g in prep["groups"]}
    rows = catalog_rows()
    usda_ids = set(rows)
    id_to_group = {
        m["catalog_id"]: g["group_id"] for g in prep["groups"] for m in g["members"]
    }

    c.check(
        "text.manifest_sha256",
        report["manifest_sha256"] == sha256_file(bench / "manifest.json"),
        "manifest hash mismatch",
    )
    preds_path = bench / "results" / "text_arms" / "predictions.jsonl"
    c.check(
        "text.predictions_sha256",
        report["predictions_sha256"] == sha256_file(preds_path),
        "predictions hash mismatch",
    )

    recs = [json.loads(line) for line in preds_path.read_text().splitlines()]
    bad_outcomes = []
    for r in recs:
        probe = probes_by_id.get(r["probe_id"])
        if probe is None:
            bad_outcomes.append(f"{r['probe_id']}: unknown probe")
            continue
        group = r["probe_id"].split("::", 1)[0]
        expected = classify(r["predicted_record_id"], probe, group, id_to_group, usda_ids)
        if expected != r["outcome"]:
            bad_outcomes.append(f"{r['arm']}/{r['probe_id']}: {r['outcome']} != {expected}")
    c.check("text.outcome_reclassification", not bad_outcomes, f"{len(bad_outcomes)} mismatches, e.g. {bad_outcomes[:3]}")

    for arm, arm_report in report["arms"].items():
        if not arm_report.get("ran"):
            c.check(
                f"text.arm[{arm}].unrun_status",
                isinstance(arm_report.get("status"), str) and not arm_report["ran"],
                "expected unrun status",
            )
            continue
        arm_recs = [r for r in recs if r["arm"] == arm]
        c.check(
            f"text.arm[{arm}].probe_count",
            arm_report.get("probe_count") == len(arm_recs),
            f"report {arm_report.get('probe_count')} != {len(arm_recs)}",
        )
        outcomes: dict[str, int] = {}
        for r in arm_recs:
            outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
        c.check(f"text.arm[{arm}].outcomes", arm_report.get("outcomes") == dict(sorted(outcomes.items())), "outcome counts differ")
        c.check(f"text.arm[{arm}].per_family", arm_report.get("per_family") == per_family(arm_recs), "per-family differs")
        if "state_confusion" in arm_report:
            c.check(
                f"text.arm[{arm}].state_confusion",
                arm_report["state_confusion"] == state_confusion(arm_recs, groups_by_base, id_to_group),
                "confusion table differs",
            )
        if arm == "heldout_alternative":
            c.check(
                "text.arm[heldout_alternative].alternative_selection",
                arm_report.get("alternative_selection") == alternative_selection(arm_recs),
                "alternative selection differs",
            )


def verify_image(bench: Path, c: Checker) -> None:
    image_dir = bench / "results" / "image_inference"
    if not (image_dir / "image_report.json").exists():
        print("SKIP image arm: results/image_inference/image_report.json absent")
        return
    report = json.loads((image_dir / "image_report.json").read_text())
    obs = image_dir / "observations.jsonl.gz"
    preds = image_dir / "image_predictions.jsonl"
    c.check("image.observations_sha256", report["inputs"]["observations_sha256"] == sha256_file(obs), "observations hash mismatch")
    c.check("image.predictions_sha256", report["predictions_sha256"] == sha256_file(preds), "predictions hash mismatch")

    n_images = expected_total = detected_total = any_hit = 0
    spurious = ambiguous_overlap = curated = 0
    sfb_multi = slb_multi = sfb_single = 0
    groups_bound: set[str] = set()
    prep = json.loads((bench / "manifest.json").read_text())
    group_sizes = {g["group_id"]: len(g["members"]) for g in prep["groups"]}
    for line in preds.read_text().splitlines():
        rec = json.loads(line)
        expected_all = set(rec["expected_groups_exact"]) | set(rec["expected_groups_coarse"])
        detected = {d["group_id"] for d in rec["detections"] if d["group_id"]}
        n_images += 1
        expected_total += len(expected_all)
        detected_total += len(detected & expected_all)
        any_hit += 1 if detected & expected_all else 0
        spurious += len(detected - expected_all)
        ambiguous_overlap += len(detected & set(rec["ambiguous_groups"]))
        for d in rec["detections"]:
            gid = d["group_id"]
            if gid is None:
                curated += 1
                continue
            if group_sizes.get(gid, 0) >= 2:
                if d["stateful"]:
                    sfb_multi += 1
                    groups_bound.add(gid)
                else:
                    slb_multi += 1
            elif d["stateful"]:
                sfb_single += 1

    recomputed = {
        "validation_images": n_images,
        "expected_groups": expected_total,
        "expected_groups_detected": detected_total,
        "group_detection_recall": round(detected_total / expected_total, 4) if expected_total else None,
        "image_any_hit_rate": round(any_hit / n_images, 4) if n_images else None,
        "spurious_group_detections": spurious,
        "ambiguous_group_overlaps": ambiguous_overlap,
        "curated_space_detections": curated,
        "state_binding": {
            "multi_member_group_detections": sfb_multi + slb_multi,
            "stateful_binding_ungrounded": sfb_multi,
            "stateful_binding_rate_on_multi": round(sfb_multi / (sfb_multi + slb_multi), 4) if (sfb_multi + slb_multi) else None,
            "multi_member_groups_with_binding": len(groups_bound),
            "single_member_group_stateful_bindings": sfb_single,
        },
    }
    got = report["metrics"]
    diffs = []
    for k, v in recomputed.items():
        if isinstance(v, dict):
            for k2, v2 in v.items():
                if k2 == "note":
                    continue
                if got.get(k, {}).get(k2) != v2:
                    diffs.append(f"{k}.{k2}: {got.get(k, {}).get(k2)} != {v2}")
        elif got.get(k) != v:
            diffs.append(f"{k}: {got.get(k)} != {v}")
    c.check("image.metrics_recomputed", not diffs, "; ".join(diffs[:5]))


def verify_nutrients(bench: Path, c: Checker) -> None:
    nut_path = bench / "results" / "nutrient_consequences.json"
    if not nut_path.exists():
        print("SKIP nutrient consequences: results/nutrient_consequences.json absent")
        return
    nut = json.loads(nut_path.read_text())
    rows = catalog_rows()
    preds_path = bench / "results" / "text_arms" / "predictions.jsonl"
    if preds_path.exists():
        recs = [json.loads(line) for line in preds_path.read_text().splitlines()]
        # a "pair" has both a predicted and a target catalog record; unknown-state
        # probes have no target record, so they cannot contribute a nutrient delta
        total = sum(
            1
            for r in recs
            if r["outcome"] == "wrong_state"
            and r["predicted_record_id"] in rows
            and r["target_record_id"] in rows
        )
        c.check(
            "nutrients.text_wrong_state_pairs",
            nut.get("text_arms_wrong_state_pairs_with_target_record") == total,
            f"{nut.get('text_arms_wrong_state_pairs_with_target_record')} != {total}",
        )
    image_preds = bench / "results" / "image_inference" / "image_predictions.jsonl"
    if image_preds.exists() and "image_inference" in nut:
        prep = json.loads((bench / "manifest.json").read_text())
        group_sizes = {g["group_id"]: len(g["members"]) for g in prep["groups"]}
        bindings = sum(
            1
            for line in image_preds.read_text().splitlines()
            for d in json.loads(line)["detections"]
            if d["group_id"] is not None and group_sizes.get(d["group_id"], 0) >= 2 and d["stateful"]
        )
        c.check(
            "nutrients.image_bindings",
            nut["image_inference"]["ungrounded_stateful_bindings_on_multi_groups"] == bindings,
            f"{nut['image_inference']['ungrounded_stateful_bindings_on_multi_groups']} != {bindings}",
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench-root", default=str(BENCH_DEFAULT))
    args = ap.parse_args()
    bench = Path(args.bench_root)
    c = Checker()
    verify_text(bench, c)
    verify_image(bench, c)
    verify_nutrients(bench, c)
    print(f"\n{c.passes} passed, {len(c.failures)} failed")
    if c.failures:
        for f in c.failures:
            print(f"  FAILED: {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
