#!/usr/bin/env python3
"""Generate correction-drift sequence families for scan-correction-eval.

Six families x 50 seeds. Each seed is one history of events for a single
focal vision label:

  scan      Vision emitted the focal label; truth = correct product id now.
  feedback  A user recorded a correction label -> product (observed choice,
            which may disagree with truth).
  restart   A fresh LearningService is built from the database (cache reload).
  delay     A time gap before the next event (kept >= 1s so SQLite
            CURRENT_TIMESTAMP second precision cannot merge events).

Truth and feedback come from two independent named RNG streams
(`truth-<family>-<seed>` and `feedback-<family>-<seed>`); feedback choices are
therefore never derived from truth at generation time. The generator contains
no policy logic: expected decisions are computed separately by reference.py
and checked by check_histories.py.

Families (clean / noisy / changed / conflict / delay are DEVELOPMENT;
heldout-combined is the held-out scoring family and must not be used for
policy selection):

  clean      truth constant A; feedback always A. Plus null-control seeds
             (25..49) whose feedback is drawn with no signal, to baseline
             wrong auto-correction under the current policy.
  noisy      truth constant A; 15% of feedback is a mis-tap to a wrong
             product (noise positions from the feedback stream).
  changed    user's habitual product for the label changes mid-history
             (A before the change, B after); measures adaptation.
  conflict   two users with different preferences alternate corrections
             A / B on the same label; truth follows the most recent user.
  delay      like clean but with multi-day gaps and restarts interleaved.
  heldout-combined  noisy feedback + one product change + one restart;
             reserved for final scoring of the selected arm.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

FAMILIES = [
    "clean",
    "noisy",
    "changed",
    "conflict",
    "delay",
    "heldout-combined",
]
DEVELOPMENT_FAMILIES = FAMILIES[:5]
HELDOUT_FAMILY = "heldout-combined"
SEEDS_PER_FAMILY = 50
CONTROL_SEED_OFFSET = 25  # clean seeds >= 25 are null-feedback controls
INFORMATIVE_SEEDS = 25

BASE_TS = 1_700_000_000
DAY = 86_400


def _label_variants(truth_rng: random.Random, focal: str) -> list[str]:
    """Render the focal label with the casing/whitespace noise Vision shows."""
    variants = [
        focal,
        focal,
        f" {focal} ",
        focal.upper(),
        focal.lower(),
        focal.capitalize(),
    ]
    truth_rng.shuffle(variants)
    return variants


def _scan(t: int, i: int, truth: int, conf: float, label: str) -> dict:
    return {"i": i, "t": t, "type": "scan", "truth": truth, "conf": round(conf, 4), "label": label}


def _fb(t: int, i: int, product: int, user: str) -> dict:
    return {"i": i, "t": t, "type": "feedback", "product": product, "user": user}


def _restart(t: int, i: int) -> dict:
    return {"i": i, "t": t, "type": "restart"}


def _delay(t: int, i: int, days: int) -> dict:
    return {"i": i, "t": t, "type": "delay", "days": days}


class _Clock:
    def __init__(self, start: int):
        self.t = start

    def step(self, seconds: int = 5) -> int:
        self.t += seconds
        return self.t


def _feedback_product(feedback_rng: random.Random, truth: int, wrong_pool: list[int], p_wrong: float) -> int:
    if feedback_rng.random() < p_wrong:
        return feedback_rng.choice(wrong_pool)
    return truth


def _build(seed: int, family: str) -> dict:
    """One seed history. Structure is deterministic per family; the RNG
    streams only place noise, label renderings, ids and confidences."""
    truth_rng = random.Random(f"truth-{family}-{seed}")
    feedback_rng = random.Random(f"feedback-{family}-{seed}")

    a = 10 + (seed % 5)          # habitual / true product
    b = a + 5                    # competing product (change or second user)
    wrong_pool = [a + 10, a + 20]  # mis-tap targets, never a or b
    focal = ["Kombucha", "Tofu", "Harissa", "Couscous", "Miso"][seed % 5]

    clock = _Clock(BASE_TS + seed * 100_000)
    variants = _label_variants(truth_rng, focal)
    events: list[dict] = []
    i = 0

    def ev(e: dict) -> None:
        nonlocal i
        e["i"] = i
        events.append(e)
        i += 1

    def scan(truth: int) -> None:
        conf = 0.55 + truth_rng.random() * 0.4
        ev(_scan(clock.step(), i, truth, conf, variants[i % len(variants)]))

    def fb(product: int, user: str = "u1") -> None:
        ev(_fb(clock.step(), i, product, user))

    def restart() -> None:
        ev(_restart(clock.step(), i))

    def delay(days: int) -> None:
        ev(_delay(clock.step(days * DAY), i, days))

    if family == "clean":
        control = seed >= CONTROL_SEED_OFFSET
        truth = a
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)
        restart()
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)
        delay(3)
        restart()
        scan(truth)
        fb(a if not control else _feedback_product(feedback_rng, a, wrong_pool, 2 / 3))
        scan(truth)

    elif family == "noisy":
        truth = a
        for scan_idx in range(8):
            scan(truth)
            fb(_feedback_product(feedback_rng, a, wrong_pool, 0.15))
            if scan_idx == 3:
                restart()
        delay(2)

    elif family == "changed":
        # A is habitual before the change (truth A), B after (truth B); the
        # user keeps correcting B until B's count passes A's (5 > 4), then
        # the policy can recover. Stale A auto-corrections in between are
        # wrong by construction.
        for _ in range(3):
            scan(a)
            fb(a)
        scan(a)  # first eligible auto-correct, correct
        fb(a)
        scan(a)
        fb(b)  # change point: new habitual product, truth flips to B
        scan(b)  # stale A (4) still wins -> WRONG
        fb(b)
        scan(b)  # 4-2 -> WRONG
        fb(b)
        scan(b)  # 4-3 -> WRONG
        fb(b)
        scan(b)  # tie 4-4, recency tie-break -> B, correct again
        fb(b)
        scan(b)  # 5-4, stable
        restart()
        scan(b)
        delay(5)

    elif family == "conflict":
        truth = a  # updated below: truth follows the most recent user
        for scan_idx in range(8):
            user_is_u1 = scan_idx % 2 == 0
            product = a if user_is_u1 else b
            scan(product)  # truth = product of the most recent user
            fb(product, user="u1" if user_is_u1 else "u2")
            if scan_idx == 4:
                restart()
        delay(2)

    elif family == "delay":
        truth = a
        scan(truth)
        fb(a)
        delay(1)
        scan(truth)
        fb(a)
        delay(4)
        scan(truth)
        restart()
        fb(a)
        scan(truth)
        fb(a)
        scan(truth)
        delay(9)
        restart()
        scan(truth)
        fb(a)
        scan(truth)
        delay(15)
        scan(truth)

    elif family == "heldout-combined":
        truth = a
        # phase 1: learn A (deterministic)
        scan(truth)
        fb(a)
        scan(truth)
        fb(a)
        scan(truth)  # auto-correct A, correct
        # phase 2: noise creeps in (50% mis-tap on one event)
        scan(truth)
        fb(_feedback_product(feedback_rng, a, wrong_pool, 0.5))
        scan(truth)
        fb(a)
        # phase 3: habit change to B (truth flips), one restart mid-adaptation
        fb(b)
        scan(b)  # stale A (3 or 4) still wins -> WRONG, deterministic
        fb(b)
        restart()
        scan(b)  # A still >= B -> WRONG, deterministic
        fb(b)
        scan(b)  # tie or B ahead: recency/count decides, seed-dependent
        fb(b)
        scan(b)  # B ahead or recency tie -> correct
        delay(7)

    else:  # pragma: no cover
        raise ValueError(f"unknown family {family}")

    return {
        "family": family,
        "seed": seed,
        "focal": focal,
        "products": {"a": a, "b": b, "wrong_pool": wrong_pool},
        "events": events,
    }


def build_all() -> dict:
    families = []
    histories = []
    for family in FAMILIES:
        seeds = [build_all_seed(family, s) for s in range(SEEDS_PER_FAMILY)]
        families.append(
            {
                "name": family,
                "kind": "heldout" if family == HELDOUT_FAMILY else "development",
                "seed_count": SEEDS_PER_FAMILY,
                "event_counts": _event_counts(seeds),
            }
        )
        histories.extend(seeds)
    return {
        "schema": 1,
        "families": families,
        "development_families": DEVELOPMENT_FAMILIES,
        "heldout_family": HELDOUT_FAMILY,
        "histories": histories,
    }


def build_all_seed(family: str, seed: int) -> dict:
    return _build(seed, family)


def _event_counts(seeds: list[dict]) -> dict:
    counts = {"scan": 0, "feedback": 0, "restart": 0, "delay": 0}
    for s in seeds:
        for e in s["events"]:
            counts[e["type"]] += 1
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(Path(__file__).parent / "data" / "histories.json"))
    args = parser.parse_args()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    data = build_all()
    out.write_text(json.dumps(data, separators=(",", ":")))
    manifest = {f["name"]: {"kind": f["kind"], "seeds": f["seed_count"], **f["event_counts"]} for f in data["families"]}
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
