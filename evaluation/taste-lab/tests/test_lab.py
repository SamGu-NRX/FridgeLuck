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
    """Pairwise consequence of the per-recipe clamp on simulated data: an
    ordering flipped by the residual layer must have rule scores within
    2 * GLOBAL_CLAMP of each other (each side's applied shift is bounded by
    GLOBAL_CLAMP, so no inversion can span a bigger gap). The clamp itself is
    pinned by test_global_clamp_pins_saturated_shifts; simulated data never
    saturates, so this test observes the consequence rather than pinning the
    bound."""
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
        # Pairwise consequence of the per-recipe clamp (SPEC 2.2): each
        # recipe's applied learned shift is bounded by GLOBAL_CLAMP, so an
        # inverted pair can span a rule gap of at most 2 * GLOBAL_CLAMP.
        # (Not GLOBAL_CLAMP: the clamp bounds the per-recipe shift, not the
        # pairwise span — a pair can legitimately invert with a gap up to
        # just under 2 * GLOBAL_CLAMP.)
        for i in range(len(residual_order) - 1):
            for j in range(i + 1, len(residual_order)):
                x, y = residual_order[i], residual_order[j]
                gap = rule_scores[y] - rule_scores[x]
                assert gap <= 2 * constants.GLOBAL_CLAMP + 1e-9, (
                    f"residual inverted a rule-score gap of {gap:.3f} "
                    f"({x} over {y})"
                )
                shift_x = arm_eval_shift(arm, x, eval_dt, rule_scores)
                assert abs(shift_x) <= constants.GLOBAL_CLAMP + 1e-9


def arm_eval_shift(arm, rid, eval_dt, rule_scores):
    """The applied learned shift for one recipe: total - rule anchor.
    ResidualArm.rank returns ids; the engine's rank entries carry the
    totals."""
    iso = eval_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    for e in arm.engine.rank(rule_scores, iso):
        if e.recipe_id == rid:
            return e.total_score - rule_scores[rid]
    return 0.0


def test_global_clamp_pins_saturated_shifts():
    """The clamp must be pinned, not just observed (PR #149 review, finding 3).

    Posteriors are engineered so each recipe's unclamped learned sum reaches
    about +/-12 (three ingredient features each contributing ~4.0, the class
    cap). SPEC 2.2's GLOBAL_CLAMP = 8.0 must bound the *applied* per-recipe
    shift to exactly +/-8.0. A simulated-data inversion test cannot catch a
    bypassed or scaled clamp (its sample never saturates); this construction
    fails if the clamp at engine.py rank()/_contribution_of() is removed,
    bypassed, or multiplied (3x and 10x mutation-checked)."""
    from taste_lab.engine import TasteResidualEngine, _Posterior, parse_utc

    eval_at = "2026-01-15T02:00:00Z"
    t = parse_utc(eval_at)
    features = {
        "A": ["ingredient:a1", "ingredient:a2", "ingredient:a3"],
        "B": ["ingredient:b1", "ingredient:b2", "ingredient:b3"],
    }
    engine = TasteResidualEngine(features)
    # Saturated posteriors: d ~ +1 / -1, shrinkage c ~ 1, so each feature's
    # contribution lands at ~ +/-CAP(ingredient) = +/-4.0 and the per-recipe
    # sum at ~ +/-12, far beyond GLOBAL_CLAMP = 8.0. last_update == eval
    # instant, so no decay intervenes.
    for fk in ("a1", "a2", "a3"):
        engine.state[f"ingredient:{fk}"] = _Posterior(
            alpha=5000.0, beta=0.5, last_update=t, last_evidence=t, last_class="cook_rating"
        )
    for fk in ("b1", "b2", "b3"):
        engine.state[f"ingredient:{fk}"] = _Posterior(
            alpha=0.5, beta=5000.0, last_update=t, last_evidence=t, last_class="cook_rating"
        )

    # Rule anchor strongly favours A (gap 12 > GLOBAL_CLAMP): the clamp, not
    # the rule order, is what bounds how far the learned layer can move these.
    rule_scores = {"A": 40.0, "B": 28.0}
    entries = engine.rank(rule_scores, eval_at)
    by_id = {e.recipe_id: e for e in entries}

    for rid, direction in (("A", 1.0), ("B", -1.0)):
        e = by_id[rid]
        # Precondition (non-vacuous if constants drift): the unclamped sum of
        # per-feature contributions must exceed the clamp for this input.
        # learned_contribution now reports the APPLIED (clamped) value, so the
        # raw sum comes from the per-feature list.
        raw = sum(ft["contribution"] for ft in e.learned_features)
        assert (
            abs(raw) > constants.GLOBAL_CLAMP
        ), f"{rid}: engineered evidence must exceed the clamp, got {raw}"
        shift = e.total_score - rule_scores[rid]
        assert abs(shift) <= constants.GLOBAL_CLAMP + 1e-9, (
            f"{rid}: applied learned shift {shift} violates the "
            f"GLOBAL_CLAMP = {constants.GLOBAL_CLAMP} bound (SPEC 2.2)"
        )
        assert abs(shift - direction * constants.GLOBAL_CLAMP) < 1e-6, (
            f"{rid}: shift {shift} is not clamped at "
            f"{direction * constants.GLOBAL_CLAMP}"
        )
    # With both shifts clamped symmetrically (A +8, B -8), totals stay
    # 20 points apart: the rule order survives.
    assert entries[0].recipe_id == "A"
    assert by_id["A"].total_score - by_id["B"].total_score > 0.0


def test_lab_constants_pin_spec_2_2_and_checker():
    """The lab's numeric dials must equal SPEC section 2.2's normative table,
    cross-read at test time from the repo's machine-checked copy
    (docs/spec/taste/contracts/check.py). PR #149 review, finding 4: a
    loosened cap (ingredient 4.0 -> 40.0) used to pass the whole suite,
    because the bounds test read its oracle from the same mutated constants
    and the parity fixture's evidence never saturates a cap. Literal
    assertions pin the spec values; the check.py parse catches the spec's
    own copy drifting out from under the lab."""
    import ast
    import re

    spec_literals = {
        # Transcribed from SPEC section 2.2 (normative constants table).
        "HALF_LIFE": {
            "cook_rating": 60.0,
            "cook_no_rating": 30.0,
            "saved": 45.0,
            "skipped": 14.0,
            "substitution": 45.0,
            "lechef": 45.0,
            "open": 7.0,
            "view": 7.0,
        },
        "STRENGTH": {
            "cook_rating": 1.0,
            "cook_no_rating": 0.3,
            "saved": 0.4,
            "skipped": 0.2,
            "substitution": 0.5,
            "lechef": 0.4,
            "open": 0.15,
            "view": 0.08,
        },
        "CAP": {
            "ingredient": 4.0,
            "cuisine": 3.0,
            "technique": 2.0,
            "time": 2.0,
            "nutrient": 2.0,
            "spice": 2.0,
            "tool": 1.0,
            "other": 1.0,
        },
        "K_SHRINK": 3.0,
        "GLOBAL_CLAMP": 8.0,
        "PROFILE_MIN_DENOMINATOR": 3,
        "PROFILE_MIN_RATIO": 0.6,
        "STALE_AFTER_HALF_LIVES": 3.0,
    }
    for name, want in spec_literals.items():
        got = getattr(constants, name)
        assert got == want, (
            f"taste_lab.constants.{name} = {got!r} but SPEC section 2.2 "
            f"pins {want!r} — if the spec changed deliberately, update both "
            f"it and this test together"
        )

    checker = os.path.join(REPO_ROOT, "docs", "spec", "taste", "contracts", "check.py")
    with open(checker) as f:
        src = f.read()
    parsed = {}
    for name in ("HALF_LIFE", "STRENGTH", "CAP"):
        m = re.search(rf"^{name} = (\{{.*?\}})", src, re.S | re.M)
        assert m, f"could not find the {name} literal in {checker}"
        parsed[name] = ast.literal_eval(m.group(1))
    for name in ("K_SHRINK", "GLOBAL_CLAMP", "PROFILE_MIN_DENOMINATOR", "PROFILE_MIN_RATIO", "STALE_AFTER_HALF_LIVES"):
        m = re.search(rf"^{name} = ([0-9.]+)", src, re.M)
        assert m, f"could not find the {name} literal in {checker}"
        parsed[name] = ast.literal_eval(m.group(1))
    for name, want in parsed.items():
        assert constants.__dict__[name] == want, (
            f"taste_lab.constants.{name} disagrees with the machine-checked "
            f"copy in {os.path.relpath(checker, REPO_ROOT)}"
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
