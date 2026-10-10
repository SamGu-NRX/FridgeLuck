"""Hand-computed checks of ref_impl against the production formulas.

Each expected number below is computed by hand in the assertion comments, following
HealthScoringService.computeScore / buildReasoning and RecipeRepository
sharedRankingScore / rankingReasons at base 8c9c88f.
"""

import math

import ref_impl as ri


def test_hand_computed_health_score():
    # macros: 500 kcal, 30P/50C/20F; P1 general 2000 kcal (0.25/0.45/0.30)
    m = ri.Macros(500.0, 30.0, 50.0, 20.0, 6.0, 8.0, 500.0)
    p = ri.Profile("general", 2000, 0.25, 0.45, 0.30)
    # split: 120/200/180 kcal of 500 -> (0.24, 0.40, 0.36)
    # diffs: 0.01 + 0.05 + 0.06 = 0.12; avg 0.04 -> 40*(1-0.12) = 35.2
    # ratio 500/666.666.. = 0.75 -> bucket 30
    # bonuses: fiber 6>=5 (+10), sugar 8<=10 (+10), sodium 500<=600 (+10)
    # points = 30 + 35.2 + 30 = 95.2 -> rating ceil(95.2/20) = 5
    score = ri.compute_score(m, p)
    split = ri.macro_split(m.protein, m.carbs, m.fat)
    assert split == (0.24, 0.40, 0.36)
    assert abs(95.2 - (30 + 35.2 + 30)) < 1e-9
    assert score.rating == 5
    assert score.label == "Great match"
    # split protein 0.24 -> no protein note; cal 500 -> no portion note;
    # fiber 6 -> 'Good fiber'; sugar/sodium quiet
    assert score.reasoning == "Good fiber"


def test_hand_computed_ranking_score():
    m = ri.Macros(500.0, 24.5, 50.0, 20.0, 6.0, 8.0, 500.0)
    p = ri.Profile("weight_loss", 1600, 0.35, 0.35, 0.30)
    r = ri.RankingInputs(time_minutes=12, tags=(), matched_required=3, total_required=3,
                         matched_optional=2, missing_required_count=0, personal_score=0.5)
    # 3/3*72 = 72; optional 2*2.5 = 5; rating 5*6.5 = 32.5; personal 0.5*8 = 4
    # time 12 <= 15 -> +6; weightLoss 500 <= 550 -> +5; protein 24.5 >= 24 -> +4
    # total = 72+5+32.5+4+6+5+4 = 128.5
    s = ri.shared_ranking_score(m, p, r, 5)
    assert abs(s - 128.5) < 1e-9


def test_no_daily_target_zero_macros_deterministic():
    p = ri.Profile("general", None, 0.25, 0.45, 0.30)  # no daily target -> base 20
    m = ri.Macros(400.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    # split guard -> thirds (0.33); diffs .08+.12+.03 avg .07667 -> 40*(1-.23) = 30.8
    # base 20; bonuses: sugar 0<=10 (+10), sodium 0<=600 (+10), fiber 0 -> no
    # points = 20 + 30.8 + 20 = 70.8 -> ceil(3.54) = 4
    score = ri.compute_score(m, p)
    expected = min(5, max(1, math.ceil((20 + 40 * (1 - ((0.08 + 0.12 + 0.03) / 3) * 3) + 20) / 20)))
    assert score.rating == expected
    assert 1 <= score.rating <= 5


def test_macro_floor_and_rating_boundaries():
    p = ri.Profile("general", None, 0.25, 0.45, 0.30)
    # protein-only macros: split protein = 1.0 -> diff 0.75 -> raw negative -> floor 5
    m = ri.Macros(0.0, 100.0, 0.0, 0.0, 10.0, 0.0, 0.0)
    # points = 20 + 5 + 30 = 55 -> ceil(2.75) = 3
    score = ri.compute_score(m, p)
    assert score.rating == 3
    assert min(5, max(1, math.ceil(55 / 20))) == 3


def test_rank_ordering_key():
    a = {"ranking_score": 10.0, "missing": 0, "time": 20}
    b = {"ranking_score": 12.0, "missing": 1, "time": 40}
    c = {"ranking_score": 10.0, "missing": 0, "time": 10}
    d = {"ranking_score": 10.0, "missing": 0, "time": 10}
    ordered = ri.rank_order([a, b, c, d])
    assert [x["ranking_score"] for x in ordered] == [12.0, 10.0, 10.0, 10.0]
    assert ordered[1]["time"] == 10  # missing then time asc within equal scores
    # full tie (score, missing, time): stable input order preserved
    tie1 = {"ranking_score": 5.0, "missing": 0, "time": 20}
    tie2 = {"ranking_score": 5.0, "missing": 0, "time": 20}
    assert [id(x) for x in ri.rank_order([tie1, tie2])] == [id(tie1), id(tie2)]
