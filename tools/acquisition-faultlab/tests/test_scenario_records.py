"""scenarios.json must be internally consistent: unique ids, digests that
re-derive from (seed, size), and committed scenario counts that match."""

import json
import re
from pathlib import Path

import pytest

from fixture_server import corrupt_bytes, sha256_hex, synthetic_content

LAB = Path(__file__).resolve().parents[1]

FAULT_FAMILIES = {
    "clean", "truncation", "wrong_content_length", "wrong_content_type",
    "wrong_hash", "redirect", "empty", "transient_status",
}

PRESEED_MODES = {None, "stale_manifest_ok", "partial_file"}


@pytest.fixture()
def manifest() -> dict:
    return json.loads((LAB / "scenarios.json").read_text())


def test_manifest_schema_and_loopback_flag(manifest):
    assert manifest["schema"] == "acquisition-faultlab/scenarios@1"
    assert manifest["loopback_only"] is True
    assert isinstance(manifest["scenarios"], list) and manifest["scenarios"]


def test_scenario_ids_unique(manifest):
    ids = [s["id"] for s in manifest["scenarios"]]
    assert len(ids) == len(set(ids))


def test_all_faults_are_declared_families(manifest):
    for s in manifest["scenarios"]:
        assert s["fault"] in FAULT_FAMILIES, s["id"]
        assert s.get("harness", {}).get("preseed") in PRESEED_MODES


@pytest.mark.parametrize("sid", [
    "clean-rgb-control", "truncation-rgb-clean-eof", "truncation-depth-clean-eof",
    "interrupted-write-rgb-rst", "wrong-content-length-understated",
    "wrong-content-length-overstated", "wrong-content-type-html",
    "wrong-hash-same-size-depth", "redirect-one-hop", "redirect-three-hops",
    "redirect-final-404", "empty-depth-raw", "transient-503-recovers",
    "transient-429-exhausted", "stale-cache-manifest-skip",
    "stale-cache-partial-overwrite",
])
def test_expected_scenario_present(manifest, sid):
    assert any(s["id"] == sid for s in manifest["scenarios"])


def test_expected_final_byte_records_rederive(manifest):
    for s in manifest["scenarios"]:
        content = synthetic_content(s["content"]["seed"], s["content"]["size"])
        exp = s["expect"]
        assert exp["content_size"] == s["content"]["size"]
        assert exp["content_sha256"] == sha256_hex(content)
        fault, serve = s["fault"], s["serve"]
        if fault == "truncation":
            cut = serve["truncate_at_bytes"]
            assert exp["served_size"] == cut
            assert exp["served_sha256"] == sha256_hex(content[:cut])
        elif fault == "wrong_hash":
            served = corrupt_bytes(content, serve["corrupt_at_bytes"])
            assert exp["served_size"] == len(served)
            assert exp["served_sha256"] == sha256_hex(served)
            assert exp["served_sha256"] != exp["content_sha256"]
        elif fault == "empty":
            assert exp["served_size"] == 0
            assert exp["served_sha256"] == sha256_hex(b"")
        else:
            assert exp["served_size"] == exp["content_size"]
            assert exp["served_sha256"] == exp["content_sha256"]


def test_wrong_hash_fault_is_same_size_as_content(manifest):
    for s in manifest["scenarios"]:
        if s["fault"] == "wrong_hash":
            assert s["expect"]["served_size"] == s["expect"]["content_size"]


def test_understated_delta_actually_undershoots(manifest):
    for s in manifest["scenarios"]:
        if s["fault"] == "wrong_content_length" and s["serve"]["length_delta"] < 0:
            assert s["expect"]["content_size"] + s["serve"]["length_delta"] > 0
            assert s["expect"]["content_size"] + s["serve"]["length_delta"] < s["expect"]["content_size"]


def test_committed_counts_match_manifest(manifest):
    committed = json.loads((LAB / "scenario_counts.json").read_text())
    assert committed["total"] == manifest["counts"]["total"] == len(manifest["scenarios"])
    assert committed["by_fault"] == manifest["counts"]["by_fault"]


def test_transient_recovery_fits_bounded_attempts(manifest):
    """fail_times must be <= RETRIES(3) - 1 for recovery scenarios to converge."""
    for s in manifest["scenarios"]:
        if s["fault"] == "transient_status" and s["id"] == "transient-503-recovers":
            assert s["serve"]["fail_times"] <= 2
