import pathlib
import sys

import pytest

HERE = pathlib.Path(__file__).resolve().parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


@pytest.fixture()
def tool_dir():
    return HERE


@pytest.fixture()
def matrix():
    import json

    return json.loads((HERE / "inputs" / "frozen_matrix.json").read_text(encoding="utf-8"))


@pytest.fixture()
def bounds():
    import json

    return json.loads((HERE / "inputs" / "perturbation_bounds.json").read_text(encoding="utf-8"))


@pytest.fixture()
def assumptions():
    import json

    return json.loads((HERE / "inputs" / "uncertainty_assumptions.json").read_text(encoding="utf-8"))
