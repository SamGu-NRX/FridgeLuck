"""The report verifier must detect dropped cases and altered targets."""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "acquisition"))

from conftest import make_manifest, make_product  # noqa: E402


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def build_results(tmp, ocr_rows, target_rows, ref_rows):
    manifest = make_manifest([
        make_product(code=c) for c in ("3017620422003", "3017620422004")
    ])
    mpath = tmp / "manifest.json"
    mpath.write_text(json.dumps(manifest))
    res = tmp / "results"
    (res / "harness").mkdir(parents=True, exist_ok=True)
    write_jsonl(res / "harness" / "targets_output.jsonl", target_rows)
    write_jsonl(res / "harness" / "ocr_front_output.jsonl", ocr_rows)
    write_jsonl(res / "harness" / "reference_output.jsonl", ref_rows)
    return str(mpath), str(res)


def run_score(res, manifest, verify=False):
    cmd = [sys.executable, os.path.join(ROOT, "score.py"), "--results", res, "--manifest", manifest]
    if verify:
        cmd.append("--verify-report")
    return subprocess.run(cmd, capture_output=True, text=True)


def base_rows():
    target_rows = [
        {"image_id": "3017620422003__targets", "targets": [
            {"text": "tomato paste", "tier": "primary", "ingredient_id": 7, "kind": "exact", "matched_token": "tomato paste"},
            {"text": "tomato ketchups", "tier": "context", "ingredient_id": 9, "kind": "catalog", "matched_token": None},
        ]},
        {"image_id": "3017620422004__targets", "targets": [
            {"text": "nutella", "tier": "primary", "ingredient_id": 12, "kind": "exact", "matched_token": "nutella"},
        ]},
    ]
    ocr_rows = [
        {"image_id": "3017620422003__front", "detections": [
            {"ingredient_id": 7, "bucket": "auto", "matched_token": "tomato paste", "source": "ocr"},
        ]},
        {"image_id": "3017620422004__front", "detections": [
            {"ingredient_id": 99, "bucket": "possible", "matched_token": "hazelnut", "source": "ocr"},
        ]},
    ]
    ref_rows = [
        {"image_id": "3017620422003__reference", "detections": [
            {"ingredient_id": 7, "bucket": "auto", "matched_token": "tomato paste", "source": "reference"},
        ]},
        {"image_id": "3017620422004__reference", "detections": []},
    ]
    return target_rows, ocr_rows, ref_rows


def test_verifier_accepts_unmutated_report(tmp_path):
    t, o, r = base_rows()
    m, res = build_results(tmp_path, o, t, r)
    assert run_score(res, m).returncode == 0
    assert run_score(res, m, verify=True).returncode == 0


def test_verifier_detects_dropped_case(tmp_path):
    t, o, r = base_rows()
    m, res = build_results(tmp_path, o, t, r)
    assert run_score(res, m).returncode == 0
    # drop one OCR case from the raw output
    (res_path := os.path.join(res, "harness", "ocr_front_output.jsonl"))
    lines = open(res_path, encoding="utf-8").read().strip().split("\n")
    open(res_path, "w", encoding="utf-8").write("\n".join(lines[:-1]) + "\n")
    p = run_score(res, m, verify=True)
    assert p.returncode != 0
    assert "recomputed" in p.stdout or "dropped" in p.stdout


def test_verifier_detects_altered_target(tmp_path):
    t, o, r = base_rows()
    m, res = build_results(tmp_path, o, t, r)
    assert run_score(res, m).returncode == 0
    # alter a target: promote the context id to primary
    (tpath := os.path.join(res, "harness", "targets_output.jsonl"))
    rows = [json.loads(x) for x in open(tpath, encoding="utf-8") if x.strip()]
    rows[0]["targets"][1]["tier"] = "primary"
    write_jsonl(tpath, rows)
    p = run_score(res, m, verify=True)
    assert p.returncode != 0


def test_verifier_detects_hand_edited_metric(tmp_path):
    t, o, r = base_rows()
    m, res = build_results(tmp_path, o, t, r)
    assert run_score(res, m).returncode == 0
    spath = os.path.join(res, "scores.json")
    stored = json.load(open(spath, encoding="utf-8"))
    stored["ocr"]["all"]["item_hit_rate"] = 1.0
    json.dump(stored, open(spath, "w", encoding="utf-8"))
    assert run_score(res, m, verify=True).returncode != 0
