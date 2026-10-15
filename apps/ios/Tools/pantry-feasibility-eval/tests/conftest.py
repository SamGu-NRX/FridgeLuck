import sys
from pathlib import Path

import pytest

TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from oracle import Catalog  # noqa: E402


@pytest.fixture(scope="session")
def frozen_catalog():
    return Catalog.load(TOOL_DIR / "runs" / "catalog_snapshot.json")
