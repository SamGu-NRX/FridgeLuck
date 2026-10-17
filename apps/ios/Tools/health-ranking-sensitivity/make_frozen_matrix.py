#!/usr/bin/env python3
"""Generate the frozen recipe/profile matrix for the health-ranking sensitivity study.

Deterministic: same Python version -> same bytes. The committed inputs/frozen_matrix.json
is the frozen artifact; this script is provenance for how the boundary values were derived.

Boundary double values are computed with the same operations the production Swift code
performs (e.g. mealTarget = dailyCalories / 3.0, ratio = cal / mealTarget) so that the
frozen recipes land exactly on (or just off) the production bucket boundaries in IEEE-754
double arithmetic.
"""

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "inputs" / "frozen_matrix.json"

BASE_COMMIT = "8c9c88f"


# ---------------------------------------------------------------------------
# Profiles. production: mealTarget = Double(dailyCalories) / 3.0
# ---------------------------------------------------------------------------

def make_profiles():
    return [
        {"id": "P1", "name": "general-2000", "goal": "general", "daily_calories": 2000,
         "protein_pct": 0.25, "carbs_pct": 0.45, "fat_pct": 0.30},
        {"id": "P2", "name": "weight-loss-1600", "goal": "weight_loss", "daily_calories": 1600,
         "protein_pct": 0.35, "carbs_pct": 0.35, "fat_pct": 0.30},
        {"id": "P3", "name": "muscle-gain-2500", "goal": "muscle_gain", "daily_calories": 2500,
         "protein_pct": 0.35, "carbs_pct": 0.40, "fat_pct": 0.25},
        {"id": "P4", "name": "maintenance-2200", "goal": "maintenance", "daily_calories": 2200,
         "protein_pct": 0.30, "carbs_pct": 0.40, "fat_pct": 0.30},
        {"id": "P5", "name": "general-no-target", "goal": "general", "daily_calories": None,
         "protein_pct": 0.25, "carbs_pct": 0.45, "fat_pct": 0.30},
    ]


def split_macros_for(cal, p_pct, c_pct, f_pct):
    """Grams P/C/F so that 4P+4C+9F == cal and the calorie split equals (p,c,f) pcts."""
    p = cal * p_pct / 4.0
    c = cal * c_pct / 4.0
    f = cal * f_pct / 9.0
    return p, c, f


def macro_pack(cal, p, c, f, fiber=3.0, sugar=8.0, sodium=400.0):
    return {
        "calories": cal, "protein_g": p, "carbs_g": c, "fat_g": f,
        "fiber_g": fiber, "sugar_g": sugar, "sodium_mg": sodium,
    }


def main():
    recipes = []

    def add(rid, purpose, cal, p, c, f, time_minutes, tags, matched, total, optional,
            missing=0, personal=0.0, fiber=3.0, sugar=8.0, sodium=400.0, notes=""):
        recipes.append({
            "id": rid,
            "title": rid,
            "purpose": purpose,
            "time_minutes": time_minutes,
            "tags": tags,
            "matched_required": matched,
            "total_required": total,
            "matched_optional": optional,
            "missing_required_count": missing,
            "personal_score": personal,
            "macros_per_serving": macro_pack(cal, p, c, f, fiber, sugar, sodium),
            "notes": notes,
        })

    meal_p1 = 2000.0 / 3.0  # matches Swift: Double(2000) / 3.0

    # --- Calorie-ratio bucket boundaries, exact and +-1% flanks, against P1 ---
    # Swift switch order: 0.7...1.1 -> 30, 0.5..<0.7 -> 20, 1.1..<1.4 -> 15, default 5.
    # Exactly 1.1 matches the FIRST case (30); exactly 1.4 falls to default (5).
    times = [15, 16, 30, 31, 20, 21, 35]  # covers <=15 (+6), <=30 (+3), >30 (0), 20/21 quick-cook reason
    idx = 0
    ratio_targets = [
        (0.5, "ratio-0.5 (bucket 20 edge: inclusive low end of 0.5..<0.7)"),
        (0.7, "ratio-0.7 (bucket 30 edge: inclusive low end of 0.7...1.1)"),
        (1.1, "ratio-1.1 (first-match-wins: 0.7...1.1 wins over 1.1..<1.4)"),
        (1.4, "ratio-1.4 (falls to default bucket 5: 1.4 not in 1.1..<1.4)"),
    ]
    for b, why in ratio_targets:
        for label, factor in [("below", 0.99), ("exact", 1.0), ("above", 1.01)]:
            idx += 1
            cal = b * meal_p1 * factor
            p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
            add(
                f"R{idx:02d}", f"P1 calorie-ratio {b} {label}: {why}",
                cal, p, c, f,
                time_minutes=times[idx % len(times)], tags=[],
                matched=3, total=3, optional=2,
                notes=f"ratio vs P1 mealTarget {b} {label}; macro split equals P1 profile split so the calorie bucket is the dominant mover",
            )

    # --- Weight-loss goal threshold (cal <= 550 -> +5 else -3) ---
    for i, cal in enumerate([549.0, 550.0, 551.0]):
        idx += 1
        label = {0: "below", 1: "exact", 2: "above"}[i]
        p, c, f = split_macros_for(cal, 0.35, 0.35, 0.30)
        add(
            f"R{idx:02d}", f"weightLoss calorie threshold 550 {label}",
            cal, p, c, f, time_minutes=20, tags=[],
            matched=4, total=4, optional=2,
            notes="goal weight_loss: score step +5.0 vs -3.0 at cal 550 (inclusive)",
        )

    # --- Maintenance goal thresholds (450 <= cal <= 750 -> +3) ---
    for i, cal in enumerate([449.0, 450.0, 451.0, 749.0, 750.0, 751.0]):
        idx += 1
        edge = "low" if cal < 600 else "high"
        label = {0: "below", 1: "exact", 2: "above"}[i % 3]
        p, c, f = split_macros_for(cal, 0.30, 0.40, 0.30)
        add(
            f"R{idx:02d}", f"maintenance calorie threshold {edge} edge {label}",
            cal, p, c, f, time_minutes=20, tags=[],
            matched=4, total=4, optional=2,
            notes="goal maintenance: +3.0 inside 450..750 inclusive, 0 outside",
        )

    # --- Bonus thresholds: fiber >= 5, sugar <= 10, sodium <= 600 (inclusive) ---
    for i, fiber in enumerate([4.9, 5.0, 5.1]):
        idx += 1
        label = {0: "below", 1: "exact", 2: "above"}[i]
        cal = 500.0
        p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
        add(
            f"R{idx:02d}", f"fiber bonus threshold 5g {label}",
            cal, p, c, f, time_minutes=20, tags=[], matched=3, total=3, optional=2,
            fiber=fiber, sugar=8.0, sodium=400.0,
            notes="production bonus uses fiber >= 5 (inclusive); reasoning 'Good fiber' shares the >= 5 threshold",
        )
    for i, sugar in enumerate([9.9, 10.0, 10.1]):
        idx += 1
        label = {0: "below", 1: "exact", 2: "above"}[i]
        cal = 500.0
        p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
        add(
            f"R{idx:02d}", f"sugar bonus threshold 10g {label}",
            cal, p, c, f, time_minutes=20, tags=[], matched=3, total=3, optional=2,
            fiber=3.0, sugar=sugar, sodium=400.0,
            notes="production bonus uses sugar <= 10 (inclusive); reasoning 'Higher sugar' fires only at > 15 (gap documented)",
        )
    for i, sodium in enumerate([590.0, 600.0, 610.0]):
        idx += 1
        label = {0: "below", 1: "exact", 2: "above"}[i]
        cal = 500.0
        p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
        add(
            f"R{idx:02d}", f"sodium bonus threshold 600mg {label}",
            cal, p, c, f, time_minutes=20, tags=[], matched=3, total=3, optional=2,
            fiber=3.0, sugar=8.0, sodium=sodium,
            notes="production bonus uses sodium <= 600 (inclusive); reasoning 'High sodium' only at > 800 (gap documented)",
        )

    # --- Reasoning-string thresholds that are NOT scoring thresholds ---
    for i, (cal, why) in enumerate([
        (349.0, "reasoning 'Light meal' fires at cal < 350 (exclusive)"),
        (351.0, "just above 'Light meal' edge"),
        (701.0, "reasoning 'Hearty portion' fires at cal > 700 (exclusive)"),
        (699.0, "just below 'Hearty portion' edge"),
    ]):
        idx += 1
        p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
        add(
            f"R{idx:02d}", why, cal, p, c, f, time_minutes=20, tags=[],
            matched=3, total=3, optional=2,
            notes=why,
        )
    for i, (sugar, why) in enumerate([
        (15.05, "reasoning 'Higher sugar' fires at sugar > 15 while the +10 bonus needs sugar <= 10: 10 < sugar <= 15 gets neither"),
        (12.0, "in the 10..15 gap: no bonus and no note"),
    ]):
        idx += 1
        cal = 500.0
        p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
        add(
            f"R{idx:02d}", why, cal, p, c, f, time_minutes=20, tags=[],
            matched=3, total=3, optional=2,
            fiber=3.0, sugar=sugar, sodium=400.0,
            notes=why,
        )
    idx += 1
    cal = 500.0
    p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
    add(
        f"R{idx:02d}", "reasoning 'High sodium' fires at sodium > 800 while the +10 bonus needs sodium <= 600",
        cal, p, c, f, time_minutes=20, tags=[], matched=3, total=3, optional=2,
        fiber=3.0, sugar=8.0, sodium=805.0,
        notes="600 < sodium <= 800: no bonus and no note",
    )

    # --- Protein 24g ranking threshold (+4 and 'High protein' reason, >= 24) ---
    for i, protein in enumerate([23.9, 24.0, 24.1]):
        idx += 1
        label = {0: "below", 1: "exact", 2: "above"}[i]
        cal = 600.0
        c = 0.50 * cal / 4.0
        f = 0.30 * cal / 9.0
        p = protein  # protein fixed at threshold; split floats slightly (documented)
        add(
            f"R{idx:02d}", f"protein 24g threshold {label} (+4.0 and 'High protein' reason, >= 24)",
            cal, p, c, f, time_minutes=20, tags=[],
            matched=4, total=4, optional=2,
            notes="ranking threshold protein >= 24 (sharedRankingScore +4.0 and rankingReasons 'High protein')",
        )

    # --- high-protein TAG path without protein >= 24, and both paths ---
    idx += 1
    cal = 550.0
    p, c, f = split_macros_for(cal, 0.25, 0.45, 0.30)
    p = 20.0
    add(
        f"R{idx:02d}", "high-protein TAG with protein 20 (< 24): tag alone gives +4.0 and the reason",
        cal, p, c, f, time_minutes=20, tags=["high_protein"],
        matched=4, total=4, optional=2,
        notes="tag OR protein >= 24 in production: tag-only path",
    )
    idx += 1
    cal = 550.0
    p, c, f = split_macros_for(cal, 0.30, 0.40, 0.30)
    p = 26.0
    add(
        f"R{idx:02d}", "high-protein tag AND protein 26 (both paths, still +4.0 once)",
        cal, p, c, f, time_minutes=20, tags=["high_protein"],
        matched=4, total=4, optional=2,
        notes="tag OR protein >= 24: additive guard - production adds 4.0 at most once",
    )

    # --- muscleGain thresholds: 'Fits your goal' at protein >= 25; cap min(protein/8, 8) ---
    for i, protein in enumerate([24.9, 25.0]):
        idx += 1
        label = {0: "below", 1: "exact"}[i]
        cal = 700.0
        c = 0.40 * cal / 4.0
        f = 0.25 * cal / 9.0
        add(
            f"R{idx:02d}", f"muscleGain reason threshold protein 25 {label}",
            cal, protein, c, f, time_minutes=20, tags=[],
            matched=4, total=4, optional=2,
            notes="rankingReasons muscleGain: protein >= 25 -> 'Fits your goal'",
        )
    for i, protein in enumerate([63.9, 64.0, 72.0]):
        idx += 1
        label = {0: "just-below-cap", 1: "cap-exact", 2: "over-cap"}[i]
        cal = 900.0
        c = 0.40 * cal / 4.0
        f = 0.25 * cal / 9.0
        add(
            f"R{idx:02d}", f"muscleGain protein/8 cap at 8.0 ({label})",
            cal, protein, c, f, time_minutes=20, tags=[],
            matched=4, total=4, optional=2,
            notes="sharedRankingScore muscleGain: min(protein/8.0, 8.0)",
        )

    # --- reasoning split thresholds: proteinPct just above/below 0.25 and 0.30 ---
    for i, (target, why) in enumerate([
        (0.2501, "split proteinPct just ABOVE 0.25 -> 'Good protein'"),
        (0.2499, "split proteinPct just BELOW 0.25 -> no protein note"),
        (0.3001, "split proteinPct just ABOVE 0.30 -> 'High protein'"),
        (0.2999, "split proteinPct just BELOW 0.30 -> at most 'Good protein'"),
    ]):
        idx += 1
        cal = 500.0
        p = target * cal / 4.0
        c = 0.45 * cal / 4.0
        f = (1.0 - target - 0.45) * cal / 9.0
        add(
            f"R{idx:02d}", why, cal, p, c, f, time_minutes=20, tags=[],
            matched=3, total=3, optional=2,
            notes=why + " (buildReasoning uses > 0.25 and > 0.30, exclusive)",
        )

    # --- Close-scoring tie pairs (weightLoss and maintenance) ---
    idx += 1
    cal_a = 542.0
    p_a, c_a, f_a = 40.0, 50.0, 15.0
    add(
        f"R{idx:02d}", "tie-pair-A1 (weightLoss): complete match, optional 2",
        cal_a, p_a, c_a, f_a, time_minutes=20, tags=[],
        matched=4, total=4, optional=2,
        notes="close-scoring partner of the next recipe under P2",
    )
    idx += 1
    add(
        f"R{idx:02d}", "tie-pair-A2 (weightLoss): complete match, optional 1",
        548.0, p_a, c_a, f_a, time_minutes=20, tags=[],
        matched=4, total=4, optional=1,
        notes="same macros as A1 but one fewer optional match: nominal gap 2.5 points",
    )
    idx += 1
    p_m, c_m, f_m = 35.0, 55.0, 12.0
    add(
        f"R{idx:02d}", "tie-pair-B1 (maintenance): optional 2",
        600.0, p_m, c_m, f_m, time_minutes=20, tags=[],
        matched=4, total=4, optional=2,
        notes="maintenance +3 (450 <= 600 <= 750); close to pair-B2",
    )
    idx += 1
    add(
        f"R{idx:02d}", "tie-pair-B2 (maintenance): optional 1, cal 602",
        602.0, p_m, c_m, f_m, time_minutes=20, tags=[],
        matched=4, total=4, optional=1,
        notes="nominal gap ~2.5 points vs B1",
    )

    # --- Macro-alignment floor (far from every profile split) ---
    idx += 1
    add(
        f"R{idx:02d}", "macro-split far from all profiles: macro alignment at the max(5, ...) floor",
        600.0, 5.0, 15.0, 40.0, time_minutes=20, tags=[],
        matched=3, total=3, optional=2,
        notes="split ~ (4.7%, 15.4%, 80.0% of cal): avgDiff large -> floor 5.0 points",
    )

    # --- macroSplit zero guard: P=C=F=0 with calories listed ---
    idx += 1
    add(
        f"R{idx:02d}", "P=C=F=0 (measured zeros): macroSplit guard returns (0.33, 0.33, 0.33)",
        400.0, 0.0, 0.0, 0.0, time_minutes=20, tags=[],
        matched=3, total=3, optional=2,
        fiber=0.0, sugar=0.0, sodium=0.0,
        notes="production guard: total macro calories 0 -> (0.33, 0.33, 0.33); zeros are real measured zeros, not missing",
    )

    # --- Zeros for fiber/sugar/sodium with a normal macro split ---
    idx += 1
    p, c, f = split_macros_for(500.0, 0.25, 0.45, 0.30)
    add(
        f"R{idx:02d}", "fiber=sugar=sodium=0 (real zeros): sugar and sodium bonuses fire, fiber does not",
        500.0, p, c, f, time_minutes=20, tags=[],
        matched=3, total=3, optional=2,
        fiber=0.0, sugar=0.0, sodium=0.0,
        notes="zeros treated as measured zeros: sugar 0 <= 10 bonus yes; fiber 0 >= 5 no; sodium 0 <= 600 yes",
    )

    # --- Listed calories disagree with 4P+4C+9F (realistic; fiber/rounding) ---
    idx += 1
    add(
        f"R{idx:02d}", "listed calories 500 but 4P+4C+9F = 560 (discrepant label)",
        500.0, 40.0, 60.0, 20.0, time_minutes=20, tags=[],
        matched=3, total=3, optional=2,
        notes="production uses listed caloriesPerServing for buckets/goal tests and P/C/F grams for split: the two can disagree; flagged for the label-defect review",
    )

    # --- Missing-required penalty path ---
    idx += 1
    p, c, f = split_macros_for(520.0, 0.30, 0.40, 0.30)
    add(
        f"R{idx:02d}", "one missing required ingredient: -24.0 penalty",
        520.0, p, c, f, time_minutes=20, tags=[],
        matched=2, total=3, optional=2, missing=1,
        notes="sharedRankingScore: -24.0 * missingRequiredCount",
    )

    # --- Personal score extremes ---
    for i, personal in enumerate([1.0, -1.0]):
        idx += 1
        p, c, f = split_macros_for(520.0, 0.30, 0.40, 0.30)
        add(
            f"R{idx:02d}", f"personal score extreme {'+' if personal > 0 else ''}{personal:.1f}",
            520.0, p, c, f, time_minutes=20, tags=[],
            matched=3, total=3, optional=2, personal=personal,
            notes="PersonalizationService documents personalScore range -1.0...+1.0; contribution = personal * 8.0",
        )

    profiles = make_profiles()

    claimed_coverage = [
        "calorie_ratio_boundary_0.5_exact_and_flanks_vs_P1",
        "calorie_ratio_boundary_0.7_exact_and_flanks_vs_P1",
        "calorie_ratio_boundary_1.1_exact_and_flanks_vs_P1",
        "calorie_ratio_boundary_1.4_exact_and_flanks_vs_P1",
        "weight_loss_550_exact_and_flanks",
        "maintenance_450_exact_and_flanks",
        "maintenance_750_exact_and_flanks",
        "fiber_5_exact_and_flanks",
        "sugar_10_exact_and_flanks",
        "sodium_600_exact_and_flanks",
        "reasoning_light_meal_350_flanks",
        "reasoning_hearty_700_flanks",
        "reasoning_sugar_15_and_gap",
        "reasoning_sodium_800_flank",
        "protein_24_exact_and_flanks",
        "high_protein_tag_only_path",
        "high_protein_tag_and_protein_paths",
        "muscle_gain_reason_25_exact_and_flank",
        "muscle_gain_cap_8_exact_and_over",
        "reasoning_split_0.25_flanks",
        "reasoning_split_0.30_flanks",
        "tie_pairs_weight_loss",
        "tie_pairs_maintenance",
        "macro_alignment_floor",
        "macro_split_zero_guard",
        "zero_fiber_sugar_sodium",
        "listed_calories_differ_from_4P4C9F",
        "missing_required_penalty",
        "personal_score_extremes",
        "time_cells_15_16_20_21_30_31",
        "profile_without_daily_calorie_target",
    ]

    matrix = {
        "schema_version": 1,
        "base_commit": BASE_COMMIT,
        "generated_by": "make_frozen_matrix.py (deterministic; committed alongside)",
        "frozen_at": "2026-10-10",
        "notes": [
            "Per-serving macros are inputs to the REPLAYED production scoring; the DB ingredient-sum path (NutritionService.macros(for:)) is upstream of computeScore and out of replay scope.",
            "Production macroSplit uses 4/4/9 kcal-per-gram; most recipes satisfy calories == 4P+4C+9F exactly by construction (one deliberate exception, flagged).",
            "Flanks are 1% off the boundary: far above any floating-point noise, far inside the perturbation bounds, so a perturbation draw can and does cross boundaries.",
        ],
        "claimed_coverage": claimed_coverage,
        "profiles": profiles,
        "recipes": recipes,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(matrix, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {OUT} with {len(recipes)} recipes, {len(profiles)} profiles")


if __name__ == "__main__":
    sys.exit(main())
