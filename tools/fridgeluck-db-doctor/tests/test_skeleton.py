"""Contract smoke test: skeleton imports and invariants (kept while streams land)."""
from __future__ import annotations

import codes  # noqa: F401  (tool dir is on sys.path via conftest)
import model


def test_budget_defaults_positive():
    b = model.Budget()
    assert b.max_steps >= 1 and b.max_rows >= 1 and b.max_seconds > 0


def test_budget_rejects_nonpositive():
    import pytest
    with pytest.raises(ValueError):
        model.Budget(max_steps=0)


def test_refusal_error_carries_code():
    e = model.RefusalError("INPUT_MISSING", "no such file")
    assert e.code == "INPUT_MISSING"


def test_verdicts_unique_strings():
    vals = [v.value for v in model.Verdict]
    assert len(vals) == len(set(vals))
