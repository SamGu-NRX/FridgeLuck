#!/usr/bin/env python3
"""Score a raw arm report against the frozen nonfood-rejection-v1 manifest.

Pipeline semantics this scorer enforces:

  - Verdicts come from policy.verdict under a named policy. The default
    "measured" policy is stratum-blind: predictions use arm output and
    dev-selected thresholds only. The "oracle" policy additionally reads
    the frozen stratum and is an explicitly privileged upper bound — its
    numbers are reported separately, never mixed with measured ones.
  - Either way: a food-control image must clear tau_high to count as
    retained food recall; a negative may be called certainly empty only
    when the pipeline produced no food label and its score sits at or
    below tau_low; any produced food label on a negative is a false
    addition even below the admit bar.
  - All headline rates are computed over photographer groups (group_id):
    a group is a false addition if ANY member image is. Scores and
    confidence distributions are also reported per image for diagnosis.
  - tau_high and tau_low are selected on dev groups only and then applied,
    frozen, to both splits. The scored output records them.

Usage:
    python3 score.py --report reports/raw/my-arm.json
        -> writes results/scored-my-arm.json, prints a table

    python3 score.py --report reports/raw/my-arm.json \
        --verify results/scored-my-arm.json
        -> recomputes everything from the raw report and compares: a
           mismatch in the manifest hash, per-image verdict, or metric
           fails with exit 1 (mutation-detection / tamper check)

Expected dev operating point: false-addition rate <= 1% of dev negative
groups at max retained control recall.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

from policy import POLICIES, verdict

HERE = Path(__file__).resolve().parent
MAX_DEV_FALSE_ADD_RATE = 0.01
GRID = [round(0.01 * i, 2) for i in range(1, 101)]


# ------------------------------------------------------------- grouping ---


def group_records(images):
    """Fold image records into photographer-group records."""
    by_group = defaultdict(list)
    for r in images:
        by_group[r["group_id"]].append(r)
    return {
        gid: {
            "strata": {r["stratum"] for r in rows},
            "splits": {r["split"] for r in rows},
            "max_score": max(r["food_score"] for r in rows),
            "any_produced": any(r["produced_food"] for r in rows),
            "size": len(rows),
        }
        for gid, rows in by_group.items()
    }


# ---------------------------------------------------------- thresholds ---


def select_thresholds(manifest, report_images):
    """Dev-only threshold selection; returns (tau_high, tau_low, diagnostics)."""
    by_id = {r["image_id"]: r for r in report_images}
    dev_images = [by_id[r["image_id"]] for r in manifest["images"] if r["split"] == "dev"]
    groups = group_records(dev_images)

    neg_groups = [g for g in groups.values() if g["strata"] <= {"empty_visible", "opaque_unknown"}]
    ctrl_groups = [g for g in groups.values() if g["strata"] == {"food_control"}]
    if not neg_groups or not ctrl_groups:
        raise SystemExit("dev split has no negative or control groups")

    # tau_low: the highest score any clean dev visible-empty group produced;
    # a dev image at or under it is certain-empty. Produced-food groups
    # never qualify by definition.
    low_scores = [
        g["max_score"] for g in groups.values()
        if g["strata"] == {"empty_visible"} and not g["any_produced"]
    ]
    tau_low = max(low_scores) if low_scores else 0.0

    def fpr(tau):
        return sum(1 for g in neg_groups if g["any_produced"] or g["max_score"] >= tau) / len(neg_groups)

    def recall(tau):
        return sum(1 for g in ctrl_groups if g["max_score"] >= tau) / len(ctrl_groups)

    feasible = [t for t in GRID if fpr(t) <= MAX_DEV_FALSE_ADD_RATE]
    if feasible:
        tau_high = min(feasible, key=lambda t: (-recall(t), t))  # max recall, min tau on ties
        note = f"selected on dev: false-addition rate {fpr(tau_high):.4f} <= {MAX_DEV_FALSE_ADD_RATE}"
    else:
        tau_high = min(GRID, key=lambda t: (fpr(t), -recall(t)))
        note = f"WARNING no grid point meets {MAX_DEV_FALSE_ADD_RATE}; minimized false-addition rate {fpr(tau_high):.4f}"
    return tau_high, tau_low, {
        "dev_negative_groups": len(neg_groups),
        "dev_control_groups": len(ctrl_groups),
        "dev_false_add_rate_at_tau_high": fpr(tau_high),
        "dev_control_recall_at_tau_high": recall(tau_high),
        "selection_note": note,
    }


# ------------------------------------------------------------ metrics ----


def _conf_histogram(images, buckets=10):
    hist = defaultdict(int)
    for r in images:
        hist[min(int(r["food_score"] * buckets), buckets - 1)] += 1
    return {f"{i / buckets:.1f}-{(i + 1) / buckets:.1f}": hist[i] for i in range(buckets) if hist[i]}


def evaluate(manifest, report_images, tau_high, tau_low, policy="measured"):
    by_id = {r["image_id"]: r for r in report_images}
    joined = []
    for m in manifest["images"]:
        r = dict(by_id[m["image_id"]])
        # manifest truth is authoritative for scoring: stratum/role always
        # come from the manifest record, never from the arm's report copy
        r["stratum"] = m["stratum"]
        r["role"] = m["role"]
        r["verdict"] = verdict(policy, m["stratum"], r["food_score"], tau_high, tau_low, r["produced_food"])
        joined.append(r)

    metrics = {"tau_high": tau_high, "tau_low": tau_low}
    for split in ("dev", "test"):
        rows = [r for r in joined if r["split"] == split]
        negs = [r for r in rows if r["role"] == "negative"]
        ctrls = [r for r in rows if r["role"] == "food_control"]
        groups = group_records(rows)
        neg_groups = {gid: g for gid, g in groups.items() if g["strata"] <= {"empty_visible", "opaque_unknown"}}
        ctrl_groups = {gid: g for gid, g in groups.items() if g["strata"] == {"food_control"}}

        fa_groups = [g for g in neg_groups.values() if g["any_produced"] or g["max_score"] >= tau_high]
        ce_groups = [
            gid for gid, g in neg_groups.items()
            if all(r["verdict"] == "empty" for r in rows if r["group_id"] == gid)
        ]
        metrics[split] = {
            "negative_images": len(negs),
            "negative_groups": len(neg_groups),
            "false_addition_groups": len(fa_groups),
            "false_addition_rate_groups": round(len(fa_groups) / len(neg_groups), 6) if neg_groups else None,
            "false_addition_images": sum(1 for r in negs if r["produced_food"] or r["verdict"] == "food"),
            "certain_empty_groups": len(ce_groups),
            "certain_empty_rate_groups": round(len(ce_groups) / len(neg_groups), 6) if neg_groups else None,
            "unknown_neg_groups": len(neg_groups) - len(fa_groups) - len(ce_groups),
            "control_groups": len(ctrl_groups),
            "control_recall_groups": round(
                sum(1 for g in ctrl_groups.values() if g["max_score"] >= tau_high) / len(ctrl_groups), 6
            ) if ctrl_groups else None,
            "control_recall_images": round(
                sum(1 for r in ctrls if r["verdict"] == "food") / len(ctrls), 6) if ctrls else None,
            "score_histogram_negatives": _conf_histogram(negs),
        }
    return metrics, joined


# --------------------------------------------------------------- I/O -----


def manifest_hash_ok(manifest_path, report):
    want = hashlib.sha256(Path(manifest_path).read_bytes()).hexdigest()
    return want == report.get("manifest_sha256"), want


def load_and_check(manifest_path, report_path):
    manifest = json.load(open(manifest_path))
    report = json.load(open(report_path))
    ok, want = manifest_hash_ok(manifest_path, report)
    if not ok:
        raise SystemExit(
            f"manifest hash mismatch: report pinned {report.get('manifest_sha256')}, file is {want}"
        )
    if report.get("manifest_name") != manifest["meta"]["name"]:
        raise SystemExit(f"report is for {report.get('manifest_name')!r}, manifest is {manifest['meta']['name']!r}")
    want_ids = {r["image_id"] for r in manifest["images"]}
    got_ids = [r["image_id"] for r in report["images"]]
    if len(got_ids) != len(want_ids) or set(got_ids) != want_ids:
        raise SystemExit("report image set does not match the manifest")
    if len(got_ids) != len(set(got_ids)):
        raise SystemExit("report contains duplicate image records")
    return manifest, report


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--report", required=True, help="raw report from run.py")
    ap.add_argument("--manifest", default=str(HERE / "manifest.json"))
    ap.add_argument("--verify", default=None, help="scored output to recompute and compare")
    ap.add_argument("--policy", default=None, choices=POLICIES,
                    help="verdict policy: measured (default, stratum-blind) or oracle (privileged)")
    args = ap.parse_args()

    manifest, report = load_and_check(args.manifest, args.report)
    tau_high, tau_low, diag = select_thresholds(manifest, report["images"])
    if args.verify:
        stored_policy = json.load(open(args.verify)).get("policy", "measured")
        if args.policy is not None and args.policy != stored_policy:
            raise SystemExit(f"--policy {args.policy} but stored output was scored under {stored_policy!r}")
        policy = stored_policy
    else:
        policy = args.policy or "measured"
    metrics, joined = evaluate(manifest, report["images"], tau_high, tau_low, policy)

    if args.verify:
        scored = json.load(open(args.verify))
        problems = []
        if scored.get("tau_high") != tau_high or scored.get("tau_low") != tau_low:
            problems.append(
                f"thresholds differ: stored {scored.get('tau_high')}/{scored.get('tau_low')}, "
                f"recomputed {tau_high}/{tau_low}"
            )
        if scored.get("manifest_sha256") != report["manifest_sha256"]:
            problems.append("scored output pins a different manifest hash")
        stored = {r["image_id"]: r.get("verdict") for r in scored.get("images", [])}
        for r in joined:
            if stored.get(r["image_id"]) != r["verdict"]:
                problems.append(
                    f"verdict mismatch for {r['image_id']}: stored {stored.get(r['image_id'])!r}, "
                    f"recomputed {r['verdict']!r}"
                )
        if scored.get("metrics") != metrics:
            problems.append("metrics block differs from recomputation")
        if problems:
            print(f"VERIFY FAIL: {len(problems)} problems")
            for p in problems[:20]:
                print(f"  - {p}")
            raise SystemExit(1)
        print("verify OK: stored scored output reproduces from the raw report and manifest")
        return

    out = {
        "arm": report["arm"],
        "policy": policy,
        "manifest_name": report["manifest_name"],
        "manifest_sha256": report["manifest_sha256"],
        "tau_high": tau_high,
        "tau_low": tau_low,
        "threshold_selection": diag,
        "metrics": metrics,
        "images": [
            {
                "image_id": r["image_id"], "stratum": r["stratum"], "split": r["split"],
                "group_id": r["group_id"], "series_id": r["series_id"], "pair_id": r["pair_id"],
                "food_score": r["food_score"], "produced_food": r["produced_food"],
                "food_labels": r["food_labels"], "verdict": r["verdict"],
            } for r in joined
        ],
    }
    arm = report["arm"]["name"]
    suffix = "" if policy == "measured" else "-oracle"
    out_path = HERE / "results" / f"scored-{arm}{suffix}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=1))

    print(f"taus: tau_high={tau_high} tau_low={tau_low}  ({diag['selection_note']})")
    for split in ("dev", "test"):
        m = metrics[split]
        print(
            f"{split}: false-add {m['false_addition_groups']}/{m['negative_groups']} groups "
            f"({m['false_addition_rate_groups']:.3f}), certain-empty {m['certain_empty_groups']} "
            f"({m['certain_empty_rate_groups']:.3f}), control recall {m['control_recall_groups']:.3f} "
            f"groups / {m['control_recall_images']:.3f} images"
        )
    print(f"policy: {policy}")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
