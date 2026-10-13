"""Binding schema tests: canonical digests, strict parsing, boundary rules."""

import copy

from capsule_model import (
    Finding,
    canonical_json_bytes,
    parse_binding,
    sha256_hex,
)

VALID = {
    "schema_version": "1",
    "capsule_id": "fixture-valid",
    "study_id": "fixture-study",
    "title": "t",
    "owner": "o",
    "sources": [
        {"path": "src/main.py", "role": "source", "sha256": "a" * 64},
        {"path": "src/helper.py", "role": "import", "sha256": "b" * 64},
    ],
    "toolchain": {"language": "python", "language_version": "3.13.14", "dependencies": []},
    "permitted_inputs": ["data/summary.csv"],
    "model_transport": {
        "mode": "offline-deterministic",
        "model": None,
        "temperature": None,
        "seed": None,
        "network": "none",
    },
    "coverage_gaps": [],
    "outputs": [{"path": "out/table.txt", "sha256": "c" * 64, "bytes": 10}],
}


def codes(findings):
    return [f.code for f in findings]


def test_sha256_empty_vector():
    assert sha256_hex(b"") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def test_canonical_bytes_independent_of_key_order():
    a = {"x": 1, "y": {"b": 2, "a": 3}}
    b = {"y": {"a": 3, "b": 2}, "x": 1}
    assert canonical_json_bytes(a) == canonical_json_bytes(b)
    assert canonical_json_bytes(a) == b'{"x":1,"y":{"a":3,"b":2}}'


def test_valid_binding_parses_clean():
    binding, findings = parse_binding(VALID)
    assert findings == []
    assert binding is not None
    assert binding.capsule_id == "fixture-valid"
    assert binding.source_paths() == {"src/main.py", "src/helper.py"}
    assert binding.outputs[0].bytes == 10


def test_unknown_field_is_schema_finding():
    raw = copy.deepcopy(VALID)
    raw["extra_field"] = 1
    binding, findings = parse_binding(raw)
    assert binding is None
    assert codes(findings) == ["schema"]


def test_volatile_field_rejected():
    raw = copy.deepcopy(VALID)
    raw["sources"][0]["generated_at"] = "2026-10-11T00:00:00Z"
    binding, findings = parse_binding(raw)
    assert binding is None
    assert codes(findings) == ["schema"]
    assert "volatile" in findings[0].detail


def test_credential_shaped_field_rejected():
    raw = copy.deepcopy(VALID)
    raw["model_transport"]["api_key"] = "sk-nothing"
    binding, findings = parse_binding(raw)
    assert binding is None
    assert "credential-shaped" in findings[0].detail


def test_path_traversal_rejected():
    raw = copy.deepcopy(VALID)
    raw["permitted_inputs"] = ["../../etc/passwd"]
    binding, findings = parse_binding(raw)
    assert binding is None
    assert any("traverse" in f.detail for f in findings)


def test_absolute_path_rejected():
    raw = copy.deepcopy(VALID)
    raw["outputs"][0]["path"] = "/etc/passwd"
    binding, findings = parse_binding(raw)
    assert binding is None


def test_bad_digest_rejected():
    raw = copy.deepcopy(VALID)
    raw["sources"][0]["sha256"] = "not-a-digest"
    binding, findings = parse_binding(raw)
    assert binding is None
    assert any("sha256" in f.detail for f in findings)


def test_duplicate_source_path_rejected():
    raw = copy.deepcopy(VALID)
    raw["sources"] = [raw["sources"][0], dict(raw["sources"][0])]
    binding, findings = parse_binding(raw)
    assert binding is None
    assert any("duplicate source path" in f.detail for f in findings)


def test_coverage_gap_for_undeclared_file_rejected():
    raw = copy.deepcopy(VALID)
    raw["coverage_gaps"] = [{"file": "src/other.py", "reason": "r"}]
    binding, findings = parse_binding(raw)
    assert binding is None
    assert any("not a declared source" in f.detail for f in findings)


def test_model_mode_without_model_name_rejected():
    raw = copy.deepcopy(VALID)
    raw["model_transport"] = {"mode": "model"}
    binding, findings = parse_binding(raw)
    assert binding is None
    assert any("model_transport.model" in f.path for f in findings)


def test_finding_round_trips_to_dict():
    finding = Finding("schema", "p", "d")
    assert finding.to_dict() == {"code": "schema", "path": "p", "detail": "d"}
