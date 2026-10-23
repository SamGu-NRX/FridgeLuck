"""Calibrator correctness on tiny hand-computed cases."""

from __future__ import annotations

from calibrators import isotonic_fit, isotonic_predict, logistic_fit, logistic_predict, pava


def test_pava_already_monotone():
    assert pava([0.0, 0.5, 1.0]) == [0.0, 0.5, 1.0]


def test_pava_violation_pools_blocks():
    # [0, 1, 0]: the 1/0 pair violates monotonicity -> pool to 0.5; the
    # leading 0 <= 0.5 is fine and stays separate. Cost 0.25+0.25 beats the
    # all-pooled 1/3 block's 0.667.
    assert pava([0.0, 1.0, 0.0]) == [0.0, 0.5, 0.5]


def test_pava_partial_pool():
    # [0.0, 1.0, 1.0, 0.0]: first pair pools to 0.5 (0<1 fine? 0 vs 1 is fine;
    # check: 0.0 <= 1.0 OK) — violations: 1.0 vs 0.0 at positions 1-2? sorted:
    # sequence 0,1,1,0. i=0: 0<=1 ok. i=1: 1<=1 ok. i=2: 1>0 pool [1,1,0]=2/3,
    # step back: 0 vs 2/3 ok. Result [0, 2/3, 2/3, 2/3].
    assert pava([0.0, 1.0, 1.0, 0.0]) == [0.0, 2 / 3, 2 / 3, 2 / 3]


def test_isotonic_predict_steps_and_edges():
    knots = isotonic_fit([0.1, 0.4, 0.7, 0.9], [0.0, 0.0, 1.0, 1.0])
    assert isotonic_predict(knots, 0.05) == 0.0  # below first knot -> floor
    assert isotonic_predict(knots, 0.4) == 0.0
    assert isotonic_predict(knots, 0.7) == 1.0
    assert isotonic_predict(knots, 0.99) == 1.0  # above last -> ceiling


def test_logistic_separates_toy_data():
    # Two well-separated clusters on one feature; fitted model must score the
    # high cluster above the low cluster and both near their class.
    X = [[0.0], [0.1], [0.9], [1.0]]
    y = [0.0, 0.0, 1.0, 1.0]
    model = logistic_fit(X, y, lam=0.01, iters=2000, lr=1.0)
    preds = logistic_predict(X, model)
    assert preds[0] < 0.2
    assert preds[3] > 0.8
    assert preds[3] > preds[0]


def test_logistic_l2_shrinks_toward_half():
    # With a strong penalty and no real signal, predictions stay near the
    # base rate. (lam=100 with this optimizer's 1/n penalty scaling and
    # lr=0.5 diverges — the penalty gradient coefficient lam/n*lr = 25
    # exceeds the stability bound; lam=10 at lr=0.1 is a stable
    # strong-shrinkage config.)
    X = [[0.2], [0.8]]
    y = [0.0, 1.0]
    model = logistic_fit(X, y, lam=10.0, iters=4000, lr=0.1)
    preds = logistic_predict(X, model)
    assert all(0.4 < p < 0.6 for p in preds)
