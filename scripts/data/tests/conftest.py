from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DATA = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DATA) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DATA))
