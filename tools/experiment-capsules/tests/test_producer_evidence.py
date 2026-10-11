"""R6 regressions: producer evidence binding.

Available public input/build evidence binds into the capsule at pack time
(input references actually used, with digests; build/toolchain context).
Producer context that is not attested is explicitly ``unknown`` — and the
packer's own runtime environment is never presented as producer fact.
"""

import hashlib
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PACK = "tools/experiment-capsules/pack.py"


def run(*args):
    return subprocess.run(
        [sys.executable, *args], cwd=REPO_ROOT, capture_output=True, text=True, timeout=120
    )


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_committed_specs_bind_producer_evidence_into_bindings(tmp_path):
    out = tmp_path / "caps"
    result = run(PACK, "--spec", "tools/experiment-capsules/specs.json", "--out", str(out))
    assert result.returncode == 0, result.stdout + result.stderr

    catalog = json.loads(
        (out / "usda-curation-catalog" / "binding.json").read_text(encoding="utf-8")
    )
    evidence = catalog["producer_evidence"]
    # The input actually consumed is bound WITH its digest, computed at pack
    # time over the repository file.
    override = next(
        i for i in evidence["inputs"]
        if i["path"] == "scripts/data/usda_manual_overrides.json"
    )
    assert override["sha256"] == sha256_file(
        REPO_ROOT / "scripts/data/usda_manual_overrides.json"
    )
    # Build evidence names the producing entrypoint; the exact invocation is
    # explicitly unknown, never invented.
    assert evidence["build"]["entrypoint"] == "scripts/data/usda.py"
    assert evidence["unknown"], "unattested producer context must be listed"

    swift = json.loads(
        (out / "usda-swift-static-export" / "binding.json").read_text(encoding="utf-8")
    )
    sw_input = swift["producer_evidence"]["inputs"][0]
    assert sw_input["path"] == "apps/ios/Resources/usda_ingredient_nutrition_compact.json"
    assert sw_input["sha256"] == sha256_file(
        REPO_ROOT / "apps/ios/Resources/usda_ingredient_nutrition_compact.json"
    )
    assert swift["producer_evidence"]["build"]["entrypoint"] == (
        "scripts/data/generate_usda_ingredient_swift_static.py"
    )


def test_packer_runtime_facts_never_appear_as_producer_evidence(tmp_path):
    """The packer's interpreter/environment is not the producer's."""
    out = tmp_path / "caps"
    result = run(PACK, "--spec", "tools/experiment-capsules/specs.json", "--out", str(out))
    assert result.returncode == 0, result.stdout + result.stderr
    for capsule in out.iterdir():
        binding = json.loads((capsule / "binding.json").read_text(encoding="utf-8"))
        blob = json.dumps(binding["producer_evidence"])
        assert platform.python_version() not in blob


def test_absent_producer_input_is_rejected(tmp_path):
    """(R6) A producer-evidence input that does not exist fails the pack."""
    repo = tmp_path / "repo"
    (repo / "src").mkdir(parents=True)
    (repo / "out").mkdir()
    (repo / "src" / "study.py").write_text("print('x')\n", encoding="utf-8")
    (repo / "out" / "r.json").write_text("{}", encoding="utf-8")
    spec_path = tmp_path / "specs.json"
    spec_path.write_text(
        json.dumps(
            {
                "schema_version": "1",
                "specs": [
                    {
                        "capsule_id": "synthetic-study",
                        "title": "t",
                        "owner": "o",
                        "sources": [{"path": "src/study.py", "role": "source"}],
                        "toolchain": {
                            "language": "python",
                            "language_version": platform.python_version(),
                            "dependencies": [],
                        },
                        "permitted_inputs": ["input/missing.json"],
                        "model_transport": {"mode": "offline-deterministic"},
                        "coverage_gaps": [],
                        "producer_evidence": {
                            "inputs": [{"path": "input/missing.json", "note": "n"}],
                            "unknown": ["everything else"],
                        },
                        "outputs": [
                            {"origin_path": "out/r.json", "stored_as": "r.json"}
                        ],
                    }
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    result = run(
        PACK, "--spec", str(spec_path), "--out", str(tmp_path / "caps"), "--repo-root", str(repo)
    )
    assert result.returncode != 0
    assert "producer-evidence input is absent" in result.stdout + result.stderr


def test_symlinked_producer_input_is_rejected_before_read(tmp_path):
    """(R6/R1) A producer-evidence input behind a symlink is rejected before
    the open — the sentinel target is never read."""
    repo = tmp_path / "repo"
    (repo / "src").mkdir(parents=True)
    (repo / "out").mkdir()
    (repo / "input").mkdir()
    (repo / "src" / "study.py").write_text("print('x')\n", encoding="utf-8")
    (repo / "out" / "r.json").write_text("{}", encoding="utf-8")
    private = tmp_path / "private"
    private.mkdir()
    sentinel = private / "secret.txt"
    sentinel.write_text("PRIVATE-SENTINEL-7\n", encoding="utf-8")
    os.symlink(sentinel, repo / "input" / "leaked.json")
    spec_path = tmp_path / "specs.json"
    spec_path.write_text(
        json.dumps(
            {
                "schema_version": "1",
                "specs": [
                    {
                        "capsule_id": "synthetic-study",
                        "title": "t",
                        "owner": "o",
                        "sources": [{"path": "src/study.py", "role": "source"}],
                        "toolchain": {
                            "language": "python",
                            "language_version": platform.python_version(),
                            "dependencies": [],
                        },
                        "permitted_inputs": ["input/leaked.json"],
                        "model_transport": {"mode": "offline-deterministic"},
                        "coverage_gaps": [],
                        "producer_evidence": {
                            "inputs": [{"path": "input/leaked.json", "note": "n"}],
                            "unknown": [],
                        },
                        "outputs": [
                            {"origin_path": "out/r.json", "stored_as": "r.json"}
                        ],
                    }
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    result = run(
        PACK, "--spec", str(spec_path), "--out", str(tmp_path / "caps"), "--repo-root", str(repo)
    )
    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert "producer-evidence input path rejected before read" in combined
    assert "PRIVATE-SENTINEL-7" not in combined
    assert sentinel.read_text(encoding="utf-8") == "PRIVATE-SENTINEL-7\n"


# ---------------------------------------------------------------------------
# Schema-level validation (bindings with producer evidence)
# ---------------------------------------------------------------------------


def _raw_binding_with_producer(producer):
    return {
        "schema_version": "1",
        "capsule_id": "synthetic",
        "title": "t",
        "owner": "o",
        "sources": [{"path": "src/main.py", "role": "source", "sha256": "a" * 64}],
        "toolchain": {"language": "python", "language_version": "3.13.14"},
        "permitted_inputs": ["data/in.csv"],
        "model_transport": {"mode": "offline-deterministic"},
        "coverage_gaps": [],
        "outputs": [{"path": "out/t.txt", "sha256": "c" * 64, "bytes": 1}],
        "producer_evidence": producer,
    }


def test_binding_accepts_well_formed_producer_evidence():
    from capsule_model import parse_binding

    binding, findings = parse_binding(
        _raw_binding_with_producer(
            {
                "inputs": [{"path": "data/in.csv", "note": "consumed", "sha256": "a" * 64}],
                "build": {"entrypoint": "src/main.py", "args": ["--emit", "out/t.txt"]},
                "unknown": ["execution environment"],
            }
        )
    )
    assert binding is not None, findings
    assert binding.raw["producer_evidence"]["inputs"][0]["path"] == "data/in.csv"


def test_binding_rejects_unknown_producer_field():
    from capsule_model import parse_binding

    producer = {"inputs": [], "unknown": [], "environment": "mystery"}
    _, findings = parse_binding(_raw_binding_with_producer(producer))
    assert any(f.code == "schema" and "environment" in f.detail for f in findings)


def test_binding_rejects_bad_input_entry():
    from capsule_model import parse_binding

    producer = {"inputs": [{"note": "no path field"}]}
    _, findings = parse_binding(_raw_binding_with_producer(producer))
    assert any(f.code == "schema" and "inputs[0]" in f.path for f in findings)


def test_binding_rejects_non_string_unknown_entries():
    from capsule_model import parse_binding

    producer = {"unknown": ["ok", 42]}
    _, findings = parse_binding(_raw_binding_with_producer(producer))
    assert any(f.code == "schema" and "unknown" in f.path for f in findings)



def test_binding_without_producer_evidence_still_valid():
    from capsule_model import parse_binding

    raw = _raw_binding_with_producer({"inputs": [], "unknown": []})
    del raw["producer_evidence"]
    binding, findings = parse_binding(raw)
    assert binding is not None, findings
