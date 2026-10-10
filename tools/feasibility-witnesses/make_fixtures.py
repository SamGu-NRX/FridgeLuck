#!/usr/bin/env python3
"""Regenerate the pinned feasibility fixtures and their manifest.

Deterministic: byte-identical output on every run (sorted keys, fixed
formatting), so manifest pins stay stable across regenerations.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
FIXTURES = TOOL_DIR / "fixtures"

STATES = [
    {
        "state_id": 1,
        "family": "solo_dinner",
        "pantry": [
            {"ingredient_id": 1, "known_grams": 300.0, "is_estimate": False},
            {"ingredient_id": 2, "known_grams": 500.0, "is_estimate": False},
            {"ingredient_id": 3, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 5, "known_grams": 350.0, "is_estimate": False},
            {"ingredient_id": 6, "known_grams": 60.0, "is_estimate": False},
            {"ingredient_id": 8, "known_grams": 50.0, "is_estimate": False},
            {"ingredient_id": 9, "known_grams": 400.0, "is_estimate": False},
            {"ingredient_id": 10, "known_grams": 80.0, "is_estimate": False},
            {"ingredient_id": 12, "known_grams": None, "is_estimate": True},
            {"ingredient_id": 14, "known_grams": 150.0, "is_estimate": False},
        ],
        "available_ids": [1, 2, 3, 5, 6, 8, 9, 10, 12, 14],
        "profile": {
            "diet": "",
            "allergen_groups": [],
            "allergen_ingredient_ids": [],
            "allergen_preferences_version": 1,
        },
    },
    {
        "state_id": 2,
        "family": "family_week",
        "pantry": [
            {"ingredient_id": 1, "known_grams": 200.0, "is_estimate": False},
            {"ingredient_id": 2, "known_grams": 400.0, "is_estimate": False},
            {"ingredient_id": 3, "known_grams": 30.0, "is_estimate": False},
            {"ingredient_id": 5, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 6, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 9, "known_grams": 350.0, "is_estimate": False},
            {"ingredient_id": 10, "known_grams": 60.0, "is_estimate": False},
            {"ingredient_id": 12, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 14, "known_grams": 150.0, "is_estimate": False},
            {"ingredient_id": 23, "known_grams": 50.0, "is_estimate": False},
            {"ingredient_id": 43, "known_grams": 450.0, "is_estimate": False},
        ],
        "available_ids": [1, 2, 3, 5, 6, 9, 10, 12, 14, 23, 43],
        "profile": {
            "diet": "",
            "allergen_groups": [],
            "allergen_ingredient_ids": [],
            "allergen_preferences_version": 1,
        },
    },
    {
        "state_id": 3,
        "family": "allergy_check",
        "pantry": [
            {"ingredient_id": 2, "known_grams": 600.0, "is_estimate": False},
            {"ingredient_id": 5, "known_grams": 400.0, "is_estimate": False},
            {"ingredient_id": 6, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 8, "known_grams": 30.0, "is_estimate": False},
            {"ingredient_id": 9, "known_grams": 500.0, "is_estimate": False},
            {"ingredient_id": 10, "known_grams": 100.0, "is_estimate": False},
            {"ingredient_id": 12, "known_grams": 120.0, "is_estimate": False},
            {"ingredient_id": 13, "known_grams": 40.0, "is_estimate": False},
            {"ingredient_id": 14, "known_grams": 150.0, "is_estimate": False},
            {"ingredient_id": 23, "known_grams": 80.0, "is_estimate": False},
            {"ingredient_id": 44, "known_grams": 10.0, "is_estimate": False},
        ],
        "available_ids": [2, 5, 6, 8, 9, 10, 12, 13, 14, 23, 44],
        "profile": {
            "diet": "",
            "allergen_groups": ["fish"],
            "allergen_ingredient_ids": [22],
            "allergen_preferences_version": 1,
        },
    },
    {
        "state_id": 4,
        "family": "no_claims_row",
        "pantry": [
            {"ingredient_id": 4, "known_grams": 500.0, "is_estimate": False},
            {"ingredient_id": 40, "known_grams": 300.0, "is_estimate": False},
        ],
        "available_ids": [4, 40],
        "profile": {
            "diet": "keto",
            "allergen_groups": [],
            "allergen_ingredient_ids": [],
            "allergen_preferences_version": 2,
        },
    },
]

CATALOG = {
    "recipes": {
        "101": {
            "title": "Weeknight Veggie Fried Rice",
            "time_minutes": 25,
            "tags": 1 | 2 | 8 | 32 | 2048,
            "required": [[2, 400], [1, 150], [3, 30], [10, 50]],
            "optional": [[22, 10], [7, 15]],
        },
        "102": {
            "title": "Creamy Tomato Penne",
            "time_minutes": 30,
            "tags": 64 | 2 | 2048,
            "required": [[9, 350], [14, 120], [12, 80], [5, 300], [6, 40]],
            "optional": [[8, 5], [13, 30]],
        },
        "103": {
            "title": "Miso Salmon Bowl",
            "time_minutes": 20,
            "tags": 1 | 8 | 512,
            "required": [[2, 300], [43, 200], [23, 25], [10, 30]],
            "optional": [[44, 5], [22, 5]],
        },
    },
    "ingredient_names": {
        "1": "eggs",
        "2": "rice",
        "3": "soy sauce",
        "4": "chicken breast",
        "5": "canned tomatoes",
        "6": "olive oil",
        "7": "frozen peas",
        "8": "garlic",
        "9": "penne",
        "10": "scallions",
        "12": "mozzarella",
        "13": "butter",
        "14": "parmesan",
        "22": "sesame seeds",
        "23": "miso paste",
        "40": "salmon (farmed)",
        "43": "salmon fillet",
        "44": "nori sheets",
    },
    "provenance": {
        "source": "pinned corpus (see manifest.parent)",
        "tag_bits": {
            "quick": 1,
            "vegetarian": 2,
            "vegan": 4,
            "asian": 8,
            "breakfast": 16,
            "budget": 32,
            "comfort": 64,
            "mediterranean": 128,
            "mexican": 256,
            "high_protein": 512,
            "low_carb": 1024,
            "one_pot": 2048,
        },
    },
}

CLAIMS = [
    {
        "state_id": 1,
        "family": "solo_dinner",
        "makeable_ids": [101, 102],
        "near_match_ids": [103],
    },
    {
        "state_id": 2,
        "family": "family_week",
        "makeable_ids": [101, 103],
        "near_match_ids": [102],
    },
    {
        "state_id": 3,
        "family": "allergy_check",
        "makeable_ids": [102],
        "near_match_ids": [101, 103],
    },
]

MANIFEST_PARENT = {
    "repo": "SamGu-NRX/FridgeLuck",
    "branch": "obv/fridgeluck-001",
    "base_commit": "c18ece18eaa3c769d55c3e2c29ca7d6e780d45e2",
    "claims_source_pr": 54,
    "claims_source_branch": "obv/fl-l2-pantry-feasibility",
}
SELECTION_RULE = (
    "4 states x 3 recipes; claims rows pinned for states 1-3 only (state 4 "
    "exercises claim_not_in_source); state 2 near_match_ids includes 103."
)


def _dump_jsonl(rows: list[dict]) -> bytes:
    return "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows).encode("utf-8")


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    states_bytes = _dump_jsonl(STATES)
    catalog_bytes = json.dumps(CATALOG, sort_keys=True, indent=1).encode("utf-8") + b"\n"
    claims_bytes = _dump_jsonl(CLAIMS)
    (FIXTURES / "states.jsonl").write_bytes(states_bytes)
    (FIXTURES / "catalog.json").write_bytes(catalog_bytes)
    (FIXTURES / "claims.jsonl").write_bytes(claims_bytes)
    manifest = {
        "files": {
            "states.jsonl": hashlib.sha256(states_bytes).hexdigest(),
            "catalog.json": hashlib.sha256(catalog_bytes).hexdigest(),
            "claims.jsonl": hashlib.sha256(claims_bytes).hexdigest(),
        },
        "parent": MANIFEST_PARENT,
        "selection_rule": SELECTION_RULE,
    }
    (FIXTURES / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print("fixtures written to", FIXTURES)


if __name__ == "__main__":
    main()
