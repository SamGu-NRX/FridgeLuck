#!/usr/bin/env python3
"""Generate the control-arm fixture for the Swift/Python bit-exact parity test.

Runs ref_impl.py (the verification-only Python mirror of the production scoring)
over the frozen matrix for every profile and writes
SwiftReplay/Tests/ReplayTests/fixtures/python_control.json.

The Swift ReplayTests then recompute the same control arm through the VENDORED
production Swift code and assert bit-exact equality (rank order, Int ratings,
explanation strings, and rankingScore as raw IEEE-754 bit patterns).

Usage: python3 make_control_fixture.py
"""

import hashlib
import json
import math
import pathlib
import struct
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import ref_impl  # noqa: E402


def main() -> int:
    matrix_path = here / "inputs" / "frozen_matrix.json"
    matrix = json.loads(matrix_path.read_text(encoding="utf-8"))

    out = {
        "note": (
            "Control-arm fixture produced by ref_impl.py (Python mirror of production "
            "scoring at base " + matrix["base_commit"] + ") for bit-exact cross-language "
            "comparison with the vendored Swift replay."
        ),
        "matrix_sha256": hashlib.sha256(matrix_path.read_bytes()).hexdigest(),
        "profiles": {},
    }

    for p in matrix["profiles"]:
        prof = ref_impl.Profile(
            goal=p["goal"],
            daily_calories=p["daily_calories"],
            protein_pct=p["protein_pct"],
            carbs_pct=p["carbs_pct"],
            fat_pct=p["fat_pct"],
        )
        rows = []
        for r in matrix["recipes"]:
            m = r["macros_per_serving"]
            macros = ref_impl.Macros(
                calories=m["calories"],
                protein=m["protein_g"],
                carbs=m["carbs_g"],
                fat=m["fat_g"],
                fiber=m["fiber_g"],
                sugar=m["sugar_g"],
                sodium=m["sodium_mg"],
            )
            ri = ref_impl.RankingInputs(
                time_minutes=r["time_minutes"],
                tags=tuple(r["tags"]),
                matched_required=r["matched_required"],
                total_required=r["total_required"],
                matched_optional=r["matched_optional"],
                missing_required_count=r["missing_required_count"],
                personal_score=r["personal_score"],
            )
            ev = ref_impl.evaluate(macros, prof, ri)
            assert math.isfinite(ev["ranking_score"]), (p["id"], r["id"])
            bits = struct.unpack(">Q", struct.pack(">d", ev["ranking_score"]))[0]
            rows.append(
                {
                    "id": r["id"],
                    "rating": ev["rating"],
                    "label": ev["label"],
                    "reasoning": ev["reasoning"],
                    "ranking_score": ev["ranking_score"],
                    "ranking_score_bits": str(bits),
                    "ranking_reasons": ev["ranking_reasons"],
                    "missing": ev["missing"],
                    "time": ev["time"],
                }
            )
        ranked = ref_impl.rank_order(rows)
        for i, row in enumerate(ranked):
            row["rank"] = i + 1
        out["profiles"][p["id"]] = {"recipes": ranked}

    fixture_dir = here / "SwiftReplay" / "Tests" / "ReplayTests" / "fixtures"
    fixture_dir.mkdir(parents=True, exist_ok=True)
    target = fixture_dir / "python_control.json"
    target.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    n = sum(len(v["recipes"]) for v in out["profiles"].values())
    print(f"wrote {target} ({len(out['profiles'])} profiles, {n} records)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
