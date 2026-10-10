"""Matrix-coverage tests: every claimed coverage case exists in the frozen matrix
and behaves as the production formulas (via ref_impl) dictate at its boundary.

Exact thresholds confirmed against production at base 8c9c88f:
  ratio buckets [0.5,0.7)->20 [0.7,1.1]->30 [1.1,1.4)->15 else 5 (first-match;
  1.1 exact lands in 0.7...1.1, 1.4 exact falls to default 5)
  fiber>=5 / sugar<=10 / sodium<=600 each +10; rating ceil(points/20) clamp 1-5
  weightLoss cal<=550 +5 else -3; maintenance 450...750 +3; muscleGain protein/8 cap 8
  protein>=24 (or tag) +4; time <=15 +6 / <=30 +3; quick-cook reason at <=20
"""

import math

import pytest

import ref_impl as ri

BOUNDARY = {"R02": 0.5, "R05": 0.7, "R08": 1.1, "R11": 1.4}


@pytest.fixture()
def by_id(matrix):
    return {r["id"]: r for r in matrix["recipes"]}


@pytest.fixture()
def prof_by_id(matrix):
    return {p["id"]: p for p in matrix["profiles"]}


def macros_of(recipe):
    m = recipe["macros_per_serving"]
    return ri.Macros(m["calories"], m["protein_g"], m["carbs_g"], m["fat_g"],
                     m["fiber_g"], m["sugar_g"], m["sodium_mg"])


def profile_of(p):
    return ri.Profile(p["goal"], p["daily_calories"], p["protein_pct"],
                      p["carbs_pct"], p["fat_pct"])


def ranking_inputs_of(recipe):
    return ri.RankingInputs(recipe["time_minutes"], tuple(recipe["tags"]),
                            recipe["matched_required"], recipe["total_required"],
                            recipe["matched_optional"], recipe["missing_required_count"],
                            recipe["personal_score"])


def ratio_vs_p1(recipe, prof_by_id):
    p1 = prof_by_id["P1"]
    daily = p1["daily_calories"] if isinstance(p1, dict) else p1.daily_calories
    return recipe["macros_per_serving"]["calories"] / (daily / 3.0)


def expected_bucket(ratio):
    """Production first-match chain: returns the calorie bucket points."""
    if 0.7 <= ratio <= 1.1:
        return 30
    if 0.5 <= ratio < 0.7:
        return 20
    if 1.1 <= ratio < 1.4:
        return 15
    return 5


# --- calorie ratio boundaries (claims 1-4) -----------------------------------

@pytest.mark.parametrize("exact_id,below_id,above_id,exact_bucket,below_bucket,above_bucket", [
    ("R02", "R01", "R03", 20, 5, 20),
    ("R05", "R04", "R06", 30, 20, 30),
    ("R08", "R07", "R09", 30, 30, 15),
    ("R11", "R10", "R12", 5, 15, 5),
])
def test_ratio_boundary(by_id, prof_by_id, exact_id, below_id, above_id,
                        exact_bucket, below_bucket, above_bucket):
    for rid, expected in ((exact_id, exact_bucket), (below_id, below_bucket),
                          (above_id, above_bucket)):
        ratio = ratio_vs_p1(by_id[rid], prof_by_id)
        assert expected_bucket(ratio) == expected, f"{rid} ratio {ratio}"
        if rid == exact_id:
            assert abs(ratio - BOUNDARY[rid]) < 1e-9, f"{rid} must sit exactly on the boundary"


# --- goal thresholds (claims 5-7) ---------------------------------------------

def test_weight_loss_550_flank(by_id, prof_by_id):
    p2 = profile_of(prof_by_id["P2"])

    def score(rid):
        r = by_id[rid]
        return ri.shared_ranking_score(macros_of(r), p2, ranking_inputs_of(r), 4)

    # 550 inclusive gets +5; 551 gets -3  => exact 8.0 point step
    assert abs(score("R14") - score("R15") - 8.0) < 1e-9
    assert score("R13") == pytest.approx(score("R14"), abs=0.15)  # 1 cal apart, same branch


def test_maintenance_edges(by_id, prof_by_id):
    p4 = profile_of(prof_by_id["P4"])

    def score(rid):
        r = by_id[rid]
        return ri.shared_ranking_score(macros_of(r), p4, ranking_inputs_of(r), 4)

    assert abs(score("R17") - score("R16") - 3.0) < 1e-9   # 449 -> +0, 450 -> +3
    assert abs(score("R20") - score("R21") - 3.0) < 1e-9   # 750 -> +3, 751 -> +0


# --- nutrient bonus thresholds (claims 8-10) ----------------------------------

def raw_points(recipe, profile):
    m = macros_of(recipe)
    split = ri.macro_split(m.protein, m.carbs, m.fat)
    diffs = [abs(split[0] - profile.protein_pct), abs(split[1] - profile.carbs_pct),
             abs(split[2] - profile.fat_pct)]
    avg = sum(diffs) / 3.0
    bucket = expected_bucket(m.calories / (profile.daily_calories / 3.0))
    bonus = (10 if m.fiber >= 5 else 0) + (10 if m.sugar <= 10 else 0) + \
        (10 if m.sodium <= 600 else 0)
    return bucket + max(5.0, 40 * (1.0 - avg * 3.0)) + bonus


def test_bonus_thresholds_are_inclusive(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])
    # production semantics: fiber >= 5 fires, sugar <= 10 fires, sodium <= 600 fires.
    # The no-bonus flank is therefore the fiber-low and sugar/sodium-high cases:
    # R23 (fiber 5.0) vs R22 (4.9); R26 (sugar 10.0) vs R27 (10.1); R29 (sodium 600) vs R30 (610).
    assert abs(raw_points(by_id["R23"], p1) - raw_points(by_id["R22"], p1) - 10.0) < 1e-9
    assert abs(raw_points(by_id["R26"], p1) - raw_points(by_id["R27"], p1) - 10.0) < 1e-9
    assert abs(raw_points(by_id["R29"], p1) - raw_points(by_id["R30"], p1) - 10.0) < 1e-9
    for no_bonus, fires in (("R22", "R23"), ("R27", "R26"), ("R30", "R29")):
        assert ri.compute_score(macros_of(by_id[fires]), p1).rating >= \
            ri.compute_score(macros_of(by_id[no_bonus]), p1).rating


# --- reasoning strings (claims 11-14, 19-20) -----------------------------------

def test_reasoning_edges(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])

    def reasoning(rid):
        return ri.compute_score(macros_of(by_id[rid]), p1).reasoning

    assert "Light meal" in reasoning("R31") and "Light meal" not in reasoning("R32")
    assert "Hearty portion" in reasoning("R33") and "Hearty portion" not in reasoning("R34")
    assert "Higher sugar" in reasoning("R35") and "Higher sugar" not in reasoning("R36")
    assert "High sodium" in reasoning("R37")
    assert "Good protein" in reasoning("R48") and "protein" not in reasoning("R49")
    assert "High protein" in reasoning("R50") and "High protein" not in reasoning("R51")


# --- protein 24 / tag paths (claims 15-17) -------------------------------------

def test_protein_24_threshold_and_tag(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])

    def score(rid):
        r = by_id[rid]
        return ri.shared_ranking_score(macros_of(r), p1, ranking_inputs_of(r), 4)

    assert abs(score("R39") - score("R38") - 4.0) < 1e-9
    # tag-only (R41, protein 20) still gets the +4 exactly once
    r41 = dict(by_id["R41"])
    no_tag = dict(r41, tags=[])
    s_with = ri.shared_ranking_score(macros_of(r41), p1, ranking_inputs_of(r41), 4)
    s_without = ri.shared_ranking_score(macros_of(r41), p1, ranking_inputs_of(no_tag), 4)
    assert abs(s_with - s_without - 4.0) < 1e-9
    # tag AND protein>=24: the OR-condition adds the +4 at most once. Removing the
    # tag leaves the protein path firing, so the score must not change.
    r42 = dict(by_id["R42"])
    no_tag42 = dict(r42, tags=[])
    s42_with = ri.shared_ranking_score(macros_of(r42), p1, ranking_inputs_of(r42), 4)
    s42_without = ri.shared_ranking_score(macros_of(r42), p1, ranking_inputs_of(no_tag42), 4)
    assert abs(s42_with - s42_without) < 1e-9
    reasons = ri.ranking_reasons(macros_of(r42), p1, ranking_inputs_of(r42), 4)
    assert reasons.count("High protein") == 1


# --- muscle gain (claim 18) ------------------------------------------------------

def test_muscle_gain_reason_and_cap(by_id, prof_by_id):
    p3 = profile_of(prof_by_id["P3"])
    general = ri.Profile("general", 2000, p3.protein_pct, p3.carbs_pct, p3.fat_pct)

    def goal_bonus(rid):
        r = by_id[rid]
        with_goal = ri.shared_ranking_score(macros_of(r), p3, ranking_inputs_of(r), 4)
        without = ri.shared_ranking_score(macros_of(r), general, ranking_inputs_of(r), 4)
        return with_goal - without

    assert abs(goal_bonus("R46") - 8.0) < 1e-9   # cap exact
    assert abs(goal_bonus("R47") - 8.0) < 1e-9   # over cap clamped
    assert 0 < goal_bonus("R45") < 8.0           # below cap
    reasons = ri.ranking_reasons(macros_of(by_id["R44"]), p3, ranking_inputs_of(by_id["R44"]), 4)
    assert "Fits your goal" in reasons
    reasons_low = ri.ranking_reasons(macros_of(by_id["R43"]), p3, ranking_inputs_of(by_id["R43"]), 4)
    assert "Fits your goal" not in reasons_low


# --- tie pairs (claims 21-22) ---------------------------------------------------

def test_tie_pairs_rank_is_ambiguous(by_id, prof_by_id, bounds):
    p2 = profile_of(prof_by_id["P2"])
    p4 = profile_of(prof_by_id["P4"])

    def score(rid, profile):
        r = by_id[rid]
        return ri.shared_ranking_score(macros_of(r), profile, ranking_inputs_of(r), 4)

    gap_wl = abs(score("R52", p2) - score("R53", p2))     # 2.5 (one optional)
    gap_maint = abs(score("R54", p4) - score("R55", p4))  # 2.5 (one optional)

    # Smallest possible ranking-score step from a rating flip is 6.5: both gaps are
    # below it, so a single rating flip reorders each pair.
    assert gap_wl < 6.5 and gap_maint < 6.5

    # Plausible calorie bound is 16.5%: R52/R53 sit at 542/548, so both can
    # independently cross the 550 weight-loss branch (max differential 8.0),
    # which covers the 2.5 nominal gap.
    cal_pct = bounds["plausible"]["nutrients_pct"]["calories"] / 100.0
    for rid in ("R52", "R53"):
        cal = by_id[rid]["macros_per_serving"]["calories"]
        assert abs(cal - 550.0) <= cal_pct * cal, f"{rid} within plausible noise of the 550 branch"
    assert gap_wl < 8.0

    # The maintenance pair is NOT reachable by the plausible calorie bound
    # (needs 148 cal at 602 vs 750; plausible shift is 99.4) but IS reachable by
    # the stress bound (35% -> 210.7): documented as stress-only instability.
    distance_to_band = 750.0 - by_id["R55"]["macros_per_serving"]["calories"]
    plausible_shift = cal_pct * by_id["R55"]["macros_per_serving"]["calories"]
    stress_shift = (bounds["stress"]["nutrients_pct"]["calories"] / 100.0) * \
        by_id["R55"]["macros_per_serving"]["calories"]
    assert distance_to_band > plausible_shift
    assert distance_to_band < stress_shift


# --- floor, zero guard, zeros (claims 23-25) ------------------------------------

def test_macro_alignment_floor(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])
    m = macros_of(by_id["R56"])
    split = ri.macro_split(m.protein, m.carbs, m.fat)
    avg = sum([abs(split[0] - p1.protein_pct), abs(split[1] - p1.carbs_pct),
               abs(split[2] - p1.fat_pct)]) / 3.0
    assert 40 * (1.0 - avg * 3.0) < 5.0  # raw contribution below floor
    assert max(5.0, 40 * (1.0 - avg * 3.0)) == 5.0  # floor engaged


def test_zero_guard_and_real_zeros(by_id, prof_by_id):
    assert ri.macro_split(0.0, 0.0, 0.0) == (0.33, 0.33, 0.33)
    p1 = profile_of(prof_by_id["P1"])
    result = ri.compute_score(macros_of(by_id["R57"]), p1)
    assert result.reasoning  # deterministic, non-empty
    m58 = macros_of(by_id["R58"])
    assert m58.fiber == 0.0 and m58.sugar == 0.0 and m58.sodium == 0.0


# --- label discrepancy, penalties, extremes, times (claims 26-30) ----------------

def test_listed_calories_are_what_production_uses(by_id, prof_by_id):
    r = by_id["R59"]
    m = r["macros_per_serving"]
    derived = 4 * m["protein_g"] + 4 * m["carbs_g"] + 9 * m["fat_g"]
    assert m["calories"] != derived, "R59 must keep the label discrepancy"
    ratio = m["calories"] / (2000 / 3.0)
    assert expected_bucket(ratio) == 30  # 500/666.67 = 0.75 -> bucket 30


def test_missing_required_penalty(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])
    r = by_id["R60"]
    with_missing = ri.shared_ranking_score(macros_of(r), p1, ranking_inputs_of(r), 4)
    # isolate the penalty term: ONLY missing_required_count changes, so the
    # matched-coverage term stays fixed and the diff is exactly -24.0
    clean = dict(r, missing_required_count=0)
    without = ri.shared_ranking_score(macros_of(clean), p1, ranking_inputs_of(clean), 4)
    assert abs(with_missing - without + 24.0) < 1e-9


def test_personal_score_extremes(by_id, prof_by_id):
    p1 = profile_of(prof_by_id["P1"])
    plus = ranking_inputs_of(by_id["R61"])
    minus = ranking_inputs_of(by_id["R62"])
    assert plus.personal_score == 1.0 and minus.personal_score == -1.0
    r = by_id["R61"]
    s_plus = ri.shared_ranking_score(macros_of(r), p1, plus, 4)
    s_minus = ri.shared_ranking_score(macros_of(r), p1, minus, 4)
    assert abs((s_plus - s_minus) - 16.0) < 1e-9  # 8.0 per unit


def test_time_cells(by_id):
    times = {r["time_minutes"] for r in by_id.values()}
    assert {15, 16, 20, 21, 30, 31}.issubset(times)

    def time_bonus(t):
        return 6.0 if t <= 15 else (3.0 if t <= 30 else 0.0)

    assert [time_bonus(t) for t in (15, 16, 20, 21, 30, 31)] == [6.0, 3.0, 3.0, 3.0, 3.0, 0.0]


# --- profile without daily target (claim 31) -------------------------------------

def test_profile_without_daily_target_uses_20_base(prof_by_id):
    p5 = profile_of(prof_by_id["P5"])
    assert p5.daily_calories is None
    m = ri.Macros(500.0, 30.0, 50.0, 20.0, 6.0, 8.0, 500.0)
    split = ri.macro_split(m.protein, m.carbs, m.fat)
    avg = sum([abs(split[0] - p5.protein_pct), abs(split[1] - p5.carbs_pct),
               abs(split[2] - p5.fat_pct)]) / 3.0
    expected_points = 20 + max(5.0, 40 * (1.0 - avg * 3.0)) + 30
    score = ri.compute_score(m, p5)
    assert score.rating == min(5, max(1, math.ceil(expected_points / 20.0)))


# --- matrix counts committed for the PR ------------------------------------------

def test_matrix_counts(matrix):
    assert len(matrix["recipes"]) == 62
    assert len(matrix["profiles"]) == 5
    assert len(matrix["claimed_coverage"]) == 31
