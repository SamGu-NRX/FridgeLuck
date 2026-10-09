"""Invariant tests binding the canonical catalog to the committed reference.

These run against the real committed files (extract + audit) and are the
sync guard: they fail if the canonical catalog, the reference extracts, and
the audit evidence drift apart.
"""

from __future__ import annotations

import csv
import hashlib

import orjson
import pytest

from usda_core.config import AUDIT_DIR, CANONICAL_JSON, REFERENCE_DIR
from usda_core.io import load_canonical
from usda_core.reference_audit import audit_catalog

REFERENCE_EXTRACT = REFERENCE_DIR / "fdc_reference_extracts.json"
MANIFEST = REFERENCE_DIR / "MANIFEST.json"
AUDIT_DIR_LATEST = AUDIT_DIR / "reference_audit"
DISCREPANCIES = AUDIT_DIR_LATEST / "discrepancies.csv"

requires_reference = pytest.mark.skipif(
    not REFERENCE_EXTRACT.exists() or not MANIFEST.exists(),
    reason="reference extract not yet generated",
)


@requires_reference
def test_extract_bytes_match_manifest_hash():
    manifest = orjson.loads(MANIFEST.read_bytes())
    digest = hashlib.sha256(REFERENCE_EXTRACT.read_bytes().rstrip(b"\n")).hexdigest()
    assert digest == manifest["extract_sha256"], (
        "committed fdc_reference_extracts.json does not match MANIFEST.json — "
        "regenerate with `usda extract-reference` or restore the committed bytes"
    )


@requires_reference
def test_every_canonical_fdc_id_is_evidenced_or_listed():
    extract = orjson.loads(REFERENCE_EXTRACT.read_bytes())
    catalog = load_canonical(CANONICAL_JSON)
    extract_ids = {r["fdc_id"] for r in extract["records"]}
    missing = set(extract["missing_fdc_ids"])
    for row in catalog.records:
        assert row.fdc_id in extract_ids or row.fdc_id in missing, (
            f"fdc_id {row.fdc_id} is neither in the extract nor in missing_fdc_ids"
        )


@requires_reference
def test_discrepancy_table_covers_every_record():
    catalog = load_canonical(CANONICAL_JSON)
    with DISCREPANCIES.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert {int(r["fdc_id"]) for r in rows} == {r.fdc_id for r in catalog.records}


@requires_reference
def test_post_correction_audit_has_no_discrepancies():
    """After corrections are applied, re-running the audit must be clean."""

    audit_report = AUDIT_DIR_LATEST / "audit.json"
    if not audit_report.exists():
        pytest.skip("audit not yet generated")
    report = orjson.loads(audit_report.read_bytes())
    drifting = [
        r["fdc_id"]
        for r in report["records"]
        if any(f["status"] == "discrepancy_correctable" for f in r["findings"])
    ]
    assert not drifting, f"unapplied source-supported corrections remain for: {drifting[:10]}"


@requires_reference
def test_reaudit_of_committed_state_is_deterministic():
    """Re-running the audit engine over committed inputs must reproduce the
    same verdicts as the committed audit (same inputs -> same verdicts)."""

    audit_report = AUDIT_DIR_LATEST / "audit.json"
    if not audit_report.exists():
        pytest.skip("audit not yet generated")
    extract = orjson.loads(REFERENCE_EXTRACT.read_bytes())
    catalog = load_canonical(CANONICAL_JSON)
    fresh = audit_catalog([r.model_dump(mode="json") for r in catalog.records], extract)
    assert fresh.verdict_counts == orjson.loads(audit_report.read_bytes())["verdict_counts"]
