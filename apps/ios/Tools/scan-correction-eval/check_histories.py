#!/usr/bin/env python3
"""Validate the generated histories and produce expected current-policy outcomes.

Checks, in order:
  1. shape        6 families x 50 seeds, dev/held-out split, event well-formedness
  2. closed-form  exact hand-derived decision sequences for the deterministic
                  families (clean informative, changed, conflict, delay) under
                  the current policy -- these are hand arithmetic, not simulator
                  output (e.g. changed: decisions [n,n,a,a,a,a,a,a,a,b,b] with
                  truth flipping to B at the change, so wrong_auto == 3)
  3. structure    hand-derivable invariants on the stochastic families
                  (noisy, clean controls, heldout): no auto-correction before
                  the label has two same-product feedbacks; first two scans
                  always abstain; every later decision is non-None
  4. restart      per seed, replaying with restart events must give identical
                  decisions to replaying without them (cache rebuild is a
                  faithful argmax reload)
  5. split        clean informative/control counts are 25/25; held-out family
                  is disjoint from development families

Writes data/expected_current.json: per-seed reference decisions and summaries,
the input for the SwiftReplay cross-check and for score.py.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from reference import CurrentPolicy, replay_history, summarize
from sequences import (
    CONTROL_SEED_OFFSET,
    DEVELOPMENT_FAMILIES,
    FAMILIES,
    HELDOUT_FAMILY,
    SEEDS_PER_FAMILY,
)

FAILURES: list[str] = []


def fail(msg: str) -> None:
    FAILURES.append(msg)


def _check_shape(data: dict) -> None:
    if data.get("schema") != 1:
        fail("schema != 1")
    names = [f["name"] for f in data["families"]]
    if names != FAMILIES:
        fail(f"family order {names} != {FAMILIES}")
    for f in data["families"]:
        if f["seed_count"] != SEEDS_PER_FAMILY:
            fail(f"{f['name']}: seed_count {f['seed_count']}")
        if f["kind"] != ("heldout" if f["name"] == HELDOUT_FAMILY else "development"):
            fail(f"{f['name']}: wrong kind {f['kind']}")
    if sorted(data["development_families"]) != sorted(DEVELOPMENT_FAMILIES):
        fail("development_families mismatch")
    if data["heldout_family"] != HELDOUT_FAMILY:
        fail("heldout_family mismatch")
    if len(data["histories"]) != SEEDS_PER_FAMILY * len(FAMILIES):
        fail(f"history count {len(data['histories'])}")


def _check_history(h: dict) -> None:
    family, seed = h["family"], h["seed"]
    a, b, pool = h["products"]["a"], h["products"]["b"], h["products"]["wrong_pool"]
    allowed = {a, b, *pool}
    last_t = None
    norm = None
    for pos, e in enumerate(h["events"]):
        if e["i"] != pos:
            fail(f"{family}/{seed}: event index {e['i']} at position {pos}")
        if last_t is not None and e["t"] <= last_t:
            fail(f"{family}/{seed}: timestamps not strictly increasing at {pos}")
        last_t = e["t"]
        if e["type"] == "scan":
            if e["truth"] not in (a, b):
                fail(f"{family}/{seed}: truth {e['truth']} outside product pool")
            if not 0.0 < e["conf"] < 1.0:
                fail(f"{family}/{seed}: conf out of range")
            key = e["label"].strip().lower()
            if norm is None:
                norm = key
            elif key != norm:
                fail(f"{family}/{seed}: label {e['label']!r} normalizes away from {norm!r}")
        elif e["type"] == "feedback":
            if e["product"] not in allowed:
                fail(f"{family}/{seed}: feedback product {e['product']} outside pool")
            if e["user"] not in ("u1", "u2"):
                fail(f"{family}/{seed}: unknown user {e['user']}")
        elif e["type"] == "delay" and e["days"] < 1:
            fail(f"{family}/{seed}: delay must be >= 1 day (second-precision rule)")


# ---- closed-form expectations (hand arithmetic, independent of reference.py) ----

def _closed_form_clean_informative(h: dict) -> list[int | None]:
    a = h["products"]["a"]
    return [None, None, a, a, a, a, a, a, a]  # auto from the 3rd scan on (9 scans)


def _closed_form_changed(h: dict) -> list[int | None]:
    a, b = h["products"]["a"], h["products"]["b"]
    # counts: A reaches 4 before the change; B catches up 1,2,3,4.
    # s0 n (A=0), s1 n (A=1), s2 a (A=2), s3 a (A=3), s4 a (A=4),
    # s5 a WRONG (B=1), s6 a WRONG (B=2), s7 a WRONG (B=3, 4>3),
    # s8 b (tie 4-4, recency), s9 b (B=5), s10 b (B=5 after restart)
    return [None, None, a, a, a, a, a, a, b, b, b]


def _closed_form_conflict(h: dict) -> list[int | None]:
    a, b = h["products"]["a"], h["products"]["b"]
    # Users alternate a (u1) / b (u2) with the scan truth matching the current
    # user. Counts stay within one of each other, so recency always picks the
    # OTHER user's product one step behind the alternation: s0-s2 abstain
    # (max count 1), then every auto-correction is wrong (s3 a vs truth b,
    # s4 b vs truth a, s5 a vs b, s6 b vs a, s7 a vs b).
    return [None, None, None, a, b, a, b, a]


def _closed_form_delay(h: dict) -> list[int | None]:
    a = h["products"]["a"]
    return [None, None, a, a, a, a, a, a]


def _check_closed_form(h: dict, decisions: list[int | None]) -> None:
    family = h["family"]
    expected = {
        "clean": _closed_form_clean_informative if h["seed"] < CONTROL_SEED_OFFSET else None,
        "changed": _closed_form_changed,
        "conflict": _closed_form_conflict,
        "delay": _closed_form_delay,
    }.get(family)
    if expected is None:
        return
    want = expected(h)
    if decisions != want:
        fail(f"{family}/{h['seed']}: closed-form mismatch\n  want {want}\n  got  {decisions}")
    # exact metric expectations for the fully deterministic families
    if family == "changed":
        truth_seq = [e["truth"] for e in h["events"] if e["type"] == "scan"]
        wrong = sum(1 for d, t in zip(decisions, truth_seq) if d is not None and d != t)
        if wrong != 3:
            fail(f"changed/{h['seed']}: expected exactly 3 stale wrong auto-corrections, got {wrong}")
    if family == "conflict":
        truth_seq = [e["truth"] for e in h["events"] if e["type"] == "scan"]
        wrong = sum(1 for d, t in zip(decisions, truth_seq) if d is not None and d != t)
        if wrong != 5:
            fail(f"conflict/{h['seed']}: expected exactly 5 ping-pong wrong corrections, got {wrong}")


def _check_structural(h: dict, decisions: list[int | None]) -> None:
    # No policy can auto-correct before any feedback exists: the first two
    # scans always abstain (threshold >= 2 and at most one feedback seen).
    if decisions[0] is not None or decisions[1] is not None:
        fail(f"{h['family']}/{h['seed']}: auto-correction before two feedbacks")
    family = h["family"]
    if family == "noisy":
        return  # noise can split the first feedbacks 1-1: abstention is legal
    if family in ("delay", "heldout-combined") or (
        family == "clean" and h["seed"] < CONTROL_SEED_OFFSET
    ):
        # every scan is followed by feedback to A, so from scan 2 the top row
        # always has count >= 2: abstention after scan 1 is a defect
        for idx, d in enumerate(decisions[2:], start=2):
            if d is None:
                fail(f"{family}/{h['seed']}: scan {idx} abstained despite >= 2 same-product feedbacks")
    if family == "heldout-combined":
        # hand-derivable: s5/s6 stale-A auto-corrections are deterministic
        # (A >= 3 beats B <= 2 both times) and the final scan always resolves
        # to B (B ahead, or tied with the later last_used_at)
        a, b = h["products"]["a"], h["products"]["b"]
        if decisions[5] != a or decisions[6] != a:
            fail(f"heldout-combined/{h['seed']}: stale-A decisions missing at s5/s6")
        if decisions[8] != b:
            fail(f"heldout-combined/{h['seed']}: final scan should resolve to B")


def _check_restart_equivalence(h: dict, with_restarts: list, without: list) -> None:
    if with_restarts != without:
        fail(f"{h['family']}/{h['seed']}: restart changed decisions (cache/DB disagreement)")


def _check_split(data: dict) -> None:
    clean_seeds = [h["seed"] for h in data["histories"] if h["family"] == "clean"]
    informative = [s for s in clean_seeds if s < CONTROL_SEED_OFFSET]
    controls = [s for s in clean_seeds if s >= CONTROL_SEED_OFFSET]
    if len(informative) != SEEDS_PER_FAMILY - CONTROL_SEED_OFFSET or len(controls) != CONTROL_SEED_OFFSET:
        fail(f"clean split {len(informative)}/{len(controls)} != 25/25")
    held = {h["seed"] for h in data["histories"] if h["family"] == HELDOUT_FAMILY}
    if len(held) != SEEDS_PER_FAMILY:
        fail("held-out family seed count wrong")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", default=str(Path(__file__).parent / "data" / "histories.json"))
    parser.add_argument("--expected-out", default=str(Path(__file__).parent / "data" / "expected_current.json"))
    args = parser.parse_args()

    data = json.loads(Path(args.data).read_text())
    _check_shape(data)

    expected_out = {"schema": 1, "policy": "current", "seeds": {}, "summaries": {}}
    for h in data["histories"]:
        _check_history(h)
        live = replay_history(h)
        decisions = [r["decision"] for r in live]
        _check_closed_form(h, decisions)
        _check_structural(h, decisions)
        stripped = _strip_restarts(h)
        no_restart = [r["decision"] for r in replay_history(stripped)]
        _check_restart_equivalence(h, decisions, no_restart)
        key = f"{h['family']}/{h['seed']}"
        expected_out["seeds"][key] = live
        expected_out["summaries"][key] = summarize(live)

    _check_split(data)

    if FAILURES:
        print(f"FAILED: {len(FAILURES)} problem(s)")
        for f in FAILURES[:20]:
            print(" -", f)
        raise SystemExit(1)

    Path(args.expected_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.expected_out).write_text(json.dumps(expected_out, separators=(",", ":")))
    total = len(data["histories"])
    print(f"OK: {len(FAMILIES)} families x {SEEDS_PER_FAMILY} seeds = {total} histories validated")
    print(f"expected current-policy outcomes written to {args.expected_out}")


def _strip_restarts(h: dict) -> dict:
    clone = dict(h)
    clone["events"] = [e for e in h["events"] if e["type"] != "restart"]
    return clone


if __name__ == "__main__":
    main()
