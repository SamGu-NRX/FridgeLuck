"""USDA FSIS safe minimum internal temperatures (pinned food-safety canon, PR #126).

Temperatures in degrees Fahrenheit, the units the FSIS charts and the corpus
safety blocks use. The bundle carries Celsius; the compiler converts.
"""

from __future__ import annotations

# class -> (min_temp_f, display name for the thermometer check)
FSIS_MIN_F = {
    "meat_poultry": (165, "poultry"),
    "meat_ground": (160, "ground meat"),
    "meat_whole_cut_pork": (145, "pork whole cut"),
    "meat_whole_cut_red": (145, "red meat whole cut"),
    "flesh_fish": (145, "fish"),
    "flesh_shellfish": (145, "shellfish"),
    "egg": (160, "egg dishes"),
    "leftovers": (165, "leftovers"),
}


def f_to_c(f: float) -> float:
    return round((f - 32.0) * 5.0 / 9.0, 1)


def source_citation(cls: str) -> str:
    min_f, _ = FSIS_MIN_F[cls]
    return f"usda-fsis: {cls} {min_f} F"


def meets_endpoint(cls: str, endpoint_c: float) -> bool:
    min_f, _ = FSIS_MIN_F[cls]
    return endpoint_c + 1e-9 >= f_to_c(min_f)
