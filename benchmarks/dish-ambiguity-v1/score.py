#!/usr/bin/env python3
"""Score dish-ambiguity predictions and generate the verified report.

Usage:
    python3 benchmarks/dish-ambiguity-v1/score.py [--verify-report]

Metric set (per model):
  - top1 / top5 class accuracy over the full test manifest (per-class
    stratification makes the overall figure exact)
  - abstention policy: suggest a specific bundled recipe only when the
    predicted class has status 'exact' AND top1Prob >= tau. tau is chosen on
    DEV predictions as the smallest value reaching >= 0.9 suggestion precision
    (maximum coverage tie-break); if dev cannot reach the target the report
    says so explicitly instead of pretending otherwise
  - at the chosen tau, on TEST: suggestion precision, suggestion coverage over
    eligible (exact/coarse true-class) images, abstention rate, and the
    ambiguity risks: how often the model's top1 lands on an ambiguous class
    (any specific suggestion there would be a guess) and on a coarse class
    (equivalence class - no wrong-rendering risk, only wrong-specificity)

With --verify-report the report is regenerated and byte-compared against the
committed report.md; any drift fails with exit 1.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parents[1]


def canonical_path(p: Path) -> str:
    """Repo-relative path when inside the checkout; bare name otherwise."""
    try:
        return str(p.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return p.name
MODEL_TAGS = ["mobilenet-v2-food101", "vit-base-food101"]
TAU_GRID = [round(x, 3) for x in [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]]
PRECISION_TARGET = 0.9


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def prediction_index(results_dir: Path, stem: str, tag: str) -> tuple[dict, dict]:
    preds = load_json(results_dir / f"predictions-{stem}-{tag}.json")
    idx = {p["path"]: p for p in preds["predictions"]}
    if len(idx) != len(preds["predictions"]):
        raise SystemExit(f"score: duplicate paths in predictions-{stem}-{tag}.json")
    return idx, preds


def suggestion_stats(preds: list[dict], mapping: dict, tau: float,
                     truth_filter: set[str] | None = None) -> dict:
    """Suggestion = predicted class status 'exact' and top1Prob >= tau.

    truth_filter restricts evaluation to images whose TRUE class is in the
    filter (used for coverage over eligible images); precision is computed on
    the unrestricted prediction stream (a suggestion after a misclassification
    is still a wrong suggestion).
    """
    n = suggestions = correct = 0
    for p in preds:
        if truth_filter is not None and p["class"] not in truth_filter:
            continue
        n += 1
        entry = mapping["classes"].get(p["top1Label"], {})
        if entry.get("status") == "exact" and p["top1Prob"] >= tau:
            suggestions += 1
            if p["top1Label"] == p["class"]:
                correct += 1
    return {
        "evaluatedImages": n,
        "suggestions": suggestions,
        "correct": correct,
        "suggestionPrecision": round(correct / suggestions, 4) if suggestions else None,
        "coverage": round(suggestions / n, 4) if n else 0.0,
    }


def top1_top5(preds: list[dict]) -> dict:
    n = len(preds)
    top1 = sum(1 for p in preds if p["top1Label"] == p["class"])
    top5 = sum(1 for p in preds if p["class"] in [t["label"] for t in p["top5"]])
    return {"images": n, "top1Accuracy": round(top1 / n, 4), "top5Accuracy": round(top5 / n, 4)}


def class_status_mix(preds: list[dict], mapping: dict) -> dict:
    mix: dict[str, int] = {}
    for p in preds:
        st = mapping["classes"].get(p["top1Label"], {}).get("status")
        if st is None:
            st = "unknown-label"
        mix[st] = mix.get(st, 0) + 1
    return mix


def choose_tau(dev_preds: list[dict], mapping: dict) -> dict:
    """Smallest tau reaching the precision target; ties broken by coverage."""
    rows = []
    for tau in TAU_GRID:
        s = suggestion_stats(dev_preds, mapping, tau)
        rows.append({"tau": tau, **s})
    ok = [r for r in rows if r["suggestionPrecision"] is not None
          and r["suggestionPrecision"] >= PRECISION_TARGET]
    if ok:
        best = max(ok, key=lambda r: (r["coverage"], -r["tau"]))
        return {"tau": best["tau"], "targetMet": True, "devGrid": rows,
                "devSuggestionPrecision": best["suggestionPrecision"],
                "devCoverage": best["coverage"]}
    best = max(rows, key=lambda r: (r["suggestionPrecision"] or 0.0, r["coverage"]))
    return {"tau": best["tau"], "targetMet": False, "devGrid": rows,
            "devSuggestionPrecision": best["suggestionPrecision"],
            "devCoverage": best["coverage"],
            "note": f"dev could not reach {PRECISION_TARGET:.2f} suggestion precision; "
                    "reported tau is the best-effort maximum and is NOT a validated "
                    "abstention threshold"}


def score_model(tag: str, results_dir: Path, mapping: dict,
                dev_manifest: dict, test_manifest: dict) -> dict:
    idx, raw = prediction_index(results_dir, "test", tag)
    dev_idx, _ = prediction_index(results_dir, "dev_manifest", tag)

    # every test image must have a prediction or a recorded failure
    test_paths = {i["path"] for i in test_manifest["images"]}
    missing = test_paths - set(idx)
    if missing:
        raise SystemExit(f"score: {tag}: {len(missing)} test images have neither a "
                         f"prediction nor a retained failure (e.g. {sorted(missing)[0]})")

    test_preds = [idx[i["path"]] for i in test_manifest["images"] if i["path"] in idx]
    dev_paths = {i["path"] for i in dev_manifest["images"]}
    dev_missing = dev_paths - set(dev_idx)
    if dev_missing:
        raise SystemExit(f"score: {tag}: {len(dev_missing)} dev images missing predictions")
    dev_preds = [dev_idx[i["path"]] for i in dev_manifest["images"] if i["path"] in dev_idx]

    eligible = {c for c, e in mapping["classes"].items() if e["status"] in ("exact", "coarse")}
    tau_choice = choose_tau(dev_preds, mapping)
    test_sugg = suggestion_stats(test_preds, mapping, tau_choice["tau"])
    eligible_sugg = suggestion_stats(test_preds, mapping, tau_choice["tau"], truth_filter=eligible)

    failures = raw["failures"]
    return {
        "model": tag,
        "repo": raw["repo"],
        "revision": raw["revision"],
        "weightsSha256": raw["weights_sha256"],
        "numFailures": len(failures),
        "classAccuracy": top1_top5(test_preds),
        "statusMixTop1": class_status_mix(test_preds, mapping),
        "abstentionPolicy": {
            "selectedOn": "dev",
            "targetSuggestionPrecision": PRECISION_TARGET,
            **tau_choice,
        },
        "testSuggestions": test_sugg,
        "testSuggestionsEligibleOnly": eligible_sugg,
        "eligibleTestImages": len([p for p in test_preds if p["class"] in eligible]),
    }


def render_report(results: list[dict], mapping_path: Path, results_dir: Path) -> str:
    lines = [
        "# dish-ambiguity-v1 report",
        "",
        f"Mapping: `{mapping_path.name}` (sha256 {sha256_file(mapping_path)[:16]}...)",
        f"Results: {canonical_path(results_dir)}",
        "",
        "Food-101 dish labels vs the bundled 166-recipe catalog. A specific recipe",
        "suggestion is emitted only when the predicted class maps to exactly one",
        "bundled recipe ('exact') and its probability clears the dev-selected tau.",
        "",
    ]
    for r in results:
        ca = r["classAccuracy"]
        ap = r["abstentionPolicy"]
        ts = r["testSuggestions"]
        es = r["testSuggestionsEligibleOnly"]
        sm = r["statusMixTop1"]
        lines += [
            f"## {r['model']}",
            "",
            f"- pinned: `{r['repo']}` @ {r['revision'][:12]} "
            f"(weights sha256 {r['weightsSha256'][:16]}...); recorded failures: {r['numFailures']}",
            f"- class accuracy over {ca['images']} test images: "
            f"top1 {ca['top1Accuracy']:.4f}, top5 {ca['top5Accuracy']:.4f}",
            f"- top1 status mix: exact {sm.get('exact', 0)}, coarse {sm.get('coarse', 0)}, "
            f"ambiguous {sm.get('ambiguous', 0)}, unsupported {sm.get('unsupported', 0)}",
            f"- abstention: tau {ap['tau']} selected on dev "
            f"({ap['devSuggestionPrecision']} dev suggestion precision, "
            f"{ap['devCoverage']} dev coverage)"
            + ("" if ap["targetMet"] else f" - TARGET NOT MET ({ap['note']})"),
            f"- unrestricted suggestions at tau: {ts['suggestions']} of "
            f"{ts['evaluatedImages']} test images, precision "
            f"{ts['correct']}/{ts['suggestions']} = {ts['suggestionPrecision']}, "
            f"coverage {ts['coverage']}",
            f"- eligible-only ({r['eligibleTestImages']} images whose true class "
            f"is exact/coarse): {es['suggestions']} suggestions, precision "
            f"{es['correct']}/{es['suggestions']} = {es['suggestionPrecision']}, "
            f"coverage {es['coverage']}",
            "",
        ]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(BENCH_DIR / "results"))
    ap.add_argument("--mapping", default=str(BENCH_DIR / "mapping.food101-v1.json"))
    ap.add_argument("--dev-manifest", default=str(BENCH_DIR / "dev_manifest.json"))
    ap.add_argument("--manifest", default=str(BENCH_DIR / "manifest.json"))
    ap.add_argument("--verify-report", action="store_true")
    args = ap.parse_args()

    results_dir = Path(args.results)
    mapping_path = Path(args.mapping)
    mapping = load_json(mapping_path)
    dev_manifest = load_json(Path(args.dev_manifest))
    test_manifest = load_json(Path(args.manifest))

    results = [score_model(tag, results_dir, mapping, dev_manifest, test_manifest)
               for tag in MODEL_TAGS]
    report = render_report(results, mapping_path, results_dir)
    payload = {
        "schemaVersion": "dish-ambiguity-results-v1",
        "mappingSha256": sha256_file(mapping_path),
        "manifestSha256": sha256_file(Path(args.manifest)),
        "devManifestSha256": sha256_file(Path(args.dev_manifest)),
        "models": results,
    }
    out_json = results_dir / "scored.json"
    out_md = results_dir / "report.md"
    if args.verify_report:
        drifted = []
        if out_json.read_text() != json.dumps(payload, indent=1):
            drifted.append(str(out_json))
        if out_md.read_text() != report:
            drifted.append(str(out_md))
        if drifted:
            print(f"score: verify FAILED: {' and '.join(drifted)} drifted", file=sys.stderr)
            return 1
        print("score: verify OK - scored.json and report.md byte-identical to committed")
        return 0
    out_json.write_text(json.dumps(payload, indent=1))
    out_md.write_text(report)
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
