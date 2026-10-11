"""Pack/verify tests: the hard constraints, exercised through the CLIs.

- no all-repository hash sweep / owner immutability (packing to a scratch
  out leaves the repository untouched),
- write containment (a spec cannot escape --out, cannot overwrite owners),
- toolchain honesty (pack refuses a capsule claiming another interpreter),
- digest-stable re-pack,
- verify catches tampered outputs, hidden labels, layout violations, and
  dependency drift,
- the committed results verify clean and reproduce the committed report.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PACK = "tools/experiment-capsules/pack.py"
VERIFY = "tools/experiment-capsules/verify.py"
SPECS = "tools/experiment-capsules/specs.json"
RESULTS = REPO_ROOT / "tools/experiment-capsules/results"
REPORT = REPO_ROOT / "tools/experiment-capsules/reports/verify-report.json"


def run(*args):
    return subprocess.run(
        [sys.executable, *args], cwd=REPO_ROOT, capture_output=True, text=True, timeout=120
    )


def pack(out: Path, spec: Path = Path(SPECS)):
    return run(PACK, "--spec", str(spec), "--out", str(out))


def verify(capsules: Path, repo_root: Path = REPO_ROOT, report: Path | None = None):
    args = [VERIFY, "--capsules", str(capsules), "--repo-root", str(repo_root)]
    if report is not None:
        args += ["--report", str(report)]
    return run(*args)


def write_spec(tmp: Path, mutation) -> Path:
    raw = json.loads((REPO_ROOT / SPECS).read_text(encoding="utf-8"))
    mutation(raw)
    spec_path = tmp / "spec.json"
    spec_path.write_text(json.dumps(raw, indent=2), encoding="utf-8")
    return spec_path


def test_pack_writes_only_under_out_and_leaves_repo_untouched(tmp_path):
    out = tmp_path / "results"
    # Packing must not change the repository: compare worktree state
    # before and after rather than assuming a clean starting tree.
    before = subprocess.run(
        ["git", "status", "--porcelain"], cwd=REPO_ROOT, capture_output=True, text=True
    ).stdout
    result = pack(out)
    assert result.returncode == 0, result.stdout + result.stderr
    after = subprocess.run(
        ["git", "status", "--porcelain"], cwd=REPO_ROOT, capture_output=True, text=True
    ).stdout
    assert after == before, f"repository mutated by pack: {after!r} != {before!r}"
    # And the packed tree exists under the scratch out only.
    assert (out / "usda-curation-catalog" / "binding.json").is_file()


def test_pack_rejects_store_as_escape(tmp_path):
    spec = write_spec(tmp_path, lambda raw: raw["specs"][0]["outputs"][0].update({"stored_as": "../escape.txt"}))
    result = pack(tmp_path / "out", spec)
    assert result.returncode == 2, result.stdout
    assert "must be a bare file name" in result.stderr
    assert not (tmp_path / "escape.txt").exists()


def test_pack_rejects_missing_source(tmp_path):
    spec = write_spec(
        tmp_path,
        lambda raw: raw["specs"][0]["sources"].append(
            {"path": "scripts/data/does_not_exist.py", "role": "import"}
        ),
    )
    result = pack(tmp_path / "out", spec)
    assert result.returncode == 1, result.stdout
    assert "PACK FAILED" in result.stdout
    assert "declared source/import file is absent" in result.stdout
    assert not (tmp_path / "out" / "usda-curation-catalog").exists()


def test_pack_refuses_toolchain_mismatch(tmp_path):
    spec = write_spec(
        tmp_path, lambda raw: raw["specs"][0]["toolchain"].update({"language_version": "3.99.0"})
    )
    result = pack(tmp_path / "out", spec)
    assert result.returncode == 2, result.stdout
    assert "toolchain mismatch" in result.stderr


def test_pack_rejects_undeclared_dependency(tmp_path):
    spec = write_spec(
        tmp_path,
        # usda.py imports typer/orjson; dropping the declared dependencies
        # must trip the pack's import-closure gate.
        lambda raw: raw["specs"][0]["toolchain"].update({"dependencies": []}),
    )
    result = pack(tmp_path / "out", spec)
    assert result.returncode == 1, result.stdout
    assert "not import-closed" in result.stdout
    assert "undeclared-dependency" in result.stdout


def test_repack_is_digest_stable(tmp_path):
    out = tmp_path / "results"
    assert pack(out).returncode == 0
    first = {
        p.relative_to(out): p.read_bytes() for p in out.rglob("*") if p.is_file()
    }
    assert pack(out).returncode == 0
    second = {
        p.relative_to(out): p.read_bytes() for p in out.rglob("*") if p.is_file()
    }
    assert first == second, "re-pack must be byte-identical (digest-stable packing)"


def test_verify_detects_tampered_output(tmp_path):
    capsules = tmp_path / "capsules"
    shutil.copytree(RESULTS, capsules)
    target = next(capsules.glob("usda-swift-static-export/outputs/*.swift"))
    content = target.read_bytes()
    target.write_bytes(content + b"\n// tampered\n")
    result = verify(capsules)
    assert result.returncode == 1, result.stdout
    assert "source-mismatch" in result.stdout
    assert "usda-swift-static-export" in result.stdout


def test_verify_rejects_undeclared_stored_file(tmp_path):
    capsules = tmp_path / "capsules"
    shutil.copytree(RESULTS, capsules)
    (capsules / "usda-curation-catalog" / "outputs" / "hidden_label.txt").write_text("smuggled")
    result = verify(capsules)
    assert result.returncode == 1, result.stdout
    assert "undeclared-output" in result.stdout
    assert "hidden labels are not tolerated" in result.stdout


def test_verify_rejects_capsule_layout_violation(tmp_path):
    capsules = tmp_path / "capsules"
    shutil.copytree(RESULTS, capsules)
    (capsules / "usda-curation-catalog" / "notes.txt").write_text("extra top-level entry")
    result = verify(capsules)
    assert result.returncode == 1, result.stdout
    assert "capsule-layout" in result.stdout


def test_verify_checks_dependencies_against_declared_root(tmp_path):
    empty_root = tmp_path / "empty-repo"
    empty_root.mkdir()
    result = verify(RESULTS, repo_root=empty_root)
    assert result.returncode == 1, result.stdout
    assert "missing-import" in result.stdout
    assert "missing-output" in result.stdout or "origin file currently absent" in result.stdout


def test_committed_results_verify_clean_and_reproduce_report(tmp_path):
    report_path = tmp_path / "verify-report.json"
    result = verify(RESULTS, report=report_path)
    assert result.returncode == 0, result.stdout
    committed = json.loads(REPORT.read_text(encoding="utf-8"))
    fresh = json.loads(report_path.read_text(encoding="utf-8"))
    assert fresh == committed, "committed report must be reproducible byte-for-byte"


def test_tooling_is_network_free():
    for tool in ("pack.py", "verify.py", "check_contract.py"):
        source = (REPO_ROOT / "tools/experiment-capsules" / tool).read_text(encoding="utf-8")
        for network_module in ("urllib", "requests", "httpx", "socket", "http.client"):
            assert f"import {network_module}" not in source, f"{tool} imports {network_module}"
            assert f"from {network_module}" not in source, f"{tool} imports {network_module}"
