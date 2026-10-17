"""Apple-observation replay adapter tests.

All fixtures here are SYNTHETIC SCHEMA FIXTURES: they exercise the adapter's
conversion, gating, dedup, and validation logic. They are not Apple
observations and must never be presented as such — the adapter exists so a
genuine device export can be scored; none exists in this repository.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

EXPERIMENT = Path(__file__).resolve().parent.parent
ADAPTER = EXPERIMENT / "runner" / "apple_replay.py"


def _module():
    spec = importlib.util.spec_from_file_location("apple_replay", ADAPTER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _export() -> dict:
    return {
        "source": "apple_device",
        "classifier": {"name": "VNClassifyImageRequest", "revision": "fixture"},
        "images": [
            {
                "image_id": 7,
                "crops": [
                    {"id": "full", "labels": [
                        {"name": "Rice", "prob": 0.55},
                        {"name": "a prepared dish on a plate", "prob": 0.90},
                    ]},
                    {"id": "center", "labels": [
                        {"name": "Rice", "prob": 0.97},   # best across crops wins
                        {"name": "Carrot", "prob": 0.042},  # below threshold -> not kept
                        {"name": "mystery object", "prob": 0.88},  # unresolvable, never detected
                        {"name": "Salt", "prob": 0.0005},  # at/below record floor -> not recorded
                    ]},
                ],
            },
            {"image_id": 3, "crops": [{"id": "full", "labels": [{"name": "Carrot", "prob": 0.80}]}]},
        ],
    }


def _run(tmp_path: Path, export: dict | None = None, threshold: float = 0.1, floor: float = 0.001):
    export = export if export is not None else _export()
    export_path = tmp_path / "export.json"
    export_path.write_text(json.dumps(export))
    out = tmp_path / "apple_replay.jsonl.gz"
    proc = subprocess.run(
        [sys.executable, str(ADAPTER), "--export", str(export_path), "--split", "validation",
         "--threshold", str(threshold), "--record-floor", str(floor), "--out", str(out)],
        capture_output=True, text=True,
    )
    return proc, out, export_path


def test_conversion_gates_resolution_and_dedup(tmp_path):
    proc, out, _ = _run(tmp_path)
    assert proc.returncode == 0, proc.stderr
    rows = {r["image_id"]: r for r in (json.loads(l) for l in __import__("gzip").open(out, "rt"))}

    img7 = rows[7]
    # cross-crop dedup: best Rice confidence across crops
    det = {d["ingredient_id"]: d for d in img7["detections"]}
    rice_id = next(k for k, v in det.items() if v["original_label"] == "Rice")
    assert det[rice_id]["confidence"] == pytest.approx(0.97)
    assert det[rice_id]["provenance"] == "curated"
    # sub-threshold resolved label (Carrot 0.42) not a detection; the
    # unresolvable "mystery object" is recorded but never detected
    assert len(img7["detections"]) == 1
    labels_by_name = {l["name"]: l for c in img7["crops"] for l in c["labels"]}
    assert "Carrot" in labels_by_name and "mystery object" in labels_by_name
    assert "Salt" not in labels_by_name  # sub-floor labels are not recorded
    assert labels_by_name["mystery object"]["resolved_id"] is None
    # absorber marked, never detected
    assert labels_by_name["a prepared dish on a plate"]["is_absorber"] is True
    assert all(d["original_label"] != "a prepared dish on a plate" for d in img7["detections"])
    # rows sorted by image_id
    assert list(rows) == [3, 7]


def test_meta_marks_device_source(tmp_path):
    proc, out, _ = _run(tmp_path)
    assert proc.returncode == 0, proc.stderr
    meta = json.loads((tmp_path / "apple_replay.meta.json").read_text())
    assert meta["source"] == "apple_device"
    assert meta["classifier"]["name"] == "VNClassifyImageRequest"
    assert meta["images_observed"] == 2
    assert meta["detections"] == 2
    assert meta["failures"] == 0
    assert "no labels, probabilities, or detections" in meta["note"]
    assert (tmp_path / "apple_replay.failures.jsonl").read_text() == ""


def test_schema_violations_abort(tmp_path):
    mod = _module()
    base = _export()
    bad_variants = [
        {**base, "source": "somewhere_else"},
        {**base, "images": [{"image_id": 1, "crops": [{"id": "full", "labels": [
            {"name": "Rice", "prob": 1.5}]}]}]},
        {**base, "images": [{"image_id": 1, "crops": [{"id": "full", "labels": [
            {"name": "", "prob": 0.5}]}]}]},
        {**base, "images": [{"image_id": "x", "crops": []}]},
        {**base, "images": [{"image_id": 1, "crops": []}, {"image_id": 1, "crops": []}]},
        {**base, "images": "nope"},
    ]
    for variant in bad_variants:
        proc, _, _ = _run(tmp_path, variant)
        assert proc.returncode != 0, f"bad export accepted: {json.dumps(variant)[:80]}"


def test_empty_export_makes_empty_file(tmp_path):
    proc, out, _ = _run(tmp_path, {"source": "apple_device", "images": []})
    assert proc.returncode == 0, proc.stderr
    assert __import__("gzip").open(out, "rt").read() == ""
    meta = json.loads((tmp_path / "apple_replay.meta.json").read_text())
    assert meta["images_observed"] == 0 and meta["detections"] == 0


def test_load_export_rejects_non_json(tmp_path):
    mod = _module()
    bad = tmp_path / "bad.json"
    bad.write_text("not json {")
    with pytest.raises(mod.ExportError):
        mod._load_export(bad)
