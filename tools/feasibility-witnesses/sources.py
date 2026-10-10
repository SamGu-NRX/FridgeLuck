"""Source bundle for the feasibility witness verifier.

Loads the pinned feasibility fixtures and derives, from them alone, the
per-(state, recipe) ground truth that witness items must match.

Fixture layout (same row schemas as the pantry-feasibility owner's frozen
corpus, sliced):

  states.jsonl   one JSON object per line:
                 {state_id, family, pantry: [{ingredient_id, known_grams,
                  is_estimate}], available_ids, profile}
  catalog.json   {recipes: {"<recipe_id>": {title, time_minutes, tags,
                  required: [[ingredient_id, grams], ...],
                  optional: [[ingredient_id, grams], ...]}},
                 ingredient_names: {"<id>": name}, provenance: {...}}
  claims.jsonl   one JSON object per line — pinned output of the production
                 replay (RecipeRepository.findMakeable / findNearMatch):
                 {state_id, family, makeable_ids, near_match_ids}
  manifest.json  {"files": {"<fixture name>": sha256}, "parent": {...},
                  "selection_rule": str}

Revision identity is content-addressed. Every revision id is recomputed from
the fixture bytes at verification time, so a stale or forged binding cannot
verify against the sources it claims.

Data-model constants below (tag bits, diet masks, allergen-group memberships)
are transcribed from the production domain sources of truth
(Recipe.swift, HealthProfile.swift, AllergenGroupMembership.swift) — the same
transcription the pantry-feasibility owner's oracle.py carries. They are
DOMAIN constants, not this tool's claims.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

TAG_BITS = {
    "quick": 1 << 0,
    "vegetarian": 1 << 1,
    "vegan": 1 << 2,
    "asian": 1 << 3,
    "breakfast": 1 << 4,
    "budget": 1 << 5,
    "comfort": 1 << 6,
    "mediterranean": 1 << 7,
    "mexican": 1 << 8,
    "high_protein": 1 << 9,
    "low_carb": 1 << 10,
    "one_pot": 1 << 11,
}

DIET_TAG_MASK = {
    "vegan": TAG_BITS["vegan"],
    "vegetarian": TAG_BITS["vegetarian"],
    "keto": TAG_BITS["low_carb"],
    "pescatarian": 0,
    "": 0,
    None: 0,
}

DIET_EXCLUDED_IDS = {
    "vegan": {12, 13, 14, 32, 50},
    "vegetarian": set(),
    "keto": set(),
    "pescatarian": set(),
    "": set(),
    None: set(),
}

GROUP_IDS = {
    "milk",
    "egg",
    "peanut",
    "tree_nut",
    "wheat_gluten",
    "soy",
    "fish",
    "shellfish",
    "sesame",
    "mustard",
}

CORE_MEMBERSHIPS: dict[int, set[str]] = {
    1: {"egg"},
    2: set(),
    3: {"soy", "wheat_gluten"},
    4: set(),
    5: set(),
    6: set(),
    7: set(),
    8: set(),
    9: {"wheat_gluten"},
    10: set(),
    11: set(),
    12: {"milk"},
    13: {"milk"},
    14: {"milk"},
    15: {"wheat_gluten"},
    16: set(),
    17: set(),
    18: set(),
    19: set(),
    20: set(),
    21: set(),
    22: {"sesame"},
    23: {"soy"},
    24: set(),
    25: set(),
    26: set(),
    27: set(),
    28: {"wheat_gluten"},
    29: set(),
    30: set(),
    31: {"wheat_gluten"},
    32: {"milk"},
    33: set(),
    34: set(),
    35: set(),
    36: {"fish"},
    37: set(),
    38: set(),
    39: set(),
    40: set(),
    41: {"peanut"},
    42: set(),
    43: {"fish"},
    44: set(),
    45: set(),
    46: set(),
    47: set(),
    48: set(),
    49: {"tree_nut"},
    50: {"milk"},
}

GRAM_TOLERANCE = 1e-9


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(Path(path).read_bytes())


def states_prefix(states_sha256: str) -> str:
    return f"states:{states_sha256[:12]}"


def catalog_prefix(catalog_sha256: str) -> str:
    return f"catalog:{catalog_sha256[:12]}"


def inventory_revision_id(states_sha256: str, state_id: int) -> str:
    return f"{states_prefix(states_sha256)}:state={state_id}"


def profile_revision_id(states_sha256: str, state_id: int, apv: int) -> str:
    return f"profile:{states_sha256[:12]}:state={state_id}:apv={apv}"


def recipe_revision_id(catalog_sha256: str, recipe_id: int) -> str:
    return f"{catalog_prefix(catalog_sha256)}:recipe={recipe_id}"


def _read_jsonl(data: bytes) -> list[dict[str, Any]]:
    rows = []
    for line in data.decode("utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


class SourceError(Exception):
    """The pinned fixtures are missing, corrupt, or self-inconsistent."""


class SourceBundle:
    """The pinned fixtures, loadable and hash-checked, with derivation."""

    def __init__(self, fixture_dir: Path):
        self.dir = Path(fixture_dir)
        paths = {
            name: self.dir / name for name in ("states.jsonl", "catalog.json", "claims.jsonl")
        }
        for name, path in paths.items():
            if not path.is_file():
                raise SourceError(f"missing fixture: {path}")

        self.states_bytes = paths["states.jsonl"].read_bytes()
        self.catalog_bytes = paths["catalog.json"].read_bytes()
        self.claims_bytes = paths["claims.jsonl"].read_bytes()
        self.states_sha256 = sha256_bytes(self.states_bytes)
        self.catalog_sha256 = sha256_bytes(self.catalog_bytes)
        self.claims_sha256 = sha256_bytes(self.claims_bytes)

        manifest_path = self.dir / "manifest.json"
        if not manifest_path.is_file():
            raise SourceError(f"missing fixture manifest: {manifest_path}")
        self.manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        pinned = self.manifest.get("files", {})
        for name, digest in (
            ("states.jsonl", self.states_sha256),
            ("catalog.json", self.catalog_sha256),
            ("claims.jsonl", self.claims_sha256),
        ):
            if pinned.get(name) != digest:
                raise SourceError(
                    f"fixture {name} does not match manifest pin "
                    f"({digest} != {pinned.get(name)})"
                )

        self.states: dict[int, dict[str, Any]] = {}
        for row in _read_jsonl(self.states_bytes):
            state_id = row.get("state_id")
            if not isinstance(state_id, int) or state_id in self.states:
                raise SourceError(f"bad or duplicate state_id in states fixture: {state_id!r}")
            self.states[state_id] = row

        raw_catalog = json.loads(self.catalog_bytes.decode("utf-8"))
        self.catalog: dict[int, dict[str, Any]] = {}
        for rid, row in raw_catalog.get("recipes", {}).items():
            self.catalog[int(rid)] = dict(row, recipe_id=int(rid))
        self.ingredient_names: dict[int, str] = {
            int(k): v for k, v in raw_catalog.get("ingredient_names", {}).items()
        }

        self.claims: dict[int, dict[str, Any]] = {}
        for row in _read_jsonl(self.claims_bytes):
            state_id = row.get("state_id")
            if not isinstance(state_id, int) or state_id in self.claims:
                raise SourceError(f"bad or duplicate state_id in claims fixture: {state_id!r}")
            self.claims[state_id] = row

    def binding_sha256s(self) -> dict[str, str]:
        return {
            "states_sha256": self.states_sha256,
            "catalog_sha256": self.catalog_sha256,
            "claims_sha256": self.claims_sha256,
        }

    def effective_exclusions(self, profile: dict[str, Any]) -> dict[int, list[str]]:
        """Ingredient ID -> provenance strings for the effective exclusion set.

        Selected allergen-group members (unknown group strings are dropped,
        never honored) UNION individually excluded ingredient IDs UNION
        diet-excluded IDs.
        """
        groups = set(profile.get("allergen_groups") or [])
        groups = groups & GROUP_IDS
        via_group: dict[int, list[str]] = {}
        for ingredient_id, member_groups in CORE_MEMBERSHIPS.items():
            hit = sorted(member_groups & groups)
            if hit:
                via_group[ingredient_id] = [f"allergen_group:{g}" for g in hit]

        excluded: dict[int, list[str]] = {iid: list(v) for iid, v in via_group.items()}
        for iid in profile.get("allergen_ingredient_ids") or []:
            excluded.setdefault(int(iid), []).append("allergen_ingredient")
        diet = profile.get("diet")
        for iid in DIET_EXCLUDED_IDS.get(diet, set()):
            excluded.setdefault(iid, []).append(f"diet:{diet}")
        return {iid: sorted(v) for iid, v in sorted(excluded.items())}

    def required_tag_mask(self, profile: dict[str, Any]) -> int:
        return DIET_TAG_MASK.get(profile.get("diet"), 0)

    def pantry_totals(self, state: dict[str, Any]) -> dict[int, dict[str, Any]]:
        """ingredient_id -> {known_grams, is_estimate}.

        Any estimated lot makes the ingredient's amount unknown overall
        (presence-only); known lots still sum for reference. A known
        0-remaining lot contributes grams but does not remove presence —
        production's available set is what drops it, so a zero lot surfaces
        as a shortage with available 0 in this derivation.
        """
        totals: dict[int, dict[str, Any]] = {}
        for lot in state.get("pantry", []):
            iid = int(lot["ingredient_id"])
            entry = totals.setdefault(iid, {"known_grams": 0.0, "is_estimate": False})
            if lot.get("is_estimate") or lot.get("known_grams") is None:
                entry["is_estimate"] = True
            else:
                entry["known_grams"] += float(lot["known_grams"])
        return totals

    def raw_lots(self, state: dict[str, Any], ingredient_id: int) -> list[dict[str, Any]]:
        lots = [
            {
                "ingredient_id": int(lot["ingredient_id"]),
                "known_grams": lot.get("known_grams"),
                "is_estimate": bool(lot.get("is_estimate")),
            }
            for lot in state.get("pantry", [])
            if int(lot["ingredient_id"]) == ingredient_id
        ]
        return sorted(lots, key=lambda l: (l["known_grams"] is None, l["known_grams"] or 0.0))

    def derive_required(
        self, state: dict[str, Any], recipe: dict[str, Any]
    ) -> dict[int, dict[str, Any]]:
        """Ground truth for each required row, in data-model precedence:
        explicit_exclusion > absent > quantity_unknown > shortage >
        required_satisfied."""
        profile = state.get("profile", {})
        excluded = self.effective_exclusions(profile)
        totals = self.pantry_totals(state)
        out: dict[int, dict[str, Any]] = {}
        for ingredient_id, grams in recipe["required"]:
            grams = float(grams)
            if ingredient_id in excluded:
                out[ingredient_id] = {
                    "kind": "explicit_exclusion",
                    "required_grams": grams,
                    "excluded_via": excluded[ingredient_id],
                }
                continue
            entry = totals.get(ingredient_id)
            if entry is None:
                out[ingredient_id] = {"kind": "absent", "required_grams": grams}
                continue
            if entry["is_estimate"]:
                out[ingredient_id] = {
                    "kind": "quantity_unknown",
                    "required_grams": grams,
                    "basis_lots": self.raw_lots(state, ingredient_id),
                }
                continue
            if entry["known_grams"] + GRAM_TOLERANCE < grams:
                out[ingredient_id] = {
                    "kind": "shortage",
                    "required_grams": grams,
                    "available_grams": entry["known_grams"],
                    "basis_lots": self.raw_lots(state, ingredient_id),
                }
                continue
            out[ingredient_id] = {
                "kind": "required_satisfied",
                "required_grams": grams,
                "available_grams": entry["known_grams"],
                "basis_lots": self.raw_lots(state, ingredient_id),
            }
        return out

    def derive_optional(
        self, state: dict[str, Any], recipe: dict[str, Any]
    ) -> dict[int, dict[str, Any]]:
        """Ground truth for optional rows; never blocks, always typed apart."""
        profile = state.get("profile", {})
        excluded = self.effective_exclusions(profile)
        totals = self.pantry_totals(state)
        out: dict[int, dict[str, Any]] = {}
        for ingredient_id, _grams in recipe["optional"]:
            if ingredient_id in excluded:
                out[ingredient_id] = {
                    "kind": "optional_excluded",
                    "excluded_via": excluded[ingredient_id],
                }
                continue
            entry = totals.get(ingredient_id)
            if entry is None:
                out[ingredient_id] = {"kind": "optional_absent"}
                continue
            if entry["is_estimate"]:
                out[ingredient_id] = {
                    "kind": "optional_unknown",
                    "basis_lots": self.raw_lots(state, ingredient_id),
                }
                continue
            if entry["known_grams"] > 0:
                out[ingredient_id] = {
                    "kind": "optional_present",
                    "available_grams": entry["known_grams"],
                    "basis_lots": self.raw_lots(state, ingredient_id),
                }
                continue
            out[ingredient_id] = {"kind": "optional_absent"}
        return out

    def tag_violation(self, state: dict[str, Any], recipe: dict[str, Any]) -> bool:
        mask = self.required_tag_mask(state.get("profile", {}))
        return int(recipe["tags"]) & mask != mask

    def derive_all(self, state_id: int, recipe_id: int) -> dict[str, Any]:
        """Full ground truth for one (state, recipe) pair."""
        state = self.states[state_id]
        recipe = self.catalog[recipe_id]
        required = self.derive_required(state, recipe)
        optional = self.derive_optional(state, recipe)
        return {
            "required": required,
            "optional": optional,
            "tag_violation": self.tag_violation(state, recipe),
            "missing_ids": sorted(
                iid for iid, w in required.items() if w["kind"] in ("absent", "shortage")
            ),
            "excluded_ids": sorted(
                iid for iid, w in required.items() if w["kind"] == "explicit_exclusion"
            ),
            "unknown_ids": sorted(
                iid for iid, w in required.items() if w["kind"] == "quantity_unknown"
            ),
            "satisfied_ids": sorted(
                iid
                for iid, w in required.items()
                if w["kind"] in ("required_satisfied", "quantity_unknown")
            ),
        }
