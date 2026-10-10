"""Manifest invariant tests: structure, roles, hashes, series groups."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
BENCH = HERE.parent

sys.path.insert(0, str(BENCH))
from build_manifest import TARGET_CONTROL, TARGET_MULTI, iou  # noqa: E402

MANIFEST = BENCH / "manifest.json"


@pytest.fixture(scope="module")
def manifest():
    assert MANIFEST.exists(), "manifest.json missing; run build_manifest.py first"
    return json.loads(MANIFEST.read_text())


class TestManifestCounts:
    def test_freeze_targets_met(self, manifest):
        assert manifest["counts"]["multi"] >= TARGET_MULTI >= 500
        assert manifest["counts"]["control"] >= TARGET_CONTROL >= 150

    def test_counts_match_image_records(self, manifest):
        multi = sum(1 for im in manifest["images"] if im["role"] == "multi")
        control = sum(1 for im in manifest["images"] if im["role"] == "control")
        assert manifest["counts"]["multi"] == multi
        assert manifest["counts"]["control"] == control
        assert manifest["counts"]["images"] == len(manifest["images"])

    def test_gt_box_count_matches(self, manifest):
        assert manifest["counts"]["gt_boxes"] == sum(
            len(im["boxes"]) for im in manifest["images"]
        )


class TestManifestInvariants:
    def test_role_consistency(self, manifest):
        for im in manifest["images"]:
            classes = {b["label_mid"] for b in im["boxes"]}
            if im["role"] == "multi":
                assert len(classes) >= 2, f"{im['image_id']}: multi with {len(classes)} classes"
            else:
                assert len(classes) == 1, f"{im['image_id']}: control with {len(classes)} classes"
                assert im["boxes"], f"{im['image_id']}: control with zero boxes"

    def test_series_groups_present_and_dhash_unique(self, manifest):
        hashes = [im["dhash"] for im in manifest["images"]]
        assert all(im["series_group"] for im in manifest["images"])
        assert len(hashes) == len(set(hashes)), "near-duplicate dhashes co-frozen"

    def test_license_hashes_present(self, manifest):
        for im in manifest["images"]:
            lic = im["license"]
            assert lic["name"] == "CC BY 2.0"
            want = hashlib.sha256(lic["record"].encode()).hexdigest()
            assert want == lic["record_sha256"], f"{im['image_id']}: license hash mismatch"

    def test_image_hashes_are_exact_sha256(self, manifest):
        for im in manifest["images"]:
            int(im["sha256"], 16)  # parses as 64-hex
            assert len(im["sha256"]) == 64

    def test_box_coordinate_ranges(self, manifest):
        for im in manifest["images"]:
            for b in im["boxes"]:
                assert 0 <= b["xmin"] < b["xmax"] <= 1
                assert 0 <= b["ymin"] < b["ymax"] <= 1

    def test_class_table(self, manifest):
        names = {c["name"] for c in manifest["classes"]}
        assert "Food" not in names  # Food root excluded from the class space
        assert len(names) == len(manifest["classes"]) >= 10

    def test_canonicalization_invariants(self, manifest):
        """No same-class GT pair with IoU > 0.98 survives in the manifest."""
        for im in manifest["images"]:
            boxes = [(b["label_mid"], (b["xmin"], b["ymin"], b["xmax"], b["ymax"])) for b in im["boxes"]]
            for i in range(len(boxes)):
                for j in range(i + 1, len(boxes)):
                    if boxes[i][0] == boxes[j][0]:
                        assert iou(boxes[i][1], boxes[j][1]) <= 0.98, im["image_id"]


class TestCheckManifestScript:
    @pytest.mark.integration
    def test_check_manifest_passes(self):
        """The committed checker exits 0 on the committed manifest; needs the
        local image pool (acquire.py)."""
        pool = Path("/home/user/work/bench/multiplate-images")
        if not pool.exists() or not any(pool.glob("*.jpg")):
            pytest.skip("image pool not acquired; run acquire.py first")
        proc = subprocess.run(
            [sys.executable, str(BENCH / "check_manifest.py")],
            capture_output=True,
            text=True,
            timeout=600,
        )
        assert proc.returncode == 0, f"check_manifest failed:\n{proc.stdout}\n{proc.stderr}"
        assert "manifest OK" in proc.stdout
