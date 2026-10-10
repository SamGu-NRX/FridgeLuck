"""Tests for score_report.py: status accounting on synthetic fixtures."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from score_report import build_report, canonical_json, score_entry

TOOL_DIR = Path(__file__).resolve().parent.parent


def write_jsonl(path: Path, rows: list[dict]) -> Path:
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    return path


def field_entry(value, unit=None, basis=None, observable=True, reason=None, evidence=0):
    return {
        "value": value,
        "unit": unit,
        "basis": basis,
        "observable": observable,
        "evidence_line": evidence if observable else None,
        "unobservability_reason": reason,
    }


def mini_corpus(tmp_path: Path) -> list[dict]:
    return [
        {
            "record_id": "T-0001",
            "group_id": "TG-0001",
            "variant": "clean",
            "family": "us_dual_column",
            "variant_kind": "clean",
            "lines": ["Calories 120", "Serving size 1 cup (30 g)", "About 8 servings per container"],
            "fields": {
                "energy_kcal@per_serving": field_entry("120", "kcal", "per_serving"),
                "energy_kcal@per_package": field_entry("960", "kcal", "per_package"),
                "fat_g@per_serving": field_entry("3.5", "g", "per_serving"),
                "serving_size": field_entry("1 cup (30 g)"),
                "servings_per_container": field_entry("8", "count"),
            },
        },
        {
            "record_id": "T-0002",
            "group_id": "TG-0001",
            "variant": "corrupted",
            "family": "us_dual_column",
            "variant_kind": "corrupted",
            "lines": ["Calories 1x0"],
            "fields": {
                "energy_kcal@per_serving": field_entry(None, "kcal", "per_serving", observable=False, reason="value_not_in_text"),
            },
        },
    ]


def mini_predictions(tmp_path: Path) -> Path:
    return write_jsonl(
        tmp_path / "predictions.jsonl",
        [
            {
                "record_id": "T-0001",
                "family": "us_dual_column",
                "variant_kind": "clean",
                "keyword_positive": True,
                "parsed": True,
                "calories_per_serving": 120.0,
                "serving_size": "1 cup (30 g) Amount per serving",
                "servings_per_container": None,
            },
            {
                "record_id": "T-0002",
                "family": "us_dual_column",
                "variant_kind": "corrupted",
                "keyword_positive": True,
                "parsed": False,
                "calories_per_serving": None,
                "serving_size": None,
                "servings_per_container": None,
            },
        ],
    )


def test_unsupported_field_marked_unavailable(tmp_path):
    corpus = mini_corpus(tmp_path)
    predictions = mini_predictions(tmp_path)
    report = build_report(
        write_jsonl(tmp_path / "corpus.jsonl", corpus), {"production": predictions}
    )
    fat = report["arms"]["production"]["by_field"]["fat_g"]["g|per_serving"]
    assert fat["unavailable"] == 1
    assert fat["match"] == 0 and fat["abstention"] == 0


def test_unsupported_basis_marked_unavailable_basis(tmp_path):
    corpus = mini_corpus(tmp_path)
    predictions = mini_predictions(tmp_path)
    report = build_report(
        write_jsonl(tmp_path / "corpus.jsonl", corpus), {"production": predictions}
    )
    pkg = report["arms"]["production"]["by_field"]["energy_kcal"]["kcal|per_package"]
    assert pkg["unavailable_basis"] == 1


def test_serving_size_overrun_is_mismatch_and_servings_null_is_abstention(tmp_path):
    corpus = mini_corpus(tmp_path)
    predictions = mini_predictions(tmp_path)
    report = build_report(
        write_jsonl(tmp_path / "corpus.jsonl", corpus), {"production": predictions}
    )
    serving = report["arms"]["production"]["by_field"]["serving_size"]["none|none"]
    assert serving["mismatch"] == 1
    servings = report["arms"]["production"]["by_field"]["servings_per_container"]["count|none"]
    assert servings["abstention"] == 1


def test_unobservable_precedes_everything(tmp_path):
    entry = field_entry(None, observable=False, reason="field_name_missing")
    prediction = {"keyword_positive": False, "calories_per_serving": None}
    assert score_entry("production", "fat_g", "per_serving", entry, prediction) == "unobservable"


def test_untouched_only_for_production_keyword_gate(tmp_path):
    entry = field_entry("100", "kcal", "per_serving")
    assert (
        score_entry("production", "energy_kcal", "per_serving", entry, {"keyword_positive": False, "calories_per_serving": 100.0})
        == "untouched"
    )
    assert (
        score_entry("strict_baseline", "energy_kcal", "per_serving", entry, {"keyword_positive": True, "calories_per_serving": 100.0})
        == "match"
    )


def test_whole_record_abstention_counts_as_abstention_per_field(tmp_path):
    entry = field_entry("1 cup (30 g)")
    prediction = {"keyword_positive": True, "parsed": False, "serving_size": None}
    assert score_entry("production", "serving_size", None, entry, prediction) == "abstention"


def test_committed_report_matches_recomputation():
    report = build_report(
        TOOL_DIR / "corpus" / "labels.jsonl",
        {
            "production": TOOL_DIR / "reports" / "replay_predictions.jsonl",
            "strict_baseline": TOOL_DIR / "reports" / "strict_predictions.jsonl",
        },
    )
    committed = (TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8")
    assert canonical_json(report) == committed


def test_committed_untouched_formats_are_the_eu_families():
    report = json.loads((TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8"))
    assert report["untouched_formats_production"] == [
        "eu_per100g|clean",
        "eu_per100g|corrupted",
        "eu_per_portion|clean",
        "eu_per_portion|corrupted",
    ]


def test_committed_unsupported_fields_listed():
    report = json.loads((TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8"))
    assert report["unsupported_production_fields"] == [
        "carbohydrate_g",
        "energy_kj",
        "fat_g",
        "protein_g",
        "salt_g",
        "sodium_mg",
    ]


def test_committed_totals_cover_every_probe():
    report = json.loads((TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8"))
    for arm in report["arms"].values():
        assert arm["totals"]["total"] == 5590
        assert sum(arm["totals"][s] for s in ("match", "mismatch", "abstention", "untouched", "unavailable_basis", "unavailable", "unobservable")) == 5590
