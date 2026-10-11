"""Allow ``python -m sqlite_state_diff`` from tools/sqlite-state-diff."""

import sys

from .cli import main

sys.exit(main())
