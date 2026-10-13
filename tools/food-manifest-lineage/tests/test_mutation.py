"""Mutation tests: the contract harness must catch violations.

Each test copies the fixtures directory into a temp dir, applies one
mutation, and runs check.py as a subprocess:

1. dropping an expectation → check must FAIL,
2. breaking a planted duplicate's hash → check must FAIL,
3. permuting record order inside a fixture → check must still PASS
   (order independence, verified through the real harness),
4. making a quiet control share a class/group label with a planted
   cluster → check must still PASS (group labels never join records),
5. planting a real duplicate on a quiet control → check must FAIL
   (the quiet-control mechanism catches new duplicates).
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
CHECK = TOOLS_DIR / "check.py"
FIXTURES = TOOLS_DIR / "fixtures"

PLANTED_DUP_HASH = "aa01010101010101010101010101010101010101010101010101010101010101"


def run_check(tmp_path: Path, mutate) -> subprocess.CompletedProcess:
    workdir = tmp_path / "fixtures"
    if not workdir.exists():
        shutil.copytree(FIXTURES, workdir)
    mutate(workdir)
    return subprocess.run(
        [sys.executable, str(CHECK), "--fixture", str(workdir / "contracts.json")],
        capture_output=True,
        text=True,
    )


def _rewrite_json(path: Path, fn) -> None:
    doc = json.loads(path.read_text(encoding="utf-8"))
    fn(doc)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def test_dropped_expectation_fails_check(tmp_path):
    def mutate(base: Path):
        contracts = base / "contracts.json"

        def bump(doc):
            doc["expectations"]["exact_duplicate_clusters"] = 999

        _rewrite_json(contracts, bump)

    result = run_check(tmp_path, mutate)
    assert result.returncode != 0
    assert "exact_duplicate_clusters" in result.stdout


def test_broken_duplicate_hash_fails_check(tmp_path):
    def mutate(base: Path):
        dish_b = base / "data" / "dish_manifest_b.json"

        def break_dup(doc):
            # second image is the renamed partner of the first
            doc["images"][1]["sha256"] = "bb" * 32

        _rewrite_json(dish_b, break_dup)

    result = run_check(tmp_path, mutate)
    assert result.returncode != 0


def test_record_order_permutation_still_passes(tmp_path):
    def mutate(base: Path):
        usda_catalog = base / "data" / "usda_catalog.json"

        def reverse(doc):
            # fdc-derived item ids are content-based, so reversing rows must
            # not change any count (order independence at the harness level)
            doc["records"] = list(reversed(doc["records"]))

        _rewrite_json(usda_catalog, reverse)

    result = run_check(tmp_path, mutate)
    assert result.returncode == 0, result.stdout + result.stderr


def test_group_label_similarity_stays_quiet(tmp_path):
    def mutate(base: Path):
        dish_a = base / "data" / "dish_manifest_a.json"

        def share_class(doc):
            # quiet control fx-dish-a:img-000002 (beta_tart) adopts the
            # planted pair's class label; a scanner that joined on group
            # labels would flag this control and fail the check
            doc["images"][2]["class"] = "alpha_pie"

        _rewrite_json(dish_a, share_class)

    result = run_check(tmp_path, mutate)
    assert result.returncode == 0, result.stdout + result.stderr


def test_planted_duplicate_on_quiet_control_is_caught(tmp_path):
    def mutate(base: Path):
        dish_a = base / "data" / "dish_manifest_a.json"

        def plant(doc):
            # give quiet control img-000001 (path 2002.jpg) the planted
            # duplicate's bytes: the hash join must flag the control
            doc["images"][1]["sha256"] = PLANTED_DUP_HASH

        _rewrite_json(dish_a, plant)

    result = run_check(tmp_path, mutate)
    assert result.returncode != 0
    assert "false-positive controls flagged" in result.stdout


def test_planted_source_reuse_on_quiet_controls_is_caught(tmp_path):
    def mutate(base: Path):
        dish_a = base / "data" / "dish_manifest_a.json"

        def plant(doc):
            # point quiet control img-000001 at quiet control
            # fx-dish-b:img-000002's path: the origin-scoped source join
            # must flag both controls
            doc["images"][1]["path"] = "fx_images/gamma_soup/4004.jpg"

        _rewrite_json(dish_a, plant)

    result = run_check(tmp_path, mutate)
    assert result.returncode != 0
    assert "false-positive controls flagged" in result.stdout
