import sys
from pathlib import Path

LAB = Path(__file__).resolve().parents[1]
if str(LAB) not in sys.path:
    sys.path.insert(0, str(LAB))

import json

import pytest

from fixture_server import FaultServer


def load_scenarios() -> dict:
    return json.loads((LAB / "scenarios.json").read_text())


@pytest.fixture()
def lab_scenarios() -> list[dict]:
    return load_scenarios()["scenarios"]


@pytest.fixture()
def load_raw_scenarios() -> str:
    return (LAB / "scenarios.json").read_text()


@pytest.fixture()
def server_factory(lab_scenarios):
    """Start a FaultServer with the given scenario ids (default: all)."""
    started = []

    def _start(*scenario_ids: str) -> FaultServer:
        picked = [s for s in lab_scenarios if not scenario_ids or s["id"] in scenario_ids]
        srv = FaultServer(picked)
        started.append(srv)
        return srv  # `with` starts it; tests may also inspect bind state unstarted

    yield _start
    for srv in started:
        srv.stop()
