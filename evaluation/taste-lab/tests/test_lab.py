"""Determinism, bounds, and fixture-replay tests."""

from __future__ import annotations

import json
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, REPO_ROOT)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from taste_lab import constants  # noqa: E402
from taste_lab.evalcli import run_eval, regenerate, load_fixtures, validate_fixture  # noqa: E402
from taste_lab.features import load_catalog  # noqa: E402

# The eval runs over the shipped bundle-v2 catalog (763 recipes); load_catalog
# dispatches on bundle_version, so the same suite still exercises the legacy
# positional loader when pointed at apps/ios/Resources/data.json.
CATALOG = os.path.join(REPO_ROOT, "apps", "ios", "Resources", "RecipeCatalog", "recipes-v2.json")
FIXTURE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")


@pytest.fixture(scope="module")
def catalog():
    return load_catalog(CATALOG)


def test_same_seed_same_report(catalog):
    a = run_eval(catalog, households_n=6, days=10, seed=11)
    b = run_eval(catalog, households_n=6, days=10, seed=11)
    assert a == b, "same seed must reproduce the report byte for byte"


def test_different_seed_different_report(catalog):
    a = run_eval(catalog, households_n=6, days=10, seed=11)
    b = run_eval(catalog, households_n=6, days=10, seed=12)
    assert a != b


def test_residual_contributions_bounded(catalog):
    from taste_lab.baselines import ResidualArm
    from taste_lab.rules import RuleRanker
    from taste_lab.sim import simulate, start_day

    households = simulate(catalog, 3, 12, start_day(), seed=3)
    for h in households:
        rule = RuleRanker(catalog, goal=h.goal)
        arm = ResidualArm(catalog, rule)
        arm.observe(h.events, h.exposures)
        contribs = arm.engine.contributions("2026-02-01T00:00:00Z")
        for fk, c in contribs.items():
            cap = constants.CAP[fk.split(":", 1)[0]]
            assert abs(c) <= cap + 1e-9, f"{fk}: {c} exceeds cap {cap}"
            assert abs(c) <= constants.GLOBAL_CLAMP + 1e-9


def test_residual_never_overturns_rule_gaps(catalog):
    """The learned shift stays within the spec's 2-3 point guardrail: an
    ordering flipped by the residual layer must have rule scores within
    GLOBAL_CLAMP of each other (never a big rule-score reversal)."""
    from taste_lab.baselines import ResidualArm
    from taste_lab.rules import RuleRanker
    from taste_lab.sim import simulate, start_day

    households = simulate(catalog, 4, 12, start_day(), seed=5)
    for h in households:
        rule = RuleRanker(catalog, goal=h.goal)
        arm = ResidualArm(catalog, rule)
        arm.observe(h.events, h.exposures)
        pantry = h.pantry
        feasible = h.feasible_recipes(pantry)
        if len(feasible) < 5:
            continue
        eval_dt = __import__("datetime").datetime(2026, 1, 15, 2, 0)
        rule_scores = rule.rule_scores(feasible, pantry, eval_dt)
        residual_order = arm.rank(feasible, pantry, eval_dt)
        # For every adjacent inversion in the residual order (x ranked above
        # y despite a lower rule score), the rule-score gap must not exceed
        # GLOBAL_CLAMP — the learned layer can never span a bigger gap.
        for i in range(len(residual_order) - 1):
            for j in range(i + 1, len(residual_order)):
                x, y = residual_order[i], residual_order[j]
                gap = rule_scores[y] - rule_scores[x]
                assert gap <= constants.GLOBAL_CLAMP + 1e-9, (
                    f"residual inverted a rule-score gap of {gap:.3f} "
                    f"({x} over {y})"
                )


def test_lab_golden_fixtures_replay(catalog):
    fixtures = load_fixtures(FIXTURE_DIR, catalog)
    assert fixtures, "the lab's committed golden fixtures must exist"
    problems = []
    for doc in fixtures:
        problems.extend(validate_fixture(doc, catalog))
    assert not problems, "\n".join(problems)


def test_evalcli_regenerate_is_stable(catalog, tmp_path):
    out_a = tmp_path / "a"
    out_b = tmp_path / "b"
    regenerate(str(out_a), catalog, seed=7)
    regenerate(str(out_b), catalog, seed=7)
    for name in sorted(os.listdir(out_a)):
        with open(out_a / name) as fa, open(out_b / name) as fb:
            assert json.load(fa) == json.load(fb), f"{name} not deterministic"
