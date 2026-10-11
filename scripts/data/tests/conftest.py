from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
PINS_DIR = REPO_ROOT / "apps/ios/Resources/LegacyBundles"
CHECK_SCRIPT = REPO_ROOT / "scripts/data/check_legacy_bundle_pins.py"
EXPORT_SCRIPT = REPO_ROOT / "scripts/data/export_legacy_bundle.py"


@pytest.fixture(scope="session")
def repo_root() -> Path:
  return REPO_ROOT


@pytest.fixture(scope="session")
def pins_dir() -> Path:
  assert PINS_DIR.is_dir(), f"missing pin corpus at {PINS_DIR}"
  return PINS_DIR


@pytest.fixture
def pins_copy(tmp_path: Path, pins_dir: Path) -> Path:
  """A writable copy of the committed pin corpus; tests corrupt the copy."""
  target = tmp_path / "LegacyBundles"
  target.mkdir(parents=True)
  for path in pins_dir.iterdir():
    (target / path.name).write_bytes(path.read_bytes())
  return target
