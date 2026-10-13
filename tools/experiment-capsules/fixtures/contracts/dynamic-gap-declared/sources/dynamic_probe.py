"""Fixture source with a runtime-resolved optional import.

The import target is computed at runtime, so static analysis cannot name
the file(s) it would load. Coverage is declared as a gap in the binding --
never guessed as closed. This module is never executed by the offline
checker; it exists to pin the declaration flow.
"""

import importlib


def optional_codec(name: str):
    return importlib.import_module(f"fixture_codec_{name}")
