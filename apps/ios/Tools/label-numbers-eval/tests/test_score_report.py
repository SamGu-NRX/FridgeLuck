"""Tests for score_report.py: capability separation, protocol freeze, controls."""
from __future__ import annotations

import json
from pathlib import Path

from score_report import build_report, canonical_json, evaluate_arm
from strict_baseline import extract, parse_number

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


def mini_corpus() -> list[dict]:
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


def production_rows(keyword_positive: bool = True) -> list[dict]:
    return [
        {
            "record_id": "T-0001",
            "family": "us_dual_column",
            "variant_kind": "clean",
            "keyword_positive": keyword_positive,
            "parsed": True,
            "calories_per_serving": 120.0,
            "serving_size": "1 cup (30 g) Amount per serving",
            "servings_per_container": None,
        },
        {
            "record_id": "T-0002",
            "family": "us_dual_column",
            "variant_kind": "corrupted",
            "keyword_positive": keyword_positive,
            "parsed": False,
            "calories_per_serving": None,
            "serving_size": None,
            "servings_per_container": None,
        },
    ]


def strict_rows() -> list[dict]:
    return [
        {
            "record_id": "T-0001",
            "family": "us_dual_column",
            "variant_kind": "clean",
            "keyword_positive": True,
            "parsed": True,
            "calories_per_serving": 120.0,
            "serving_size": "1 cup (30 g)",
            "servings_per_container": 8.0,
            "fields": {"energy_kcal@per_serving": 120.0, "servings_per_container": 8.0, "serving_size": "1 cup (30 g)"},
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
            "fields": {},
        },
    ]


def run_build(tmp_path: Path, corpus=None, production=None, strict=None) -> dict:
    corpus = corpus if corpus is not None else mini_corpus()
    production = production if production is not None else production_rows()
    strict = strict if strict is not None else strict_rows()
    return build_report(
        write_jsonl(tmp_path / "corpus.jsonl", corpus),
        {
            "production": write_jsonl(tmp_path / "replay.jsonl", production),
            "strict_baseline": write_jsonl(tmp_path / "strict.jsonl", strict),
        },
    )


def test_unsupported_field_marked_unavailable_for_production(tmp_path):
    report = run_build(tmp_path)
    fat = report["arms"]["production"]["by_field"]["fat_g"]["g|per_serving"]
    assert fat["unavailable"] == 1
    assert fat["match"] == 0 and fat["abstention"] == 0


def test_production_whitelist_not_imposed_on_strict(tmp_path):
    report = run_build(tmp_path)
    strict = report["arms"]["strict_baseline"]
    assert strict["capability_bases"]["fat_g"] == ["per_100g", "per_100ml", "per_portion"]
    fat = strict["by_field"]["fat_g"]["g|per_serving"]
    assert fat["unavailable"] == 0


def test_unsupported_basis_marked_unavailable_basis(tmp_path):
    report = run_build(tmp_path)
    pkg = report["arms"]["production"]["by_field"]["energy_kcal"]["kcal|per_package"]
    assert pkg["unavailable_basis"] == 1


def test_gate_rejected_records_excluded_from_production_totals(tmp_path):
    report = run_build(tmp_path, production=production_rows(keyword_positive=False))
    prod = report["arms"]["production"]
    assert prod["gate_rejected_records"] == 2
    assert prod["keyword_admitted_records"] == 0
    assert prod["totals"]["total"] == 0
    assert prod["by_field"] == {}
    assert prod["gate_rejected_formats"] == ["us_dual_column|clean", "us_dual_column|corrupted"]
    assert report["arms"]["strict_baseline"]["gate_rejected_records"] == 0


def test_gate_rejected_records_not_called_untouched(tmp_path):
    report = run_build(tmp_path)
    for arm in report["arms"].values():
        assert "untouched" not in arm["totals"]


def test_report_discloses_protocol_and_prior_exposure(tmp_path):
    report = run_build(tmp_path)
    protocol = report["protocol"]
    assert protocol["frozen_families"]["development"] == ["us_dual_column", "ca_bilingual"]
    assert protocol["frozen_families"]["heldout"] == ["eu_per100g", "eu_per_portion"]
    assert "NOT a clean held-out split" in protocol["prior_exposure"]
    assert "not scored as 'untouched'" in protocol["gate_rejected_note"]


def test_metrics_split_by_frozen_families(tmp_path):
    report = run_build(tmp_path)
    prod = report["arms"]["production"]
    dev_total = prod["by_split"]["development"]["totals"]["total"]
    held_total = prod["by_split"]["heldout"]["totals"]["total"]
    assert dev_total + held_total == prod["totals"]["total"]
    assert held_total == 0  # both fixture records are US


def test_unit_error_control(tmp_path):
    prod = production_rows()
    prod[0]["calories_per_serving"] = 120.0 * 4.184  # the kJ-equivalent number
    report = run_build(tmp_path, production=prod)
    assert report["arms"]["production"]["controls"]["unit_errors"] == 1


def test_false_abstention_control_counts_companion_matches(tmp_path):
    report = run_build(tmp_path)
    prod = report["arms"]["production"]
    # production abstains on servings; strict matches it
    assert prod["controls"]["false_abstentions"] == 1
    assert report["arms"]["strict_baseline"]["controls"]["false_abstentions"] == 0


def test_basis_error_control(tmp_path):
    prod = production_rows()
    prod[0]["calories_per_serving"] = 960.0  # the per_package truth value
    report = run_build(tmp_path, production=prod)
    assert report["arms"]["production"]["controls"]["basis_errors"] == 1


def test_strict_extracts_eu_table_with_comma_decimals():
    result = extract(
        [
            "Typical values          per 100 g      per portion (40 g)",
            "Energy                  1728 kJ      690 kJ",
            "                        413 kcal      165 kcal",
            "Fat                     25,9 g      10,4 g",
            "Salt                     1,7 g      0,7 g",
        ]
    )
    assert result["fields"]["energy_kj@per_100g"] == 1728.0
    assert result["fields"]["energy_kj@per_portion"] == 690.0
    assert result["fields"]["energy_kcal@per_100g"] == 413.0
    assert result["fields"]["energy_kcal@per_portion"] == 165.0
    assert result["fields"]["fat_g@per_100g"] == 25.9
    assert result["fields"]["fat_g@per_portion"] == 10.4
    assert result["fields"]["salt_g@per_portion"] == 0.7


def test_strict_extracts_eu_single_column_and_sodium():
    result = extract(
        [
            "Typical values per 100 ml",
            "Energy 2548 kJ / 609 kcal",
            "Fat 7.4 g",
            "Sodium / Sodium 382 mg  17 %",
            "Sodium 6,096 mg  265%",
        ]
    )
    assert result["fields"]["energy_kj@per_100ml"] == 2548.0
    assert result["fields"]["energy_kcal@per_100ml"] == 609.0
    assert result["fields"]["fat_g@per_100ml"] == 7.4
    assert result["fields"]["sodium_mg@per_serving"] == 382.0


def test_strict_never_mismatches_on_committed_corpus():
    preds = [json.loads(l) for l in open(TOOL_DIR / "reports" / "strict_predictions.jsonl", encoding="utf-8")]
    corpus = [json.loads(l) for l in open(TOOL_DIR / "corpus" / "labels.jsonl", encoding="utf-8")]
    evaluated = evaluate_arm("strict_baseline", corpus, preds)
    statuses = {r["status"] for r in evaluated["rows"]}
    assert "mismatch" not in statuses


def test_parse_number_semantics():
    assert parse_number("25,9") == 25.9
    assert parse_number("6,096") == 6096.0
    assert parse_number("2 548") == 2548.0
    assert parse_number("41.6") == 41.6


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


def test_committed_protocol_and_gate_disclosure():
    report = json.loads((TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8"))
    assert report["protocol"]["frozen_families"]["heldout"] == ["eu_per100g", "eu_per_portion"]
    prod = report["arms"]["production"]
    assert prod["gate_rejected_records"] == 243
    assert prod["gate_rejected_formats"] == [
        "ca_bilingual|corrupted",
        "eu_per100g|clean",
        "eu_per100g|corrupted",
        "eu_per_portion|clean",
        "eu_per_portion|corrupted",
    ]
    assert "untouched" not in prod["totals"]
    assert report["unsupported_production_fields"] == [
        "carbohydrate_g",
        "energy_kj",
        "fat_g",
        "protein_g",
        "salt_g",
        "sodium_mg",
    ]


def test_committed_totals_cover_every_admitted_probe():
    report = json.loads((TOOL_DIR / "reports" / "report.json").read_text(encoding="utf-8"))
    statuses = ("match", "mismatch", "abstention", "unavailable_basis", "unavailable", "unobservable")
    for arm in report["arms"].values():
        assert sum(arm["totals"][s] for s in statuses) == arm["totals"]["total"]
        for split in arm["by_split"].values():
            assert sum(split["totals"][s] for s in statuses) == split["totals"]["total"]
    assert report["arms"]["strict_baseline"]["totals"]["total"] == 5590
    assert report["arms"]["production"]["totals"]["total"] == 2733
