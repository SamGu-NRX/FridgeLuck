"""Pytest suite guarding the usda_core examples.

Two layers of protection:

1. ``test_pipeline_demo_runs`` executes ``usda_core/examples/pipeline_demo.py``
   in a subprocess (the same way a new engineer would) and asserts it exits 0,
   prints every ``step N:`` marker, and reports the three app-facing SQLite
   tables the demo builds (``ingredient_catalog``, ``ingredients``,
   ``ingredient_aliases``).
2. ``test_doctest_sweep`` imports every top-level ``usda_core`` module and runs
   :mod:`doctest` on it, so documentation examples added by any contributor
   cannot rot silently. It also sweeps ``pipeline_demo.py`` itself, which is
   loaded from its file path because ``usda_core/examples`` is not a package.

Both tests are offline and deterministic: the demo talks only to its own
temporary directory, and the sweep never executes ``main()``.
"""

from __future__ import annotations

import doctest
import importlib
import importlib.util
import subprocess
import sys
from pathlib import Path

# tests/p11_test_examples.py -> parents[2] is scripts/data, the directory the
# demo and every `uv run` command expect to be the working directory.
SCRIPTS_DATA_DIR = Path(__file__).resolve().parents[2]
DEMO_PATH = SCRIPTS_DATA_DIR / "usda_core" / "examples" / "pipeline_demo.py"
STEP_MARKERS = tuple(f"step {number}:" for number in range(1, 8))
EXPECTED_TABLES = ("ingredient_catalog", "ingredients", "ingredient_aliases")
DEMO_TIMEOUT_SECONDS = 120


def test_pipeline_demo_runs() -> None:
    """Run the demo exactly as the README documents and assert its output contract.

    The subprocess uses the same interpreter that is running the tests (the
    project venv python under ``uv run``) with cwd set to ``scripts/data``, so
    the demo's ``sys.path`` bootstrap resolves ``usda_core`` the way it does
    for a human. The three table names must appear in stdout because the demo
    prints them while inspecting the SQLite database it just built.
    """
    result = subprocess.run(
        [sys.executable, str(DEMO_PATH)],
        cwd=str(SCRIPTS_DATA_DIR),
        capture_output=True,
        text=True,
        timeout=DEMO_TIMEOUT_SECONDS,
        check=False,
    )
    transcript = result.stdout + result.stderr
    assert result.returncode == 0, f"demo failed:\n{transcript}"
    for marker in STEP_MARKERS:
        assert marker in result.stdout, f"missing {marker!r} in demo stdout"
    for table in EXPECTED_TABLES:
        assert table in result.stdout, f"missing table {table!r} in demo stdout"


def _run_doctests_on_module(module: importlib.types.ModuleType, results: list[tuple[str, doctest.TestResults]]) -> None:
    """Collect doctest.testmod results for one already-imported module."""
    results.append((module.__name__, doctest.testmod(module, verbose=False)))


def test_doctest_sweep() -> None:
    """Run doctest.testmod on every top-level usda_core module; zero failures allowed.

    Every module under ``usda_core/*.py`` is importable with no side effects
    (no network, no filesystem writes at import time), so a plain
    ``importlib.import_module`` is safe. ``pipeline_demo.py`` is loaded by file
    path via :mod:`importlib.util` because ``usda_core/examples`` has no
    ``__init__.py`` and is therefore not an importable subpackage; loading it
    executes only definitions (its ``main()`` is behind the ``__main__`` guard).
    """
    results: list[tuple[str, doctest.TestResults]] = []

    usda_core_dir = SCRIPTS_DATA_DIR / "usda_core"
    for path in sorted(usda_core_dir.glob("*.py")):
        if path.name == "__init__.py":
            continue
        _run_doctests_on_module(importlib.import_module(f"usda_core.{path.stem}"), results)

    spec = importlib.util.spec_from_file_location("pipeline_demo", DEMO_PATH)
    assert spec is not None and spec.loader is not None, f"cannot load {DEMO_PATH}"
    demo_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(demo_module)
    _run_doctests_on_module(demo_module, results)

    failures = [(name, outcome.failed) for name, outcome in results if outcome.failed]
    assert not failures, f"doctest failures: {failures}"
