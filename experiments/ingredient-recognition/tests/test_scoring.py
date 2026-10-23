"""Scorer hand-case and corruption tests.

The taxonomy CSV is the real committed one (read-only); the manifest and
observations are synthetic so every expected number is hand-computed.
Taxonomy anchors used (from taxonomy/foodseg103_to_catalog.csv):
- class 15 "milk":    exact   -> target {13}
- class 46 "steak":   coarse  -> target {38}
- class 3  "french fries": ambiguous -> target(s) incl. {10}
- class 1  "candy":   unsupported -> no targets
"""

import gzip
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

EXPERIMENT = Path(__file__).resolve().parent.parent
SCORE = EXPERIMENT / "scoring" / "score.py"
SWEEP = EXPERIMENT / "scoring" / "threshold_sweep.py"


def _det(ing_id: int, conf: float) -> dict:
    return {"ingredient_id": ing_id, "confidence": conf, "original_label": "", "provenance": "curated"}


def _manifest() -> dict:
    return {
        "images": [
            {"image_id": "0", "split": "validation", "classes_on_image": "15"},
            {"image_id": "1", "split": "validation", "classes_on_image": "15"},
            {"image_id": "2", "split": "validation", "classes_on_image": "1"},
            {"image_id": "3", "split": "validation", "classes_on_image": "46,3"},
            {"image_id": "4", "split": "train", "classes_on_image": "15"},  # other split: ignored
        ]
    }


def _observations() -> list[dict]:
    return [
        # hit on the exact target plus an unjustified detection
        {"image_id": 0, "detections": [_det(13, 0.9), _det(5, 0.5)]},
        # abstain: supported GT class, no detections
        {"image_id": 1, "detections": []},
        # no-claim violation: unsupported-only image that still emits
        {"image_id": 2, "detections": [_det(13, 0.4)]},
        # coarse hit and ambiguous hit on the same image
        {"image_id": 3, "detections": [_det(38, 0.8), _det(10, 0.6)]},
    ]


@pytest.fixture()
def run_dir(tmp_path: Path) -> Path:
    d = tmp_path / "sc"
    d.mkdir()
    (d / "manifest.json").write_text(json.dumps(_manifest()))
    (d / "id2label.json").write_text(json.dumps({"0": "background"}))
    with gzip.open(d / "obs.jsonl.gz", "wt") as f:
        for rec in _observations():
            f.write(json.dumps(rec) + "\n")
    return d


def _score(run_dir: Path) -> dict:
    proc = subprocess.run(
        [sys.executable, str(SCORE), "--observations", str(run_dir / "obs.jsonl.gz"),
         "--split", "validation", "--manifest", str(run_dir / "manifest.json"),
         "--id2label", str(run_dir / "id2label.json"), "--out-prefix", "t",
         "--out-dir", str(run_dir)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads((run_dir / "t_scores.json").read_text())


def test_hand_case_recall_and_precision(run_dir: Path):
    s = _score(run_dir)
    # supported instances: img0 milk, img1 milk, img3 steak, img3 fries = 4
    # hits: img0 (13), img3 (38), img3 (10) = 3
    assert s["instance_recall"]["all"] == pytest.approx(0.75)
    assert s["instance_recall"]["exact"] == pytest.approx(0.5)      # img0 hit, img1 miss
    assert s["instance_recall"]["coarse"] == pytest.approx(1.0)     # img3 steak
    assert s["instance_recall"]["ambiguous"] == pytest.approx(1.0)  # img3 fries
    # detections counted only on images with mapped GT:
    # img0 [13,5], img3 [38,10] = 4; correct: 13, 38, 10 = 3
    # (img2's violation detection is reported via no_claim_violations instead)
    assert s["detections_total"] == 4
    assert s["detections_correct"] == 3
    assert s["detection_precision"] == pytest.approx(0.75)
    assert s["abstain_images_with_mapped_gt"] == 1
    assert s["no_claim_violations"] == 1
    assert s["mapping_coverage"]["gt_instances_with_targets"] == 4
    assert s["mapping_coverage"]["gt_instances_unsupported"] == 1


def test_hand_case_per_image_outcomes(run_dir: Path):
    _score(run_dir)
    rows = {
        r["image_id"]: r
        for r in map(json.loads, gzip.open(run_dir / "t_per_image.jsonl.gz", "rt"))
    }
    assert rows[0]["outcome"] == "mixed"
    assert rows[1]["outcome"] == "abstain"
    assert rows[2]["outcome"] == "no_claim"
    assert rows[3]["outcome"] == "all_correct"


def test_unsupported_only_image_without_detections_is_no_claim(tmp_path: Path):
    m = {"images": [{"image_id": "0", "split": "validation", "classes_on_image": "1"}]}
    (tmp_path / "manifest.json").write_text(json.dumps(m))
    (tmp_path / "id2label.json").write_text("{}")
    with gzip.open(tmp_path / "obs.jsonl.gz", "wt") as f:
        f.write(json.dumps({"image_id": 0, "detections": []}) + "\n")
    proc = subprocess.run(
        [sys.executable, str(SCORE), "--observations", str(tmp_path / "obs.jsonl.gz"),
         "--split", "validation", "--manifest", str(tmp_path / "manifest.json"),
         "--id2label", str(tmp_path / "id2label.json"), "--out-prefix", "t",
         "--out-dir", str(tmp_path)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    s = json.loads((tmp_path / "t_scores.json").read_text())
    assert s["no_claim_images"] == 1
    assert s["no_claim_violations"] == 0


def test_missing_detection_field_fails_loudly(tmp_path: Path):
    m = {"images": [{"image_id": "0", "split": "validation", "classes_on_image": "15"}]}
    (tmp_path / "manifest.json").write_text(json.dumps(m))
    (tmp_path / "id2label.json").write_text("{}")
    with gzip.open(tmp_path / "obs.jsonl.gz", "wt") as f:
        f.write(json.dumps({"image_id": 0, "crops": []}) + "\n")  # detections key lost
    proc = subprocess.run(
        [sys.executable, str(SCORE), "--observations", str(tmp_path / "obs.jsonl.gz"),
         "--split", "validation", "--manifest", str(tmp_path / "manifest.json"),
         "--id2label", str(tmp_path / "id2label.json"), "--out-prefix", "t"],
        capture_output=True, text=True,
    )
    assert proc.returncode != 0
    assert "malformed observation record" in (proc.stderr + proc.stdout)


def _load_sweep():
    spec = importlib.util.spec_from_file_location("threshold_sweep", SWEEP)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_derive_detections_hand_case():
    """Absorbers skipped, best-per-ingredient across crops, strict > threshold."""
    mod = _load_sweep()
    rec = {
        "crops": [
            {"id": "full", "labels": [
                {"name": "Rice", "prob": 0.35, "resolved_id": 2, "is_absorber": False},
                {"name": "a prepared dish on a plate", "prob": 0.9, "resolved_id": None, "is_absorber": True},
            ]},
            {"id": "center", "labels": [
                {"name": "Rice", "prob": 0.989, "resolved_id": 2, "is_absorber": False},
                {"name": "Chicken Breast", "prob": 0.727, "resolved_id": 4, "is_absorber": False},
            ]},
            {"id": "topLeft", "labels": [
                {"name": "Pasta", "prob": 0.25, "resolved_id": 9, "is_absorber": False},  # == T, excluded
            ]},
        ]
    }
    assert sorted(mod.derive_detections(rec, 0.25)) == [2, 4]
    assert sorted(mod.derive_detections(rec, 0.3)) == [2, 4]
    assert sorted(mod.derive_detections(rec, 0.7)) == [2, 4]  # 0.727 survives strict >
    assert sorted(mod.derive_detections(rec, 0.75)) == [2]
    assert mod.derive_detections(rec, 0.99) == []
