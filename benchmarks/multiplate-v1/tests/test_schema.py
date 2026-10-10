"""Schema and production-contract tests for multiplate-v1 results.

Validates every committed predictions_*.jsonl row against
schema/region-result.schema.json, and checks schema/production name
compatibility against apps/ios/Capability/Core/Recognition/ScanContracts.swift
read-only: the Swift file is only ever read, never written or compiled here,
and the production types it defines stay untouched.
"""

import json
import re
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parent.parent
SCHEMA_PATH = BENCH / "schema" / "region-result.schema.json"

# Pinned repo-relative location of the production scan contracts.
SCAN_CONTRACTS_REPO_PATH = Path("apps/ios/Capability/Core/Recognition/ScanContracts.swift")


def _load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def _validate_row(row, schema, path="$", root=None):
    """Minimal recursive JSON Schema validator for the constructs used above."""
    root = root if root is not None else schema
    if "$ref" in schema:
        ref = schema["$ref"]
        assert ref.startswith("#/"), f"{path}: only local refs supported, got {ref}"
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        _validate_row(row, target, path, root)
        return
    if "enum" in schema:
        assert row in schema["enum"], f"{path}: {row!r} not in {schema['enum']}"
        return
    t = schema.get("type")
    if t == "object":
        assert isinstance(row, dict), f"{path}: expected object, got {type(row).__name__}"
        for k in schema.get("required", []):
            assert k in row, f"{path}: missing required key {k!r}"
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extra = set(row) - set(props)
            assert not extra, f"{path}: unexpected keys {sorted(extra)}"
        for k, v in row.items():
            if k in props:
                _validate_row(v, props[k], f"{path}.{k}", root)
    elif t == "array":
        assert isinstance(row, list), f"{path}: expected array"
        if "minItems" in schema:
            assert len(row) >= schema["minItems"], f"{path}: fewer than {schema['minItems']} items"
        if "maxItems" in schema:
            assert len(row) <= schema["maxItems"], f"{path}: more than {schema['maxItems']} items"
        for i, item in enumerate(row):
            _validate_row(item, schema["items"], f"{path}[{i}]", root)
    elif t == "string":
        assert isinstance(row, str), f"{path}: expected string"
        if "minLength" in schema:
            assert len(row) >= schema["minLength"], f"{path}: too short"
    elif t == "number":
        assert isinstance(row, (int, float)) and not isinstance(row, bool), f"{path}: expected number"
        if "minimum" in schema:
            assert row >= schema["minimum"], f"{path}: below minimum"
        if "maximum" in schema:
            assert row <= schema["maximum"], f"{path}: above maximum"
    else:
        raise AssertionError(f"{path}: unhandled schema type {t!r}")


def _committed_rows():
    rows = []
    for p in sorted((BENCH / "results").glob("predictions_*.jsonl")):
        for lineno, line in enumerate(p.read_text().splitlines(), 1):
            if line.strip():
                rows.append((p.name, lineno, json.loads(line)))
    assert rows, "no committed prediction rows found — run.py results missing?"
    return rows


def test_all_committed_rows_match_schema():
    schema = _load_schema()
    rows = _committed_rows()
    # 668 images x 3 arms is the frozen slice; every row must validate.
    assert len(rows) == 668 * 3, f"expected 2004 rows, found {len(rows)}"
    for fname, lineno, row in rows:
        _validate_row(row, schema, f"{fname}:{lineno}")


def test_row_arms_are_separated_and_complete():
    """The pixels-only/oracle separation holds: each arm file covers exactly
    668 unique images, the oracle arm is the only one carrying gt_label +
    gt_box, and the detector arm is the only one carrying coco_label."""
    per_arm: dict[str, set] = {}
    for fname, _, row in _committed_rows():
        arm = fname.removeprefix("predictions_").removesuffix(".jsonl")
        per_arm.setdefault(arm, set()).add(row["image_id"])
    assert set(per_arm) == {"detector", "proposals", "oracle-crops"}
    assert all(len(ids) == 668 for ids in per_arm.values())
    for fname, _, row in _committed_rows():
        arm = fname.removeprefix("predictions_").removesuffix(".jsonl")
        if arm == "oracle-crops":
            assert all("gt_label" in d and "gt_box" in d for d in row["detections"])
        else:
            assert all("gt_label" not in d and "gt_box" not in d for d in row["detections"])
        # detector rows carry the raw COCO label; the other arms do not
        if arm == "detector":
            assert all("coco_label" in d for d in row["detections"])
        else:
            assert all("coco_label" not in d for d in row["detections"])


# --- read-only ScanContracts compatibility -----------------------------------

def _scan_contracts_source() -> str:
    repo_root = BENCH.parents[1]
    path = repo_root / SCAN_CONTRACTS_REPO_PATH
    assert path.exists(), (
        f"production ScanContracts not found at {SCAN_CONTRACTS_REPO_PATH} "
        "(pinned repo-relative path); update SCAN_CONTRACTS_REPO_PATH and "
        "re-check this schema's compatibility claims. This test only reads "
        "the file — production types stay untouched."
    )
    return path.read_text()


def _swift_enum_cases(source: str, enum_name: str) -> list[str]:
    m = re.search(
        rf"enum {enum_name}[^{{]*\{{(.*?)\}}", source, re.DOTALL
    )
    assert m, f"enum {enum_name} not found in ScanContracts.swift"
    return re.findall(r"case\s+(\w+)", m.group(1))


def test_schema_provenance_enum_matches_scancontracts():
    """The schema's optional provenance field must use exactly the production
    ScanProvenance raw values, so benchmark rows stay name-compatible with
    the app's Codable contracts."""
    source = _scan_contracts_source()
    cases = _swift_enum_cases(source, "ScanProvenance")
    schema_enum = _load_schema()["properties"]["provenance"]["enum"]
    assert schema_enum == cases, (
        f"schema provenance {schema_enum} != ScanProvenance cases {cases}"
    )


def test_scan_input_source_includes_benchmark():
    """Production ScanInputSource must keep the `benchmark` case: the
    benchmark feed is a first-class input source in the app contracts."""
    source = _scan_contracts_source()
    assert "benchmark" in _swift_enum_cases(source, "ScanInputSource")
