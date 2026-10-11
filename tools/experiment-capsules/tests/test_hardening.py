"""R7–R8 regressions: provenance identities and separated diagnostics.

R7 — the regeneration proof must show actual binding identities (capsule
id, binding digest, toolchain, producer-evidence state) and an explicit
same/different/UNKNOWN status per declared source, even when output numbers
agree. Printing only an output digest is not provenance.

R8 — where source drift exists, verification stays strict (VERIFIED/REJECTED
semantics unchanged) AND clearly labeled DIAGNOSTIC comparisons are emitted
separately. Diagnostics are derived after the verdict is final and can never
flip it.
"""

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
VERIFY = "tools/experiment-capsules/verify.py"
REGEN = "tools/experiment-capsules/regen.py"
CHECK = "tools/experiment-capsules/check_contract.py"
RESULTS = REPO_ROOT / "tools/experiment-capsules/results"
FIXTURES = REPO_ROOT / "tools/experiment-capsules/fixtures/contracts"


def run(*args):
    return subprocess.run(
        [sys.executable, *args], cwd=REPO_ROOT, capture_output=True, text=True, timeout=120
    )


# ---------------------------------------------------------------------------
# R7 — provenance identities in the regeneration proof
# ---------------------------------------------------------------------------


def test_regen_report_shows_binding_identities_and_source_statuses(tmp_path):
    """(R7) The proof report contains the provenance-identity section: per
    capsule — id, binding digest, toolchain — and per declared source a
    same/different/UNKNOWN status line."""
    out = tmp_path / "regen-proof"
    result = run(REGEN, "--capsules", str(RESULTS), "--out", str(out))
    assert result.returncode == 0, result.stdout + result.stderr
    report = (out / "regen-proof.md").read_text(encoding="utf-8")

    assert "## Provenance identities (capsule bindings)" in report
    assert "`usda-curation-catalog`" in report
    assert "`usda-swift-static-export`" in report
    assert "binding digest" in report
    assert "toolchain:" in report
    # Every declared source gets an explicit status; committed capsules
    # currently match the repository, so the statuses read "same".
    assert " — same" in report
    assert "declared sha256" in report


def test_provenance_identities_mark_absent_source_unknown(tmp_path):
    """(R7) A declared source absent from the repository is UNKNOWN — never
    silently treated as agreement."""
    sys.path.insert(0, str(REPO_ROOT / "tools/experiment-capsules"))
    from regen import provenance_identities

    capsules = tmp_path / "capsules"
    (capsules / "synthetic").mkdir(parents=True)
    binding = {
        "schema_version": "1",
        "capsule_id": "synthetic",
        "title": "t",
        "owner": "o",
        "sources": [
            {"path": "does/not/exist.py", "role": "source", "sha256": "a" * 64}
        ],
        "toolchain": {"language": "python", "language_version": "3.13.14"},
        "outputs": [],
    }
    (capsules / "synthetic" / "binding.json").write_text(
        json.dumps(binding, indent=2), encoding="utf-8"
    )
    lines = provenance_identities(capsules, REPO_ROOT)
    assert any("does/not/exist.py" in line and "UNKNOWN" in line for line in lines)


def test_provenance_identities_state_missing_producer_evidence_unknown(tmp_path):
    """(R6/R7) A binding without producer evidence reports the producer
    context as explicitly unknown in the identity section."""
    sys.path.insert(0, str(REPO_ROOT / "tools/experiment-capsules"))
    from regen import provenance_identities

    capsules = tmp_path / "capsules"
    (capsules / "synthetic").mkdir(parents=True)
    binding = {
        "schema_version": "1",
        "capsule_id": "synthetic",
        "title": "t",
        "owner": "o",
        "sources": [],
        "toolchain": {"language": "python", "language_version": "3.13.14"},
        "outputs": [],
    }
    (capsules / "synthetic" / "binding.json").write_text(
        json.dumps(binding, indent=2), encoding="utf-8"
    )
    lines = provenance_identities(capsules, REPO_ROOT)
    assert any("producer context explicitly unknown" in line for line in lines)


# ---------------------------------------------------------------------------
# R8 — strict verification with separated diagnostics
# ---------------------------------------------------------------------------


def _tamper_a_packed_output(tmp_path) -> Path:
    """Pack the committed specs into a scratch dir, then flip one byte of a
    packed output so verification must REJECT with source-mismatch."""
    out = tmp_path / "caps"
    packed = run(
        "tools/experiment-capsules/pack.py",
        "--spec",
        "tools/experiment-capsules/specs.json",
        "--out",
        str(out),
    )
    assert packed.returncode == 0, packed.stdout + packed.stderr
    target = out / "usda-swift-static-export" / "outputs" / "USDAIngredientNutritionStaticData.swift"
    content = target.read_bytes()
    target.write_bytes(b"x" + content[1:])
    return out


def test_tampered_capsule_is_rejected_and_diagnostics_stay_separate(tmp_path):
    """(R8) Drift keeps strict REJECTED semantics; the report carries a
    separate labeled diagnostics block; diagnostics never appear as findings
    or change the counts."""
    out = _tamper_a_packed_output(tmp_path)
    report_path = tmp_path / "verify-report.json"
    result = run(VERIFY, "--capsules", str(out), "--report", str(report_path))
    assert result.returncode == 1

    report = json.loads(report_path.read_text(encoding="utf-8"))
    swift = next(c for c in report["capsules"] if c["capsule"] == "usda-swift-static-export")
    assert swift["status"] == "rejected"
    assert swift["counts"].get("source-mismatch") == 1
    # Diagnostics: separate, labeled, derived after the verdict.
    assert swift["diagnostics_note"] == (
        "informational comparisons only; cannot change the result"
    )
    assert any(
        d["kind"] == "diagnostic" and d["code"] == "source-mismatch" and "declared output digest" in d["comparison"]
        for d in swift["diagnostics"]
    )
    # The strict findings list does not contain diagnostic entries.
    assert all(f["code"] != "diagnostic" for f in swift["findings"])
    # The CLI prints the labeled block.
    assert "DIAGNOSTICS" in result.stdout


def test_clean_capsule_has_empty_diagnostics(tmp_path):
    """(R8) A clean capsule reports an empty diagnostics list — diagnostics
    exist only where drift exists, and never for clean VERIFIED results."""
    out = tmp_path / "caps"
    packed = run(
        "tools/experiment-capsules/pack.py",
        "--spec",
        "tools/experiment-capsules/specs.json",
        "--out",
        str(out),
    )
    assert packed.returncode == 0, packed.stdout + packed.stderr
    report_path = tmp_path / "verify-report.json"
    result = run(VERIFY, "--capsules", str(out), "--report", str(report_path))
    assert result.returncode == 0
    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert all(c["diagnostics"] == [] for c in report["capsules"])


def test_check_contract_cli_prints_diagnostics_on_drift():
    """(R8) The contract checker's single-binding mode prints the labeled
    DIAGNOSTICS block for a drifted fixture and exits non-zero."""
    result = run(CHECK, "--binding", str(FIXTURES / "source-mismatch" / "binding.json"))
    assert result.returncode == 1
    assert "DIAGNOSTICS" in result.stdout
    assert "never able to change the verification result" in result.stdout
    assert "source-mismatch=1" in result.stdout
