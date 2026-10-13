"""Regeneration-proof tests: table from stored outputs, labeled differences."""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
REGEN = "tools/experiment-capsules/regen.py"
RESULTS = REPO_ROOT / "tools/experiment-capsules/results"
sys.path.insert(0, str(REPO_ROOT / "tools/experiment-capsules"))

from regen import catalog_table, compare_tables, render_tsv  # noqa: E402


def regen(capsules: Path, out: Path, repo_root: Path = REPO_ROOT):
    return subprocess.run(
        [sys.executable, REGEN, "--capsules", str(capsules), "--out", str(out),
         "--repo-root", str(repo_root)],
        cwd=REPO_ROOT, capture_output=True, text=True, timeout=120,
    )


def synthetic_rows():
    return [
        {"category": "fruit", "ingredients": 149, "macro_complete": 149,
         "macro_complete_share": 1.0},
        {"category": "TOTAL", "ingredients": 149, "macro_complete": 149,
         "macro_complete_share": 1.0},
    ]


def test_regenerates_table_from_committed_capsules(tmp_path):
    out = tmp_path / "regen-proof"
    result = regen(RESULTS, out)
    assert result.returncode == 0, result.stdout + result.stderr
    tsv = (out / "table-from-capsule.tsv").read_text(encoding="utf-8")
    total = [line for line in tsv.splitlines() if line.startswith("TOTAL")][0]
    fields = total.split("\t")
    assert fields[1] == "800", f"catalog record count: {total}"
    assert "NOT identical provenance" in (out / "regen-proof.md").read_text(encoding="utf-8")


def test_regenerated_table_is_digest_stable(tmp_path):
    out_a, out_b = tmp_path / "a", tmp_path / "b"
    assert regen(RESULTS, out_a).returncode == 0
    assert regen(RESULTS, out_b).returncode == 0
    a = (out_a / "table-from-capsule.tsv").read_bytes()
    b = (out_b / "table-from-capsule.tsv").read_bytes()
    assert a == b, "regenerated table must be byte-identical across runs"


def test_regenerated_table_has_no_volatile_tokens(tmp_path):
    from volatile_scan import scan_text as scan_volatile_content

    out = tmp_path / "regen-proof"
    assert regen(RESULTS, out).returncode == 0
    for artifact in ("table-from-capsule.tsv", "regen-proof.md"):
        content = (out / artifact).read_text(encoding="utf-8")
        assert scan_volatile_content(content) == [], f"volatile tokens in {artifact}"


def test_regenerated_table_excludes_volatile_origin_field(tmp_path):
    # The origin artifact's generated_at_utc must not reach the table.
    out = tmp_path / "regen-proof"
    assert regen(RESULTS, out).returncode == 0
    tsv = (out / "table-from-capsule.tsv").read_text(encoding="utf-8")
    assert "generated_at" not in tsv


def test_compare_tables_labels_differences_explicitly():
    capsule_rows = synthetic_rows()
    origin_rows = [dict(capsule_rows[0], ingredients=150), capsule_rows[1]]
    labels = compare_tables(capsule_rows, origin_rows)
    assert any("DIFFERENCE [fruit] ingredients: capsule=149 vs origin=150" in x for x in labels)
    assert not any(x.startswith("AGREEMENT") for x in labels)


def test_compare_tables_labels_agreement_as_numerical_only():
    labels = compare_tables(synthetic_rows(), synthetic_rows())
    assert len(labels) == 1
    assert labels[0].startswith("AGREEMENT (numerical)")
    assert "NOT identical provenance" in labels[0]


def test_regen_refuses_tampered_capsule(tmp_path):
    capsules = tmp_path / "capsules"
    shutil.copytree(RESULTS, capsules)
    target = next(capsules.glob("usda-curation-catalog/outputs/*.json"))
    catalog = target.read_text(encoding="utf-8")
    target.write_text(catalog.replace('"fdc_id":', '"fdc_id":', 1) + " ", encoding="utf-8")
    result = regen(capsules, tmp_path / "out")
    assert result.returncode == 1, result.stdout
    assert "refusing to build a proof" in result.stderr


def test_regen_report_states_coverage_gap_policy(tmp_path):
    out = tmp_path / "regen-proof"
    assert regen(RESULTS, out).returncode == 0
    report = (out / "regen-proof.md").read_text(encoding="utf-8")
    assert "coverage gap" in report
    assert "never" in report  # "regen never guesses them closed"


def test_catalog_table_counts_macros_strictly():
    records = [
        {"category_label": "fruit", "macros": {f: 1 for f in (
            "calories", "carbs_g", "fat_g", "fiber_g", "protein_g", "sodium_g", "sugar_g")}},
        {"category_label": "fruit", "macros": {"calories": 1}},  # incomplete
        {"category_label": "vegetable", "macros": None},
    ]
    rows = catalog_table(records)
    by_category = {row["category"]: row for row in rows}
    assert by_category["fruit"]["ingredients"] == 2
    assert by_category["fruit"]["macro_complete"] == 1
    assert by_category["vegetable"]["macro_complete"] == 0
    assert by_category["TOTAL"]["ingredients"] == 3


def test_render_tsv_is_fixed_format():
    tsv = render_tsv(synthetic_rows())
    lines = tsv.strip().split("\n")
    assert lines[0] == "category\tingredients\tmacro_complete\tmacro_complete_share"
    assert lines[1] == "fruit\t149\t149\t1.0000"
    assert lines[-1].startswith("TOTAL\t")
