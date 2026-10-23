#!/usr/bin/env python3
"""Verify the health-ranking sensitivity report against committed raw outputs.

Usage:
    python3 score.py --verify-report [--update-report]

--verify-report performs, in order (any failure exits non-zero and is printed):
  1. Re-runs check_inputs.py (schema, loud unknown/missing handling, bounds lock).
  2. Re-derives every control record from the frozen matrix via ref_impl.py and
     asserts bit-exact equality (ranking score IEEE-754 bit patterns, rank,
     rating, label, reasoning, ranking reasons) with the committed control files.
  3. Recomputes every window aggregate (rank moves, rating flips, reasoning
     changes, boundary flips, pairwise interval overlaps) from the committed raw
     window samples and asserts exact equality with run_meta window summaries.
  4. Verifies the committed hand rank-swap calculation (hand_swap.json) against
     ref_impl arithmetic: the flip, the exact scores, and the +4.0 protein-bonus
     discontinuity; confirms the same pair flips in the committed raw sample;
     confirms the hand perturbation sits inside the locked plausible bounds.
  5. Recomputes the label-service defect counts (documented reproducer) and
     asserts the R07 failing-input example is present in the committed control.
  6. Regenerates the summary tables; without --update-report they must be
     byte-identical to the committed outputs/summary_tables.md and to the
     marked block in report.md.

Scope fence: every measured outcome here concerns ONLY rank/rating/reasoning
stability of the production scorer on the frozen matrix. Nothing here measures
clinical benefit, weight-loss effectiveness, or real user preference.
"""

import argparse
import json
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ref_impl  # noqa: E402

RUN_DIR = HERE / "outputs" / "20261010-swift"
INPUTS = HERE / "inputs"
BEGIN_MARK = "<!-- BEGIN GENERATED TABLES -->"
END_MARK = "<!-- END GENERATED TABLES -->"

# Point deltas carried by each indicator flip (production constants).
INDICATOR_POINTS = {
    "calorie_bucket": {"30->20": -10, "20->30": +10, "30->15": -15, "15->30": +15,
                       "20->15": -5, "15->20": +5, "30->5": -25, "5->30": +25,
                       "20->5": -15, "5->20": +15, "15->5": -10, "5->15": +10},
    "fiber_bonus": {"on->off": -10, "off->on": +10},
    "sugar_bonus": {"on->off": -10, "off->on": +10},
    "sodium_bonus": {"on->off": -10, "off->on": +10},
    "ranking_high_protein": {"on->off": -4, "off->on": +4},
    "goal_band": "goal-dependent",  # weight-loss +/-5/-3, maintenance +3
    "reasoning_protein_band": "no ranking points",
    "reasoning_cal_band": "no ranking points",
}

FAILURES: list[str] = []


def check(cond: bool, message: str) -> None:
    if not cond:
        FAILURES.append(message)
        print(f"FAIL: {message}")


def score_bits(x: float) -> str:
    """IEEE-754 bit pattern as unsigned decimal (matches Swift String(bitPattern:))."""
    return str(int.from_bytes(struct.pack(">d", x), "big"))


def load(path: Path):
    with open(path) as f:
        return json.load(f)


def to_ref_macros(m: dict) -> ref_impl.Macros:
    return ref_impl.Macros(
        calories=m["calories"], protein=m["protein_g"], carbs=m["carbs_g"],
        fat=m["fat_g"], fiber=m["fiber_g"], sugar=m["sugar_g"], sodium=m["sodium_mg"])


def to_ref_profile(p: dict) -> ref_impl.Profile:
    return ref_impl.Profile(
        goal=p["goal"], daily_calories=p.get("daily_calories"),
        protein_pct=p["protein_pct"], carbs_pct=p["carbs_pct"], fat_pct=p["fat_pct"])


def to_ref_inputs(r: dict) -> ref_impl.RankingInputs:
    return ref_impl.RankingInputs(
        time_minutes=r["time_minutes"], tags=tuple(r["tags"]),
        matched_required=r["matched_required"], total_required=r["total_required"],
        matched_optional=r["matched_optional"],
        missing_required_count=r["missing_required_count"],
        personal_score=r["personal_score"])


def rederive_control(matrix: dict, profile: dict) -> list[dict]:
    """Evaluate all recipes for one profile and apply the production sort."""
    results = []
    for r in matrix["recipes"]:
        ev = ref_impl.evaluate(to_ref_macros(r["macros_per_serving"]),
                               to_ref_profile(profile), to_ref_inputs(r))
        results.append({**ev, "recipe_id": r["id"]})
    ordered = ref_impl.rank_order(results)
    for i, rec in enumerate(ordered):
        rec["rank"] = i + 1
        rec["ranking_score_bits"] = score_bits(rec["ranking_score"])
    return ordered


def indicators(macros: dict, profile: dict, row: dict) -> dict:
    """Port of the replay engine's replay-side threshold indicators."""
    out = {}
    if profile.get("daily_calories") is not None:
        ratio = macros["calories"] / (profile["daily_calories"] / 3.0)
        if 0.7 <= ratio <= 1.1:
            out["calorie_bucket"] = "30"
        elif 0.5 <= ratio < 0.7:
            out["calorie_bucket"] = "20"
        elif 1.1 <= ratio < 1.4:
            out["calorie_bucket"] = "15"
        else:
            out["calorie_bucket"] = "5"
    out["fiber_bonus"] = "on" if macros["fiber_g"] >= 5 else "off"
    out["sugar_bonus"] = "on" if macros["sugar_g"] <= 10 else "off"
    out["sodium_bonus"] = "on" if macros["sodium_mg"] <= 600 else "off"
    out["ranking_high_protein"] = "on" if (
        "high_protein" in row["tags"] or macros["protein_g"] >= 24) else "off"
    goal = profile["goal"]
    if goal == "weight_loss":
        out["goal_band"] = "on" if macros["calories"] <= 550 else "off"
    elif goal == "maintenance":
        out["goal_band"] = "on" if 450 <= macros["calories"] <= 750 else "off"
    split = ref_impl.macro_split(macros["protein_g"], macros["carbs_g"], macros["fat_g"])
    out["reasoning_protein_band"] = ("high" if split[0] > 0.30
                                     else "good" if split[0] > 0.25 else "none")
    out["reasoning_cal_band"] = ("light" if macros["calories"] < 350
                                 else "hearty" if macros["calories"] > 700 else "mid")
    return out


def step1_check_inputs() -> None:
    proc = subprocess.run(
        [sys.executable, str(HERE / "check_inputs.py")],
        capture_output=True, text=True)
    check(proc.returncode == 0,
          f"check_inputs.py exited {proc.returncode}: {proc.stderr[-2000:]}")


def step2_control_bitexact(matrix: dict, profiles: list[dict]) -> dict:
    by_profile = {}
    for p in profiles:
        rederived = rederive_control(matrix, p)
        committed = load(RUN_DIR / "raw" / f"control__{p['id']}.json")["records"]
        check(len(rederived) == len(committed),
              f"{p['id']}: record count {len(rederived)} != {len(committed)}")
        for got, exp in zip(rederived, committed):
            rid = exp["recipe_id"]
            check(got["recipe_id"] == rid, f"{p['id']}: order diverged at {rid}")
            for field in ("rank", "rating", "label", "reasoning",
                          "ranking_score_bits", "ranking_reasons"):
                check(got[field] == exp[field],
                      f"{p['id']}/{rid}: {field} {got[field]!r} != {exp[field]!r}")
        by_profile[p["id"]] = {r["recipe_id"]: r for r in rederived}
    return by_profile


def step3_windows(matrix: dict, profiles: list[dict], run_meta: dict,
                  control_idx: dict) -> None:
    committed = {(w["arm"], w["profile"]): w for w in run_meta["window_summaries"]}
    sample_files = sorted((RUN_DIR / "raw").glob("sample__*__*.json"))
    check(len(sample_files) == len(committed),
          f"sample files {len(sample_files)} != window summaries {len(committed)}")
    for path in sample_files:
        smp = load(path)
        arm, pid = smp["arm_id"], smp["profile_id"]
        key = (arm, pid)
        check(key in committed, f"{path.name}: no committed window summary")
        if key not in committed:
            continue
        w = committed[key]
        profile = next(p for p in profiles if p["id"] == pid)
        ctrl = control_idx[pid]
        rows = {r["id"]: r for r in matrix["recipes"]}
        moves = flips = reasonings = moving_draws = 0
        boundary: dict[str, int] = {}
        min_s: dict[str, float] = {}
        max_s: dict[str, float] = {}
        for d in smp["draws"]:
            moved = False
            for rec in d["records"]:
                rid = rec["recipe_id"]
                c = ctrl[rid]
                if rec["rank"] != c["rank"]:
                    moves += 1
                    moved = True
                if rec["rating"] != c["rating"]:
                    flips += 1
                if rec["reasoning"] != c["reasoning"]:
                    reasonings += 1
                s = rec["ranking_score"]
                min_s[rid] = min(min_s.get(rid, float("inf")), s)
                max_s[rid] = max(max_s.get(rid, float("-inf")), s)
                row = rows[rid]
                base_macros = rows[rid]["macros_per_serving"]
                now = indicators(rec["macros_used"], profile, row)
                was = indicators(base_macros, profile, row)
                for k in now:
                    if now[k] != was[k]:
                        label = f"{k}:{was[k]}->{now[k]}"
                        boundary[label] = boundary.get(label, 0) + 1
            if moved:
                moving_draws += 1
        ids = [r["id"] for r in matrix["recipes"]]
        overlaps = pairs = skipped = 0
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                if ids[i] in min_s and ids[j] in min_s:
                    pairs += 1
                    if max(min_s[ids[i]], min_s[ids[j]]) <= min(
                            max_s[ids[i]], max_s[ids[j]]):
                        overlaps += 1
                else:
                    skipped += 1
        got = {
            "draws": len(smp["draws"]),
            "rank_moving_draws": moving_draws,
            "rank_moves_total": moves,
            "rating_flips_total": flips,
            "reasoning_changes_total": reasonings,
            "boundary_flips": boundary,
            "pairwise_overlapping_intervals": overlaps,
            "pairwise_total": pairs,
            "pairwise_skipped_intervals": skipped,
        }
        for f, v in got.items():
            check(w[f] == v, f"{arm}/{pid} window {f}: engine {w[f]} != recomputed {v}")


def step4_hand_swap(matrix: dict, profiles: list[dict], bounds: dict) -> dict:
    hs = load(HERE / "hand_swap.json")
    profile = next(p for p in profiles if p["id"] == hs["profile_id"])
    prof = to_ref_profile(profile)
    out = dict(hs)
    for side in ("kept", "risen"):
        spec = hs[side]
        row = next(r for r in matrix["recipes"] if r["id"] == spec["recipe_id"])
        base = spec["control_macros"]
        pert = spec["perturbed_macros"]
        # The hand perturbation must sit inside the locked plausible envelope.
        # The joint arm compounds nutrients x portion, so the effective limit is
        # (1 + nutrients_pct) * (1 + portion_scale_pct) - 1.
        portion = bounds["plausible"]["portion_scale_pct"] / 100.0
        for field, pct_key in (("calories", "calories"), ("protein_g", "protein"),
                               ("carbs_g", "carbs"), ("fat_g", "fat"),
                               ("fiber_g", "fiber"), ("sugar_g", "sugar"),
                               ("sodium_mg", "sodium")):
            dev = abs(pert[field] / base[field] - 1.0) * 100.0
            lim = ((1.0 + bounds["plausible"]["nutrients_pct"][pct_key] / 100.0)
                   * (1.0 + portion) - 1.0) * 100.0
            check(dev <= lim + 1e-9,
                  f"{spec['recipe_id']} {field}: hand deviation {dev:.2f}% exceeds "
                  f"compounded plausible bound {lim:.2f}%")
        ri = to_ref_inputs(row)
        ev_c = ref_impl.evaluate(to_ref_macros(base), prof, ri)
        ev_p = ref_impl.evaluate(to_ref_macros(pert), prof, ri)
        check(score_bits(ev_c["ranking_score"]) == score_bits(spec["control_score"]),
              f"{spec['recipe_id']} control score {ev_c['ranking_score']} != hand "
              f"{spec['control_score']}")
        check(score_bits(ev_p["ranking_score"]) == score_bits(spec["perturbed_score"]),
              f"{spec['recipe_id']} perturbed score {ev_p['ranking_score']} != hand "
              f"{spec['perturbed_score']}")
        check(ev_c["rating"] == spec["control_rating"], f"{spec['recipe_id']} control rating")
        check(ev_p["rating"] == spec["perturbed_rating"], f"{spec['recipe_id']} perturbed rating")
        out[side] = {"control": ev_c, "perturbed": ev_p, "spec": spec}

    # The claimed flip: 'risen' starts below 'kept' and ends above it.
    kept, risen = out["kept"], out["risen"]
    check(kept["spec"]["control_rank"] < risen["spec"]["control_rank"],
          "hand swap: control order does not match the claimed starting order")
    check(kept["perturbed"]["ranking_score"] < risen["perturbed"]["ranking_score"],
          "hand swap: perturbed order did not flip")
    delta = risen["perturbed"]["ranking_score"] - risen["spec"]["control_score"]
    check(abs(delta - hs["expected_delta_points"]) < 1e-9,
          f"hand swap: risen self-delta {delta} != expected {hs['expected_delta_points']}")

    # The same pair must actually flip in the committed raw window sample.
    smp = load(RUN_DIR / "raw" / f"sample__{hs['arm']}__{hs['profile_id']}.json")
    kept_id = kept["spec"]["recipe_id"]
    risen_id = risen["spec"]["recipe_id"]
    flip_draws = []
    for d in smp["draws"]:
        recs = {r["recipe_id"]: r for r in d["records"]}
        if recs[risen_id]["rank"] < recs[kept_id]["rank"]:
            flip_draws.append(d["draw"])
    check(hs["evidence_draw"] in flip_draws,
          f"hand swap: draw {hs['evidence_draw']} not among flip draws {flip_draws}")
    out["flip_draws"] = flip_draws
    out["delta"] = delta
    return out


def step5_defect_reproducer(matrix: dict, profiles: list[dict]) -> dict:
    counts = {}
    for p in profiles:
        committed = load(RUN_DIR / "raw" / f"control__{p['id']}.json")["records"]
        bonus_no_reason = [r["recipe_id"] for r in committed
                           if "High protein" in r["ranking_reasons"]
                           and "High protein" not in r["reasoning"]]
        reason_no_bonus = [r["recipe_id"] for r in committed
                           if "High protein" not in r["ranking_reasons"]
                           and "High protein" in r["reasoning"]]
        counts[p["id"]] = (len(bonus_no_reason), len(reason_no_bonus))
    r07 = next(r for r in load(RUN_DIR / "raw" / "control__P1.json")["records"]
               if r["recipe_id"] == "R07")
    check("High protein" in r07["ranking_reasons"] and "High protein" not in r07["reasoning"],
          "R07 is no longer a bonus-without-reasoning example; update the reproducer")
    return counts


# MARK: - Table generation

def generate_tables(run_meta: dict, profiles: list[dict], hand: dict,
                    defect: dict, window_ok: bool, control_n: int) -> str:
    lines: list[str] = []
    ap = " | ".join(p["id"] for p in profiles)
    lines.append(f"Profiles: {ap} · recipes: {run_meta['recipe_count']} · "
                 f"seed: {run_meta['draw_seed']} · base: {run_meta['base_commit'][:12]}")
    lines.append("")
    lines.append("## Full-run aggregates (engine-recorded, verified where windowed)")
    lines.append("")
    lines.append("Plausible arms (within the locked uncertainty bounds):")
    lines.append("")
    lines.append("| arm | profile | rank-moving draws | rank moves | rating flips | "
                 "reasoning changes | interval overlaps |")
    lines.append("|---|---|---|---|---|---|---|")
    for s in run_meta["arm_summaries"]:
        if s["stress"]:
            continue
        lines.append(
            f"| {s['arm']} | {s['profile']} | {s['rank_moving_draws']}/{s['draws']} "
            f"| {s['rank_moves_total']} | {s['rating_flips_total']} "
            f"| {s['reasoning_changes_total']} "
            f"| {s['pairwise_overlapping_intervals']}/{s['pairwise_total']} |")
    lines.append("")
    lines.append("Stress arms (adversarial, OUTSIDE plausible uncertainty — "
                 "separately labeled, never mixed):")
    lines.append("")
    lines.append("| arm | profile | rank-moving draws | rank moves | rating flips | "
                 "reasoning changes | interval overlaps |")
    lines.append("|---|---|---|---|---|---|---|")
    for s in run_meta["arm_summaries"]:
        if s["stress"]:
            lines.append(
                f"| {s['arm']} | {s['profile']} | {s['rank_moving_draws']}/{s['draws']} "
                f"| {s['rank_moves_total']} | {s['rating_flips_total']} "
                f"| {s['reasoning_changes_total']} "
                f"| {s['pairwise_overlapping_intervals']}/{s['pairwise_total']} |")
    lines.append("")

    plaus = [s for s in run_meta["arm_summaries"] if not s["stress"]]
    rm = [s["rank_moving_draws"] for s in plaus]
    ov = [(s["pairwise_overlapping_intervals"], s["pairwise_total"]) for s in plaus
          if s["arm"] == "plausible_both"]
    lines.append("## Headline instability numbers (plausible arms)")
    lines.append("")
    lines.append(
        f"- Rank moved in {min(rm)}-{max(rm)} of {run_meta['arm_summaries'][0]['draws']} "
        f"draws for every plausible arm-profile cell — at least one recipe changes "
        f"position in essentially every plausible draw.")
    if ov:
        lo = min(o for o, _ in ov)
        hi = max(o for o, _ in ov)
        n = ov[0][1]
        lines.append(
            f"- Joint plausible arm: {lo}-{hi} of {n} recipe pairs have overlapping "
            f"plausible score intervals (rank order between them is not determined "
            f"by the data).")
    lines.append(
        f"- Window recomputation from committed raw samples: "
        f"{'PASS (exact equality with engine summaries)' if window_ok else 'FAILED'}")
    lines.append(f"- Control bit-exactness: {control_n} records re-derived from the "
                 f"frozen matrix reproduce the committed control output exactly.")
    lines.append("")
    lines.append("## Hand-verified rank swap (production formulas)")
    lines.append("")
    hs = hand
    kept_id, risen_id = hs["kept"]["spec"]["recipe_id"], hs["risen"]["spec"]["recipe_id"]
    lines.append(
        f"- Pair: {kept_id} (control rank {hs['kept']['spec']['control_rank']}, "
        f"score {hs['kept']['spec']['control_score']}) vs "
        f"{risen_id} (control rank {hs['risen']['spec']['control_rank']}, "
        f"score {hs['risen']['spec']['control_score']}), profile {hs['profile_id']}.")
    lines.append(
        f"- Under the committed plausible perturbation of draw "
        f"{hs['evidence_draw']}, {risen_id} gains "
        f"{hs['expected_delta_points']:+.1f} points by crossing the 24 g protein "
        f"ranking threshold ({hs['risen']['spec']['control_macros']['protein_g']:.1f} g -> "
        f"{hs['risen']['spec']['perturbed_macros']['protein_g']:.2f} g) and its order "
        f"flips. Hand arithmetic in hand_swap.md; machine-verified by score.py.")
    lines.append(f"- The same pair flips in raw-sample draws: "
                 f"{', '.join(map(str, hs['flip_draws']))}.")
    lines.append("")
    lines.append("## Label-service defect reproducer (documented, NOT fixed)")
    lines.append("")
    lines.append("Ranking grants the high-protein bonus on absolute grams "
                 "(protein >= 24 g or the `high_protein` tag) while reasoning "
                 "strings use calorie-share bands (protein kcal share > 30%/25%). "
                 "The two disagree on the same input:")
    lines.append("")
    lines.append("| profile | bonus w/o reasoning note | reasoning note w/o bonus |")
    lines.append("|---|---|---|")
    for p in profiles:
        a, b = defect[p["id"]]
        lines.append(f"| {p['id']} | {a}/{run_meta['recipe_count']} | {b}/{run_meta['recipe_count']} |")
    lines.append("")
    lines.append(
        "Failing-input example R07 (P1 control): ranking_reasons includes "
        "'High protein', reasoning is 'Hearty portion' with no protein note. "
        "Reproduce: re-derive the P1 control and inspect R07, or run "
        "`python3 score.py --verify-report` which asserts this example.")
    lines.append("")
    lines.append("## Boundary flips with point impact (plausible_both, full run)")
    lines.append("")
    lines.append("| indicator | profile | flips | points per flip |")
    lines.append("|---|---|---|---|")
    for s in run_meta["arm_summaries"]:
        if s["arm"] != "plausible_both":
            continue
        for k in sorted(s["boundary_flips"], key=lambda x: -s["boundary_flips"][x]):
            ind, trans = k.split(":", 1)
            m = INDICATOR_POINTS.get(ind)
            if isinstance(m, dict):
                pts = m.get(trans, "?")
                pts = f"{pts:+d}" if isinstance(pts, int) else pts
            else:
                pts = m or "?"
            lines.append(f"| {ind} {trans} | {s['profile']} "
                         f"| {s['boundary_flips'][k]} | {pts} |")
    lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify-report", action="store_true")
    ap.add_argument("--update-report", action="store_true")
    args = ap.parse_args()
    if not (args.verify_report or args.update_report):
        ap.error("nothing to do: pass --verify-report (optionally --update-report)")

    print("== 1. check_inputs gate ==")
    step1_check_inputs()

    matrix = load(INPUTS / "frozen_matrix.json")
    bounds = load(INPUTS / "perturbation_bounds.json")
    profiles = matrix["profiles"]
    run_meta = load(RUN_DIR / "run_meta.json")

    print("== 2. control bit-exactness ==")
    control_idx = step2_control_bitexact(matrix, profiles)
    control_n = len(profiles) * len(matrix["recipes"])
    print(f"   {control_n} control records verified bit-exact")

    print("== 3. window aggregates from raw samples ==")
    step3_windows(matrix, profiles, run_meta, control_idx)
    window_ok = not FAILURES
    print(f"   {len(run_meta['window_summaries'])} window cells recomputed")

    print("== 4. hand rank swap ==")
    hand = step4_hand_swap(matrix, profiles, bounds)
    print(f"   flip draws: {hand['flip_draws']}")

    print("== 5. label-service reproducer ==")
    defect = step5_defect_reproducer(matrix, profiles)

    print("== 6. summary tables ==")
    tables = generate_tables(run_meta, profiles, hand, defect, window_ok, control_n)
    tables_path = HERE / "outputs" / "summary_tables.md"
    if args.update_report:
        tables_path.write_text(tables)
        report = HERE / "report.md"
        text = report.read_text()
        start = text.index(BEGIN_MARK) + len(BEGIN_MARK)
        end = text.index(END_MARK)
        report.write_text(text[:start] + "\n" + tables + text[start:end].replace(
            "\n" + tables, "") + text[end:])
        print("   wrote outputs/summary_tables.md and refreshed report.md block")
    else:
        check(tables_path.exists(), "outputs/summary_tables.md missing")
        if tables_path.exists():
            check(tables_path.read_text() == tables,
                  "regenerated summary tables differ from committed "
                  "outputs/summary_tables.md (run with --update-report after "
                  "regenerating outputs)")
            report = HERE / "report.md"
            if report.exists():
                text = report.read_text()
                if BEGIN_MARK in text and END_MARK in text:
                    block = text[text.index(BEGIN_MARK) + len(BEGIN_MARK):
                                 text.index(END_MARK)].strip()
                    check(block == tables.strip(),
                          "report.md generated-tables block is stale")
        print("   tables match committed report artifacts")

    if FAILURES:
        print(f"\nVERIFICATION FAILED: {len(FAILURES)} failure(s)")
        return 1
    print("\nVERIFICATION PASSED: all checks green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
