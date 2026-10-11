"""R1–R3 regressions: the path trust boundary, exercised through the CLIs.

Sentinel files stand in for private/owner files — no real private input is
ever present in these fixtures. Every test proves the boundary held by
comparing sentinel BYTES and MTIME before/after the attempted operation:

- (R1/R3a) a declared source that is a symlink to a private sentinel is
  rejected BEFORE any read; the sentinel is never opened (content and
  mtime unchanged, and the sentinel's secret content never appears in the
  tool's output),
- (R2/R3b) a pre-existing ``binding.json`` symlink at a pack destination is
  refused — the sentinel target stays byte-identical (never overwritten
  through the link),
- (R1/R3c) the same holds for a symlinked ``binding.json`` under verify,
  and for a symlinked owner origin (unknown drift, never followed),
- (R1) ``..``-traversal in a spec path is rejected at spec validation,
  before any read.
"""

import json
import os
import platform
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PACK = "tools/experiment-capsules/pack.py"
VERIFY = "tools/experiment-capsules/verify.py"

SENTINEL_CONTENT = "PRIVATE-SENTINEL-DO-NOT-READ-42\n"


def run(*args):
    return subprocess.run(
        [sys.executable, *args], cwd=REPO_ROOT, capture_output=True, text=True, timeout=120
    )


def snapshot(path: Path) -> tuple[bytes, int]:
    return path.read_bytes(), os.lstat(path).st_mtime_ns


def make_study_repo(root: Path) -> tuple[Path, Path]:
    """A minimal synthetic study repo: one source, one input, one output.

    Returns (repo_root, spec_path). Nothing here is private; the sentinel
    tests add private files OUTSIDE the repo and point tools at them only
    through links that the boundary must reject.
    """
    (root / "src").mkdir(parents=True)
    (root / "input").mkdir(parents=True)
    (root / "out").mkdir(parents=True)
    (root / "src" / "study.py").write_text("print('study')\n", encoding="utf-8")
    (root / "input" / "study_input.json").write_text("{}\n", encoding="utf-8")
    (root / "out" / "study_result.json").write_text('{"rows": 1}\n', encoding="utf-8")
    spec = {
        "schema_version": "1",
        "specs": [
            {
                "capsule_id": "synthetic-study",
                "title": "synthetic study",
                "owner": "test",
                "sources": [{"path": "src/study.py", "role": "source"}],
                "toolchain": {
                    "language": "python",
                    "language_version": platform.python_version(),
                    "dependencies": [],
                },
                "permitted_inputs": ["input/study_input.json"],
                "model_transport": {"mode": "offline-deterministic"},
                "coverage_gaps": [],
                "outputs": [
                    {
                        "origin_path": "out/study_result.json",
                        "stored_as": "study_result.json",
                    }
                ],
            }
        ],
    }
    spec_path = root / "specs.json"
    spec_path.write_text(json.dumps(spec, indent=2), encoding="utf-8")
    return root, spec_path


def make_sentinel(private_dir: Path) -> Path:
    private_dir.mkdir(parents=True, exist_ok=True)
    sentinel = private_dir / "secret.txt"
    sentinel.write_text(SENTINEL_CONTENT, encoding="utf-8")
    return sentinel


def test_symlinked_source_rejected_before_any_read(tmp_path):
    """(R1/R3a) A source that is a symlink to a private file is rejected
    before the open: the sentinel's bytes and mtime are untouched and its
    content never reaches the tool's output."""
    repo, spec = make_study_repo(tmp_path / "repo")
    sentinel = make_sentinel(tmp_path / "private")
    os.symlink(sentinel, repo / "src" / "link_to_private.py")

    spec_doc = json.loads(spec.read_text(encoding="utf-8"))
    spec_doc["specs"][0]["sources"].append(
        {"path": "src/link_to_private.py", "role": "source"}
    )
    spec.write_text(json.dumps(spec_doc, indent=2), encoding="utf-8")

    before = snapshot(sentinel)
    result = run(PACK, "--spec", str(spec), "--out", str(tmp_path / "caps"), "--repo-root", str(repo))
    after = snapshot(sentinel)

    assert result.returncode != 0
    assert "rejected before read" in result.stdout + result.stderr
    # (R3c) nothing was read: bytes and mtime identical, content never leaked.
    assert after == before
    tool_output = result.stdout + result.stderr
    assert "PRIVATE-SENTINEL-DO-NOT-READ-42" not in tool_output


def test_traversal_spec_path_rejected_before_read(tmp_path):
    """(R1) A ``..``-escape in a spec path is rejected at spec validation,
    before any read of the referenced private file."""
    repo, _ = make_study_repo(tmp_path / "repo")
    sentinel = make_sentinel(tmp_path / "private")
    spec_path = tmp_path / "bad-spec.json"
    spec_doc = {
        "schema_version": "1",
        "specs": [
            {
                "capsule_id": "synthetic-study",
                "title": "synthetic study",
                "owner": "test",
                "sources": [{"path": "../private/secret.txt", "role": "source"}],
                "toolchain": {
                    "language": "python",
                    "language_version": platform.python_version(),
                    "dependencies": [],
                },
                "permitted_inputs": ["input/study_input.json"],
                "model_transport": {"mode": "offline-deterministic"},
                "coverage_gaps": [],
                "outputs": [
                    {
                        "origin_path": "out/study_result.json",
                        "stored_as": "study_result.json",
                    }
                ],
            }
        ],
    }
    spec_path.write_text(json.dumps(spec_doc, indent=2), encoding="utf-8")

    before = snapshot(sentinel)
    result = run(PACK, "--spec", str(spec_path), "--out", str(tmp_path / "caps"), "--repo-root", str(repo))
    after = snapshot(sentinel)

    assert result.returncode != 0
    assert "invalid path" in result.stdout + result.stderr
    assert after == before
    assert "PRIVATE-SENTINEL-DO-NOT-READ-42" not in result.stdout + result.stderr


def test_planted_binding_symlink_leaves_sentinel_byte_identical(tmp_path):
    """(R2/R3b) A pre-existing binding.json symlink at the pack destination
    is refused — the sentinel it points at is never overwritten through the
    link, byte for byte and mtime for mtime."""
    repo, spec = make_study_repo(tmp_path / "repo")
    sentinel = make_sentinel(tmp_path / "private")
    capsule_dir = tmp_path / "caps" / "synthetic-study"
    capsule_dir.mkdir(parents=True)
    os.symlink(sentinel, capsule_dir / "binding.json")

    before = snapshot(sentinel)
    result = run(PACK, "--spec", str(spec), "--out", str(tmp_path / "caps"), "--repo-root", str(repo))
    after = snapshot(sentinel)

    assert result.returncode != 0
    assert "refused" in result.stdout + result.stderr
    # The symlink itself is still there (never deleted through), and the
    # sentinel it targets is byte-unchanged.
    assert (capsule_dir / "binding.json").is_symlink()
    assert after == before
    assert sentinel.read_text(encoding="utf-8") == SENTINEL_CONTENT


def test_verify_rejects_symlinked_binding_without_reading_it(tmp_path):
    """(R1/R3) A capsule whose binding.json is a symlink to a private file
    is rejected before the open; the sentinel is never read or modified."""
    repo, spec = make_study_repo(tmp_path / "repo")
    sentinel = make_sentinel(tmp_path / "private")
    out = tmp_path / "caps"
    packed = run(PACK, "--spec", str(spec), "--out", str(out), "--repo-root", str(repo))
    assert packed.returncode == 0, packed.stdout + packed.stderr

    capsule_dir = out / "synthetic-study"
    (capsule_dir / "binding.json").unlink()
    os.symlink(sentinel, capsule_dir / "binding.json")

    before = snapshot(sentinel)
    result = run(VERIFY, "--capsules", str(out), "--repo-root", str(repo))
    after = snapshot(sentinel)

    assert result.returncode == 1
    assert "capsule-path-untrusted" in result.stdout
    assert "rejected before read" in result.stdout
    assert after == before
    assert "PRIVATE-SENTINEL-DO-NOT-READ-42" not in result.stdout + result.stderr


def test_symlinked_owner_origin_is_unknown_drift_never_followed(tmp_path):
    """(R1/R3) An owner origin replaced by a symlink is reported as unknown
    drift and never followed; the packed capsule still verifies on its own
    packed copies, and the sentinel target is untouched."""
    repo, spec = make_study_repo(tmp_path / "repo")
    sentinel = make_sentinel(tmp_path / "private")
    out = tmp_path / "caps"
    packed = run(PACK, "--spec", str(spec), "--out", str(out), "--repo-root", str(repo))
    assert packed.returncode == 0, packed.stdout + packed.stderr

    origin = repo / "out" / "study_result.json"
    origin.unlink()
    os.symlink(sentinel, origin)

    before = snapshot(sentinel)
    result = run(VERIFY, "--capsules", str(out), "--repo-root", str(repo))
    after = snapshot(sentinel)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "VERIFIED" in result.stdout
    assert "origin-drift" in result.stdout
    assert "unknown" in result.stdout.lower()
    assert after == before
