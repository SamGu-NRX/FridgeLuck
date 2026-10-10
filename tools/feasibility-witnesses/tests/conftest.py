import subprocess
import sys
from pathlib import Path

import pytest

TOOL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL_DIR))

from sources import SourceBundle  # noqa: E402


@pytest.fixture(scope="session")
def bundle() -> SourceBundle:
    if not (TOOL_DIR / "fixtures" / "manifest.json").is_file():
        subprocess.run([sys.executable, str(TOOL_DIR / "make_fixtures.py")], check=True)
    return SourceBundle(TOOL_DIR / "fixtures")
