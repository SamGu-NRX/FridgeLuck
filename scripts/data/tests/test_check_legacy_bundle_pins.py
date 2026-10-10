"""Controls for the pin checker and the exporter's reproducibility.

Every corruption test mutates a copy of the committed corpus, never the
corpus itself: a checker that rewrote its inputs would be useless.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from conftest import CHECK_SCRIPT, EXPORT_SCRIPT, PINS_DIR, REPO_ROOT

COMMITTED_MANIFEST = json.loads((PINS_DIR / "manifest.json").read_text(encoding="utf-8"))


def run_checker(pins: Path) -> subprocess.CompletedProcess:
  return subprocess.run(
    [sys.executable, str(CHECK_SCRIPT), "--pins", str(pins)],
    capture_output=True,
    text=True,
    check=False,
  )


def run_exporter(slug: str, data_ref: str, out_dir: Path) -> subprocess.CompletedProcess:
  return subprocess.run(
    [
      sys.executable, str(EXPORT_SCRIPT),
      "--slug", slug, "--data-ref", data_ref, "--out-dir", str(out_dir),
    ],
    capture_output=True,
    text=True,
    check=False,
    cwd=str(REPO_ROOT),
  )


def test_committed_corpus_passes(pins_dir: Path) -> None:
  result = run_checker(pins_dir)
  assert result.returncode == 0, result.stdout + result.stderr
  assert "OK: 1 pin(s) verified" in result.stdout
  # The exact committed values, restated by the checker's own output.
  assert COMMITTED_MANIFEST["pins"][0]["dataSha256"] == (
    "62d9ed0ae7694cf3a6add076340314641fb064c0f4b9662cf6d910f0326e22be"
  )
  assert COMMITTED_MANIFEST["pins"][0]["catalogExportSha256"] == (
    "7c2fd33e19be9d5c98a9614609a4705d1a143d945a5b0156f6bc43ffb9efdeda"
  )
  assert COMMITTED_MANIFEST["pins"][0]["expectedCatalogRowCount"] == 800


def test_missing_manifest_fails(tmp_path: Path) -> None:
  result = run_checker(tmp_path)
  assert result.returncode == 1
  assert "no manifest" in result.stderr


def test_manifest_parse_error_fails(tmp_path: Path) -> None:
  (tmp_path / "manifest.json").write_text("{not json", encoding="utf-8")
  result = run_checker(tmp_path)
  assert result.returncode == 1
  assert "does not parse" in result.stderr


def test_missing_pin_file_fails(pins_copy: Path) -> None:
  (pins_copy / "v1_data.json").unlink()
  result = run_checker(pins_copy)
  assert result.returncode == 1
  assert "v1_data.json is missing" in result.stderr


def test_corrupted_catalog_export_fails(pins_copy: Path) -> None:
  target = pins_copy / "v1_usda_catalog_export.json"
  raw = bytearray(target.read_bytes())
  raw[raw.index(b'"fdcId"') + 2] ^= 0x01
  target.write_bytes(bytes(raw))
  result = run_checker(pins_copy)
  assert result.returncode == 1
  assert "catalog export hash mismatch" in result.stderr


def test_corrupted_data_payload_fails(pins_copy: Path) -> None:
  target = pins_copy / "v1_data.json"
  raw = bytearray(target.read_bytes())
  raw[raw.index(b'"tags"') + 2] ^= 0x01
  target.write_bytes(bytes(raw))
  result = run_checker(pins_copy)
  assert result.returncode == 1
  assert "data payload hash mismatch" in result.stderr


def test_row_count_mismatch_fails(pins_copy: Path) -> None:
  """Only the count is wrong: file bytes stay valid, the manifest claim drifts."""
  manifest_path = pins_copy / "manifest.json"
  manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
  manifest["pins"][0]["expectedCatalogRowCount"] = 799
  manifest_path.write_bytes(
    (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
  )
  result = run_checker(pins_copy)
  assert result.returncode == 1
  assert "catalog row count mismatch: manifest 799, actual 800" in result.stderr


def test_exporter_reproduces_the_committed_corpus(tmp_path: Path) -> None:
  """Re-running the exporter for v1 must reproduce the committed corpus
  byte for byte: same data payload (read from the pin commit's git
  object), same catalog export, same manifest."""
  result = run_exporter("v1", "42d9dc9", tmp_path)
  assert result.returncode == 0, result.stdout + result.stderr
  for name in ("manifest.json", "v1_data.json", "v1_usda_catalog_export.json"):
    exported = (tmp_path / name).read_bytes()
    committed = (PINS_DIR / name).read_bytes()
    assert exported == committed, f"{name} diverges from the committed corpus"


def test_exporter_preserves_other_slugs_and_sorts(tmp_path: Path) -> None:
  first = run_exporter("v2", "42d9dc9", tmp_path)
  assert first.returncode == 0, first.stdout + first.stderr
  second = run_exporter("v1", "42d9dc9", tmp_path)
  assert second.returncode == 0, second.stdout + second.stderr

  manifest = json.loads((tmp_path / "manifest.json").read_text(encoding="utf-8"))
  assert [pin["slug"] for pin in manifest["pins"]] == ["v1", "v2"]
  data_by_slug = {pin["slug"]: pin["dataSha256"] for pin in manifest["pins"]}
  # Both slugs pinned the same git object, so the payloads agree.
  assert data_by_slug["v1"] == data_by_slug["v2"] == (
    "62d9ed0ae7694cf3a6add076340314641fb064c0f4b9662cf6d910f0326e22be"
  )
