"""Grounded pantry manifest builder — suite A (pantry-truth).

Builds the audit's grounding inputs from data that exists in the repo:

- The production bundled corpus `apps/ios/Resources/data.json` (loaded by the
  app's BundledDataLoader): 50 catalog ingredients and 166 recipes, each
  recipe line carrying a gram quantity for the recipe's servings. This is the
  recipe corpus of record for the CURRENT app. (The scorecard task brief
  names `assets/recipes.json`; no such file exists on any branch of this
  repository — the production corpus actually shipped in the app is
  `apps/ios/Resources/data.json`, so that is what grounds the manifest. The
  substitution is recorded in every results payload and in evidence.md.)
- The USDA curated catalog `scripts/data/catalog/usda_curated_ingredients.json`
  (scripts/data tooling), used to ground ingredient identity: every catalog
  ingredient name is matched against USDA display/alternate names and the
  match statistics are recorded in the evidence.

Everything else is SYNTHETIC: pantry scenarios (lots, evidence classes,
staleness, plans) are generated with a fixed seed from the corpus demands so
quantities are coherent with real recipe lines. No personal data, no
credentials, no network.

Public surface used by suite.py:

    build_manifest(repo_root) -> dict          # raises MissingInput
   MissingInput                                # precise-reason exception
"""

from __future__ import annotations

import hashlib
import json
import random
import re
from datetime import datetime, timezone
from pathlib import Path

# Fixed seed for the whole suite (fixtures, scenario draws, sampling).
SEED = 20261011

# Pair-class mix adding up to exactly 200 audited pairs. Names are stable
# identifiers used in pairs_200.json and evidence.md.
PAIR_CLASSES = [
    ("full_coverage", 50),
    ("full_coverage_swap", 15),
    ("short_by_quantity", 40),
    ("observed_unknown", 30),
    ("estimated_quantity", 20),
    ("stale_evidence", 20),
    ("assumed_staple", 20),
    ("empty_pantry", 5),
]

STAPLE_NAMES = ("salt", "olive oil", "black pepper", "vegetable oil", "butter")

# Lots older than this many days carry stale evidence (needs reconfirming).
STALE_AFTER_DAYS = 14

# Plan battery sizes for the double-count audit.
PLAN_CURATED = 2
PLAN_RANDOM = 60


class MissingInput(Exception):
    """A named input file is missing or empty; the metric reports not-run."""


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_corpus(repo_root: Path) -> dict:
    """Load the production bundled corpus (the app's own data.json)."""
    path = repo_root / "apps" / "ios" / "Resources" / "data.json"
    if not path.is_file():
        raise MissingInput(
            "production corpus apps/ios/Resources/data.json is absent on this branch "
            "(the brief's assets/recipes.json does not exist anywhere in the repo); "
            "cannot ground the pantry manifest"
    )
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise MissingInput(f"production corpus data.json is not valid JSON: {exc}") from exc
    if not data.get("recipes"):
        raise MissingInput("production corpus data.json has no recipes")
    if not data.get("ingredients"):
        raise MissingInput("production corpus data.json has no ingredients")
    return data


def load_usda_catalog(repo_root: Path) -> dict | None:
    """Load the USDA curated catalog if present (grounding is auxiliary)."""
    path = repo_root / "scripts" / "data" / "catalog" / "usda_curated_ingredients.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def usda_grounding(ingredients: dict, usda: dict | None) -> dict:
    """Match corpus ingredient names against USDA display/alternate names."""
    if not usda:
        return {"present": False, "records": 0, "matched": 0, "total": len(ingredients)}
    records = usda.get("records", [])
    needles: list[tuple[str, dict]] = []
    for rec in records:
        names = [rec.get("display_name", "")]
        names.extend(rec.get("alt_names", []))
        for n in names:
            if n:
                needles.append((n.lower(), rec))
    matched = 0
    for ing in ingredients.values():
        name = ing["name"].lower()
        base = re.sub(r"[^a-z ]", "", name).strip()
        hit = any(
            (base in needle) or (needle in base)
            for needle, _rec in needles
            if len(needle) > 2 and len(base) > 2
        )
        if hit:
            matched += 1
    return {
        "present": True,
        "records": len(records),
        "matched": matched,
        "total": len(ingredients),
    }


def _lots_for_line(
    rng: random.Random,
    line_grams: float,
    evidence_class: str,
    days_back_limit: int = 30,
) -> dict:
    """One synthetic inventory lot for a recipe line, per evidence class."""
    lot = {
        "evidence_class": evidence_class,
        "quantity_grams": None,
        "remaining_grams": None,
        "quantity_is_estimate": 0,
        "source": None,
        "age_days": int(rng.uniform(0, days_back_limit)),
    }
    if evidence_class == "purchased_lot":
        cover = rng.uniform(1.2, 3.0)
        lot["quantity_grams"] = round(line_grams * cover, 1)
        lot["remaining_grams"] = lot["quantity_grams"]
        lot["source"] = "receipt"
    elif evidence_class == "purchased_lot_short":
        lot["quantity_grams"] = round(line_grams, 1)
        lot["remaining_grams"] = round(line_grams * rng.uniform(0.1, 0.6), 1)
        lot["source"] = "receipt"
    elif evidence_class == "observed_unknown":
        # A shelf scan saw the item and reconciled presence; no amount exists.
        # (SPEC 3.2: a scan observes — "Still 2 lemons?" — quantity stays unknown.)
        lot["remaining_grams"] = round(line_grams, 1)  # presence marker only
        lot["quantity_is_estimate"] = 1
        lot["source"] = "scan"
    elif evidence_class == "estimated_quantity":
        # A recognition-derived amount: recognition confidence, not quantity
        # confidence. Carries grams, but the grams are not evidence.
        lot["quantity_grams"] = round(line_grams * rng.uniform(0.2, 2.5), 1)
        lot["remaining_grams"] = lot["quantity_grams"]
        lot["quantity_is_estimate"] = 1
        lot["source"] = "scan"
    elif evidence_class == "stale_lot":
        lot["quantity_grams"] = round(line_grams * 2.0, 1)
        lot["remaining_grams"] = lot["quantity_grams"]
        lot["source"] = "receipt"
        lot["age_days"] = STALE_AFTER_DAYS + int(rng.uniform(1, 20))
    elif evidence_class == "assumed_staple":
        # No lot at all: a pantry assumption ("always keep on hand").
        pass
    else:
        raise ValueError(f"unknown evidence class {evidence_class}")
    return lot


def build_manifest(repo_root: Path) -> dict:
    """Build the grounded manifest: catalog, recipes, pantry scenarios, plans."""
    corpus = load_corpus(repo_root)
    usda = load_usda_catalog(repo_root)
    rng = random.Random(SEED)

    ingredients: dict[int, dict] = {}
    for key, arr in corpus["ingredients"].items():
        ingredients[int(key)] = {
            "id": int(key),
            "name": arr[0],
            "calories": arr[1],
            "protein": arr[2],
            "carbs": arr[3],
            "fat": arr[4],
            "typical_unit": arr[8],
            "storage_tip": arr[9],
        }

    recipes: dict[int, dict] = {}
    for arr in corpus["recipes"]:
        rid, title, time_minutes, servings, required, optional, instructions, tags = arr
        recipes[int(rid)] = {
            "id": int(rid),
            "title": title,
            "time_minutes": time_minutes,
            "servings": servings,
            "required": [{"ingredient_id": int(i), "grams": float(g)} for i, g in required],
            "optional": [{"ingredient_id": int(i), "grams": float(g)} for i, g in optional],
            "tags": tags,
        }

    usda_stats = usda_grounding(ingredients, usda)
    staple_ids = sorted(
        ing["id"] for ing in ingredients.values()
        if any(s in ing["name"].lower() for s in STAPLE_NAMES)
    )

    # ------------------------------------------------------------------
    # 200 audited (pantry, recipe) pairs, sampled deterministically.
    # Each pair: a pantry scenario over the recipe's required lines
    # (+ distractor lots), per the pair class.
    # ------------------------------------------------------------------
    pair_classes = [name for name, n in PAIR_CLASSES for _ in range(n)]
    rng.shuffle(pair_classes)
    recipe_ids = sorted(recipes)
    # Recipes with at least two required lines exercise multi-line ledgers.
    multi = [rid for rid in recipe_ids if len(recipes[rid]["required"]) >= 2]

    pairs = []
    for idx, klass in enumerate(pair_classes):
        rid = rng.choice(multi if klass in ("full_coverage_swap", "short_by_quantity") else recipe_ids)
        recipe = recipes[rid]
        pantry = {"lots": [], "assumptions": []}
        short_targets: set[int] = set()
        swap = None

        if klass == "full_coverage":
            evidence = ["purchased_lot"] * len(recipe["required"])
        elif klass == "full_coverage_swap":
            evidence = ["purchased_lot"] * len(recipe["required"])
            swap_line = rng.randrange(len(recipe["required"]))
            required_ids = {l["ingredient_id"] for l in recipe["required"]}
            substitutes = [i for i in sorted(ingredients) if i not in required_ids]
            swap = {
                "original_id": recipe["required"][swap_line]["ingredient_id"],
                "substitute_id": rng.choice(substitutes),
                "ratio": 1.0,
            }
            evidence[swap_line] = "absent_swapped_out"  # original absent from pantry
        elif klass == "short_by_quantity":
            k = 1 if len(recipe["required"]) < 3 else 2
            short_targets = set(rng.sample([l["ingredient_id"] for l in recipe["required"]], k))
            evidence = [
                "purchased_lot_short" if l["ingredient_id"] in short_targets else "purchased_lot"
                for l in recipe["required"]
            ]
        elif klass == "observed_unknown":
            k = 1 if len(recipe["required"]) < 3 else 2
            unknown_targets = set(rng.sample([l["ingredient_id"] for l in recipe["required"]], k))
            evidence = [
                "observed_unknown" if l["ingredient_id"] in unknown_targets else "purchased_lot"
                for l in recipe["required"]
            ]
        elif klass == "estimated_quantity":
            k = 1 if len(recipe["required"]) < 3 else 2
            est_targets = set(rng.sample([l["ingredient_id"] for l in recipe["required"]], k))
            evidence = [
                "estimated_quantity" if l["ingredient_id"] in est_targets else "purchased_lot"
                for l in recipe["required"]
            ]
        elif klass == "stale_evidence":
            k = 1 if len(recipe["required"]) < 3 else 2
            stale_targets = set(rng.sample([l["ingredient_id"] for l in recipe["required"]], k))
            evidence = [
                "stale_lot" if l["ingredient_id"] in stale_targets else "purchased_lot"
                for l in recipe["required"]
            ]
        elif klass == "assumed_staple":
            k = 1 if len(recipe["required"]) < 3 else 2
            staple_targets = set(rng.sample([l["ingredient_id"] for l in recipe["required"]], k))
            evidence = [
                "assumed_staple" if l["ingredient_id"] in staple_targets else "purchased_lot"
                for l in recipe["required"]
            ]
        elif klass == "empty_pantry":
            evidence = ["assumed_staple"] * len(recipe["required"])
            pantry["assumptions"] = []  # truly empty: no lots, no assumptions
        else:
            raise ValueError(f"unknown pair class {klass}")

        for line, ev in zip(recipe["required"], evidence):
            if ev == "absent_swapped_out":
                continue  # swapped out of the pantry; the accepted swap covers the line
            if ev == "assumed_staple":
                pantry["assumptions"].append(line["ingredient_id"])
                continue
            pantry["lots"].append(
                _lots_for_line(rng, line["grams"], ev, days_back_limit=rng.randint(1, 13))
                | {"ingredient_id": line["ingredient_id"]}
            )

        if klass == "empty_pantry":
            pantry["lots"] = []
            pantry["assumptions"] = []  # truly empty: no lots, no assumptions

        if swap is not None:
            # The accepted swap's substitute must be present with margin.
            original_grams = next(
                l["grams"] for l in recipe["required"]
                if l["ingredient_id"] == swap["original_id"]
            )
            pantry["lots"].append(
                _lots_for_line(
                    rng, original_grams * swap["ratio"], "purchased_lot",
                    days_back_limit=rng.randint(1, 13),
                )
                | {"ingredient_id": swap["substitute_id"]}
            )

        pairs.append(
            {
                "pair_id": f"P{idx + 1:03d}",
                "class": klass,
                "recipe_id": rid,
                "pantry": pantry,
                "swap": swap,
            }
        )

    # ------------------------------------------------------------------
    # Double-count plan battery (metric 1): curated + seeded random plans.
    # Each plan: several dinners (recipes) sharing scarce lots.
    # ------------------------------------------------------------------
    plans = []
    shared_pool = multi or recipe_ids

    def _shared_pair() -> tuple[int, int, int]:
        """Pick two recipes sharing at least one required ingredient; return
        (recipe_a, recipe_b, shared_ingredient_id)."""
        for _ in range(200):
            a, b = rng.sample(shared_pool, 2)
            common = (
                {l["ingredient_id"] for l in recipes[a]["required"]}
                & {l["ingredient_id"] for l in recipes[b]["required"]}
            )
            if common:
                return a, b, sorted(common)[0]
        raise MissingInput("corpus too small: no two recipes share an ingredient")

    # Curated probe 1: two dinners, one shared lot that cannot cover both.
    a, b, shared = _shared_pair()
    demand_a = next(l["grams"] for l in recipes[a]["required"] if l["ingredient_id"] == shared)
    demand_b = next(l["grams"] for l in recipes[b]["required"] if l["ingredient_id"] == shared)
    scarce = round((max(demand_a, demand_b) + (demand_a + demand_b)) / 2, 1)
    plans.append(
        {
            "plan_id": "PLAN-C1",
            "kind": "curated_scarce_shared_lot",
            "recipes": [a, b],
            "shared_lot": {"ingredient_id": shared, "remaining_grams": scarce},
            "expects_no_double_count": False,
        }
    )
    # Curated probe 2 (control): the same plan with a lot big enough for both.
    plans.append(
        {
            "plan_id": "PLAN-C2",
            "kind": "curated_sufficient_shared_lot",
            "recipes": [a, b],
            "shared_lot": {"ingredient_id": shared, "remaining_grams": round(demand_a + demand_b, 1)},
            "expects_no_double_count": True,
        }
    )
    # Seeded random plans: shared lots straddling total demand.
    for i in range(PLAN_RANDOM):
        a, b, shared = _shared_pair()
        d_a = next(l["grams"] for l in recipes[a]["required"] if l["ingredient_id"] == shared)
        d_b = next(l["grams"] for l in recipes[b]["required"] if l["ingredient_id"] == shared)
        remaining = round((d_a + d_b) * rng.uniform(0.4, 1.2), 1)
        plans.append(
            {
                "plan_id": f"PLAN-R{i + 1:03d}",
                "kind": "random_shared_lot",
                "recipes": [a, b],
                "shared_lot": {"ingredient_id": shared, "remaining_grams": remaining},
                "expects_no_double_count": remaining >= d_a + d_b,
            }
        )

    return {
        "suite": "pantry-truth",
        "seed": SEED,
        "generated_at": _iso_now(),
        "grounding": {
            "corpus_path": "apps/ios/Resources/data.json",
            "corpus_sha256": _sha256(repo_root / "apps" / "ios" / "Resources" / "data.json"),
            "note": (
                "The brief named assets/recipes.json; that file does not exist on any "
                "branch. The manifest is grounded on the production bundled corpus the "
                "app actually loads (apps/ios/Resources/data.json via BundledDataLoader)."
            ),
            "usda": usda_stats,
            "usda_path": "scripts/data/catalog/usda_curated_ingredients.json",
        },
        "ingredients": ingredients,
        "recipes": recipes,
        "_raw_corpus_recipes": corpus["recipes"],
        "staple_ids": staple_ids,
        "pairs": pairs,
        "plans": plans,
    }


def plan_pantries(manifest: dict) -> dict:
    """Deterministic pantries for the plan battery (probe job construction).

    For each plan: full-coverage purchased lots for every non-shared required
    line of both dinners (cover factor 2.0), plus the plan's single shared
    lot. The only contention is the shared ingredient, so any double-count
    finding is attributable to it.
    """
    out = {}
    for idx, plan in enumerate(manifest["plans"]):
        rng = random.Random(SEED + 7 * (idx + 1))
        shared_id = plan["shared_lot"]["ingredient_id"]
        # Combined demand per non-shared ingredient across both dinners, so
        # every non-shared line is genuinely covered and the shared
        # ingredient stays the only contention in the plan.
        demand: dict[int, float] = {}
        for rid in plan["recipes"]:
            for line in manifest["recipes"][rid]["required"]:
                if line["ingredient_id"] == shared_id:
                    continue
                demand[line["ingredient_id"]] = demand.get(line["ingredient_id"], 0.0) + float(line["grams"])
        lots = []
        for ing_id, total_demand in sorted(demand.items()):
            lot = _lots_for_line(rng, total_demand, "purchased_lot", days_back_limit=3)
            lot["remaining_grams"] = lot["quantity_grams"] = round(total_demand * 2.0, 1)
            lot["ingredient_id"] = ing_id
            lots.append(lot)
        shared = dict(plan["shared_lot"])
        shared.update({
            "evidence_class": "purchased_lot",
            "quantity_grams": shared["remaining_grams"],
            "quantity_is_estimate": 0,
            "source": "receipt",
            "age_days": 0,
        })
        lots.append(shared)
        available_ids = sorted(set(demand) | {shared_id})
        out[plan["plan_id"]] = {"lots": lots, "available_ids": available_ids}
    return out
