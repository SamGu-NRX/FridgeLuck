"""Read-only SQLite state diff for closed synthetic fixtures.

Compares two explicitly named fixture files and reports precise schema,
row, and typed-value differences. Never writes to its inputs. See
tools/sqlite-state-diff/README.md for scope, contract, and limits.
"""

__version__ = "0.1.0"
