#!/usr/bin/env python3
"""Generates the worked golden fixture and contract examples for docs/spec/taste.

The model math mirrors SPEC section 2.2 exactly. Every file is written in the
canonical serialization (sorted keys, 2-space indent, floats with exactly 6
fractional digits) that check.py enforces. Run from the repo root:
  python3 docs/spec/taste/contracts/gen_examples.py
"""
import json
import os
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.join(HERE, "examples")

# Model constants (SPEC 2.2)
H = {"cook_rating": 60.0, "cook_no_rating": 30.0, "saved": 45.0, "skipped": 14.0,
     "substitution": 45.0, "lechef": 45.0, "open": 7.0, "view": 7.0}
STRENGTH = {"cook_rating": 1.0, "cook_no_rating": 0.3, "saved": 0.4, "skipped": 0.2,
            "substitution": 0.5, "lechef": 0.4, "open": 0.15, "view": 0.08}
REWARD = {"saved": 0.75, "skipped": 0.15}
CAP = {"ingredient": 4.0, "cuisine": 3.0, "technique": 2.0, "time": 2.0,
       "nutrient": 2.0, "spice": 2.0, "tool": 1.0, "other": 1.0}
K_SHRINK = 3.0
GLOBAL_CLAMP = 8.0
PROFILE_MIN_DENOMINATOR = 3
PROFILE_MIN_RATIO = 0.6
STALE_AFTER_HALF_LIVES = 3.0


def from_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def decay(dt_days, half_life):
    return 2.0 ** (-dt_days / half_life)


class Ref:
    def __init__(self, rid):
        self.source = "catalog"
        self.id = rid
        self.revision = 1

    def d(self):
        return {"source": self.source, "id": self.id, "revision": self.revision}


R1, R2, R3, R4, R5 = Ref("1"), Ref("2"), Ref("3"), Ref("4"), Ref("5")

X1 = {
    "id": "1a2b3c4d-0001-4a00-8b00-000000000001",
    "at": "2026-09-01T17:58:00Z",
    "surface": "home.tonight",
    "eater": None,
    "sessionId": "sess-2026-09-01",
    "slate": [{"recipe": R1.d(), "position": 1}, {"recipe": R2.d(), "position": 2}],
    "feasible": [R1.d(), R2.d(), R3.d(), R4.d()],
    "context": {"kitchenIngredientCount": 6, "householdSize": 2, "mealContext": "weeknight"},
}
X2 = {
    "id": "1a2b3c4d-0002-4a00-8b00-000000000002",
    "at": "2026-09-21T17:55:00Z",
    "surface": "home.tonight",
    "eater": None,
    "sessionId": "sess-2026-09-21",
    "slate": [{"recipe": R3.d(), "position": 1}],
    "feasible": [R1.d(), R2.d(), R3.d(), R4.d()],
    "context": {"kitchenIngredientCount": 4, "householdSize": 2, "mealContext": "weeknight"},
}
X3 = {
    "id": "1a2b3c4d-0003-4a00-8b00-000000000003",
    "at": "2026-10-06T17:55:00Z",
    "surface": "home.tonight",
    "eater": None,
    "sessionId": "sess-2026-10-06",
    "slate": [{"recipe": R3.d(), "position": 1}],
    "feasible": [R3.d(), R4.d()],
    "context": {"kitchenIngredientCount": 3, "householdSize": 2, "mealContext": "weeknight"},
}
X4 = {
    "id": "1a2b3c4d-0004-4a00-8b00-000000000004",
    "at": "2026-10-13T17:55:00Z",
    "surface": "home.tonight",
    "eater": None,
    "sessionId": "sess-2026-10-13",
    "slate": [{"recipe": R5.d(), "position": 1}, {"recipe": R4.d(), "position": 2}],
    "feasible": [R1.d(), R2.d(), R3.d(), R4.d(), R5.d()],
    "context": {"kitchenIngredientCount": 5, "householdSize": 2, "mealContext": "weeknight"},
}
X5 = {
    "id": "1a2b3c4d-0005-4a00-8b00-000000000005",
    "at": "2026-10-15T17:55:00Z",
    "surface": "home.tonight",
    "eater": None,
    "sessionId": "sess-2026-10-15",
    "slate": [{"recipe": R3.d(), "position": 1}],
    "feasible": [R3.d(), R5.d()],
    "context": {"kitchenIngredientCount": 3, "householdSize": 2, "mealContext": "weeknight"},
}

E1 = {
    "id": "2b3c4d5e-0001-4b00-9c00-000000000001",
    "at": "2026-09-01T18:00:00Z",
    "kind": "recipe_cooked",
    "eater": "you",
    "recipe": R1.d(),
    "ingredient": None,
    "surface": "cook.complete",
    "payload": {"rating": 2, "wouldMakeAgain": None, "servings": 2,
                "exposureId": X1["id"], "slatePosition": 1, "cookSessionId": "cook-2026-09-01"},
}
E2 = {
    "id": "2b3c4d5e-0002-4b00-9c00-000000000002",
    "at": "2026-09-21T18:00:00Z",
    "kind": "recipe_cooked",
    "eater": "you",
    "recipe": R3.d(),
    "ingredient": None,
    "surface": "cook.complete",
    "payload": {"rating": 1, "wouldMakeAgain": None, "servings": 2,
                "exposureId": X2["id"], "slatePosition": 1, "cookSessionId": "cook-2026-09-21"},
}
E3 = {
    "id": "2b3c4d5e-0003-4b00-9c00-000000000003",
    "at": "2026-10-06T18:00:00Z",
    "kind": "recipe_cooked",
    "eater": "you",
    "recipe": R3.d(),
    "ingredient": None,
    "surface": "cook.complete",
    "payload": {"rating": 1, "wouldMakeAgain": None, "servings": 2,
                "exposureId": X3["id"], "slatePosition": 1, "cookSessionId": "cook-2026-10-06"},
}
# Unrated cook of the stir-fry, its later rating merging into the same cook's
# transaction window (cookEventId), a save from outside any slate, and a skip
# resolving against the slate that showed the recipe.
E4 = {
    "id": "2b3c4d5e-0004-4b00-9c00-000000000004",
    "at": "2026-10-13T18:00:00Z",
    "kind": "recipe_cooked",
    "eater": "you",
    "recipe": R5.d(),
    "ingredient": None,
    "surface": "cook.complete",
    "payload": {"rating": None, "wouldMakeAgain": None, "servings": 2,
                "exposureId": X4["id"], "slatePosition": 1, "cookSessionId": "cook-2026-10-13"},
}
E5 = {
    "id": "2b3c4d5e-0005-4b00-9c00-000000000005",
    "at": "2026-10-15T18:00:00Z",
    "kind": "recipe_rated",
    "eater": "you",
    "recipe": R5.d(),
    "ingredient": None,
    "surface": "cook.complete",
    "payload": {"rating": 3, "cookEventId": E4["id"]},
}
E6 = {
    "id": "2b3c4d5e-0006-4b00-9c00-000000000006",
    "at": "2026-10-14T09:00:00Z",
    "kind": "recipe_saved",
    "eater": "you",
    "recipe": R5.d(),
    "ingredient": None,
    "surface": "recipe.detail",
    "payload": {"exposureId": None},
}
E7 = {
    "id": "2b3c4d5e-0007-4b00-9c00-000000000007",
    "at": "2026-10-15T18:30:00Z",
    "kind": "recipe_skipped",
    "eater": "you",
    "recipe": R3.d(),
    "ingredient": None,
    "surface": "home.tonight",
    "payload": {"reason": "doesnt_appeal", "exposureId": X5["id"]},
}

CATALOG = [
    {"recipe": R1.d(), "features": ["ingredient:101", "cuisine:indian"], "ruleScore": 63.0, "timeMinutes": 30},
    {"recipe": R2.d(), "features": [], "ruleScore": 60.0, "timeMinutes": 25},
    {"recipe": R3.d(), "features": ["ingredient:101"], "ruleScore": 61.0, "timeMinutes": 15},
    {"recipe": R4.d(), "features": [], "ruleScore": 60.0, "timeMinutes": 20},
    {"recipe": R5.d(), "features": ["technique:stirfry"], "ruleScore": 59.0, "timeMinutes": 20},
]

FEATURE_NAMES = {
    "ingredient:101": "coriander",
    "cuisine:indian": "Indian food",
    "technique:stirfry": "stir-fries",
}

CATALOG_KIND = {"ingredient:101": "ingredient", "cuisine:indian": "cuisine",
                "technique:stirfry": "technique"}

PIN = {
    "id": "4d5e6f70-0004-4d00-9e00-000000000004",
    "layer": "pinned",
    "featureKind": "ingredient",
    "featureKey": "ingredient:101",
    "templateId": "pinned.dont_ask_again",
    "numerator": None,
    "denominator": None,
    "state": "active",
    "mutedUntil": None,
    "pinnedValue": -8.0,
    "lastEvidenceAt": None,
    "createdAt": "2026-10-15T09:00:00Z",
    "updatedAt": "2026-10-15T09:00:00Z",
    "text": "You asked not to see coriander-heavy recipes for now.",
}


def share_of(exp):
    return max(len(exp["slate"]) / len(exp["feasible"]), 0.15)


def exposure_by_id(exposures, exposure_id):
    if exposure_id is None:
        return None
    for e in exposures:
        if e["id"] == exposure_id:
            return e
    raise KeyError(exposure_id)


def run_reference(events, exposures, catalog, statements, eval_at):
    """The taste-residual-v1 reference model, exactly as SPEC section 2.2 defines it."""
    state = {}  # key -> [alpha, beta, last_update_dt, last_class]
    cooks = {e["id"]: e for e in events if e["kind"] == "recipe_cooked"}

    def rec_of(ev):
        for c in catalog:
            if c["recipe"]["id"] == ev["recipe"]["id"]:
                return c
        raise KeyError(ev["recipe"]["id"])

    for ev in sorted(events, key=lambda e: (e["at"], e["id"])):
        kind = ev["kind"]
        rec = rec_of(ev)
        t_ev = from_iso(ev["at"])

        if kind == "recipe_cooked":
            rating = ev["payload"].get("rating")
            if rating is None:
                reward, strength, hl = 0.6, STRENGTH["cook_no_rating"], H["cook_no_rating"]
            else:
                reward, strength, hl = (rating - 1) / 4.0, STRENGTH["cook_rating"], H["cook_rating"]
            exp = exposure_by_id(exposures, ev["payload"].get("exposureId"))
            w = (share_of(exp) if exp else 1.0) * strength
            cls = "cook_no_rating" if rating is None else "cook_rating"
            for fk in rec["features"]:
                a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, cls])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, hl)
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, cls]

        elif kind == "recipe_rated":
            cook = cooks[ev["payload"]["cookEventId"]]
            if cook["payload"].get("rating") is not None:
                raise ValueError("late rating for an already-rated cook is a correction")
            reward = (ev["payload"]["rating"] - 1) / 4.0
            strength = STRENGTH["cook_rating"]
            exp = exposure_by_id(exposures, cook["payload"].get("exposureId"))
            w = (share_of(exp) if exp else 1.0) * strength
            for fk in rec["features"]:
                a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, "cook_rating"])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, H["cook_rating"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, "cook_rating"]

        elif kind == "recipe_saved":
            exp = exposure_by_id(exposures, ev["payload"].get("exposureId"))
            w = (share_of(exp) if exp else 1.0) * STRENGTH["saved"]
            reward = REWARD["saved"]
            for fk in rec["features"]:
                a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, "saved"])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, H["saved"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, "saved"]

        elif kind == "recipe_skipped":
            exp = exposure_by_id(exposures, ev["payload"]["exposureId"])
            slate_ids = [s["recipe"]["id"] for s in exp["slate"]]
            if ev["recipe"]["id"] not in slate_ids:
                raise ValueError("skips only apply to shown items")
            w = share_of(exp) * STRENGTH["skipped"]
            reward = REWARD["skipped"]
            for fk in rec["features"]:
                a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, "skipped"])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, H["skipped"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, "skipped"]

        # servings_edited / profile_edited / correction_applied: configuration.

    t_eval = from_iso(eval_at)
    final = {}
    for fk, (a, b, t_last, cls) in state.items():
        d = decay((t_eval - t_last).total_seconds() / 86400.0, H[cls])
        final[fk] = (a * d, b * d, t_last, cls)
    return state, final


def contribution(final_key, cls_key):
    a, b, _, _ = final_key
    n = a + b
    mu = a / n
    d = 2.0 * mu - 1.0
    c = n / (n + K_SHRINK)
    return d * c * CAP[cls_key]


def canonical(value, indent=0):
    sp = "  " * indent
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return "%.6f" % value
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, list):
        if not value:
            return "[]"
        inner = ",\n".join(sp + "  " + canonical(v, indent + 1) for v in value)
        return "[\n" + inner + "\n" + sp + "]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        inner = ",\n".join(
            sp + "  " + json.dumps(k, ensure_ascii=True) + ": " + canonical(value[k], indent + 1)
            for k in sorted(value))
        return "{\n" + inner + "\n" + sp + "}"
    raise ValueError(f"cannot canonicalize {type(value).__name__}")


def write_canonical(path, doc):
    with open(path, "w") as f:
        f.write(canonical(doc) + "\n")


def main():
    os.makedirs(os.path.join(EX, "events"), exist_ok=True)
    os.makedirs(os.path.join(EX, "profile-statement"), exist_ok=True)
    os.makedirs(os.path.join(EX, "exposure"), exist_ok=True)
    os.makedirs(os.path.join(EX, "golden-fixture"), exist_ok=True)

    # --- single-event examples, one per kind ---
    base = {"id": "3c4d5e6f-1111-4c00-8d00-000000000001",
            "at": "2026-10-12T18:30:00Z", "eater": "you", "ingredient": None}
    r = R1.d()
    examples = {
        "recipe_viewed": {"recipe": r, "surface": "home.tonight",
                          "payload": {"slatePosition": 1, "exposureId": X1["id"]}},
        "recipe_opened": {"recipe": r, "surface": "home.tonight",
                          "payload": {"slatePosition": 1, "exposureId": X1["id"]}},
        "recipe_saved": {"recipe": r, "surface": "recipe.detail", "payload": {"exposureId": None}},
        "recipe_unsaved": {"recipe": r, "surface": "cookbook.saved", "payload": {}},
        "recipe_skipped": {"recipe": r, "surface": "home.tonight",
                           "payload": {"reason": "made_something_else", "exposureId": X1["id"]}},
        "recipe_cooked": E1,
        "recipe_rated": {"recipe": r, "surface": "cook.complete",
                         "payload": {"rating": 4, "cookEventId": E1["id"]}},
        "ingredient_substituted": {"recipe": r, "ingredient": 101, "surface": "cook.lechef",
                                   "payload": {"substituteIngredientId": 105, "ratio": 1.0,
                                               "motivation": "preferred", "cookEventId": E1["id"]}},
        "servings_edited": {"recipe": r, "surface": "cook.complete",
                            "payload": {"from": 2, "to": 4, "cookEventId": E1["id"]}},
        "lechef_feedback": {"recipe": r, "surface": "cook.lechef",
                            "payload": {"tag": "too_bland", "note": None, "cookEventId": E1["id"]}},
        "profile_edited": {"recipe": None, "ingredient": 101, "surface": "taste.profile",
                           "payload": {"op": "never_suggest", "featureKind": "ingredient",
                                       "featureKey": "ingredient:101", "note": None}},
        "correction_applied": {"recipe": None, "ingredient": None, "surface": "taste.profile",
                               "payload": {"statementId": "4d5e6f70-2222-4d00-9e00-000000000004",
                                           "action": "wrong", "note": None}},
    }
    for kind, rest in examples.items():
        doc = {"id": base["id"], "at": base["at"], "kind": kind, "eater": base["eater"],
               "recipe": rest.get("recipe"), "ingredient": rest.get("ingredient"),
               "surface": rest["surface"], "payload": rest["payload"]}
        write_canonical(os.path.join(EX, "events", kind + ".json"), doc)

    write_canonical(os.path.join(EX, "exposure", "tonight-weeknight.json"), X1)

    statements = [
        {"id": "4d5e6f70-0001-4d00-9e00-000000000001", "layer": "restriction",
         "featureKind": None, "featureKey": None, "templateId": "restriction.setup.allergy",
         "numerator": None, "denominator": None, "state": "active", "mutedUntil": None,
         "pinnedValue": None, "lastEvidenceAt": None, "createdAt": "2026-09-01T09:00:00Z",
         "updatedAt": "2026-09-01T09:00:00Z", "text": "No shellfish. Set at setup, edited in setup only."},
        {"id": "4d5e6f70-0002-4d00-9e00-000000000002", "layer": "inferred",
         "featureKind": "ingredient", "featureKey": "ingredient:101",
         "templateId": "taste.avoid.confident", "numerator": 4, "denominator": 5,
         "state": "active", "mutedUntil": None, "pinnedValue": None,
         "lastEvidenceAt": "2026-10-10T19:12:00Z", "createdAt": "2026-09-18T10:00:00Z",
         "updatedAt": "2026-10-10T19:12:00Z",
         "text": "You removed coriander in 4 of the 5 recipes you cooked that had it."},
        {"id": "4d5e6f70-0005-4d00-9e00-000000000005", "layer": "inferred",
         "featureKind": "ingredient", "featureKey": "ingredient:101",
         "templateId": "taste.lowrating.hedged", "numerator": 3, "denominator": 3,
         "state": "active", "mutedUntil": None, "pinnedValue": None,
         "lastEvidenceAt": "2026-10-10T19:12:00Z", "createdAt": "2026-09-18T10:00:00Z",
         "updatedAt": "2026-10-10T19:12:00Z",
         "text": "You seem to go off coriander: the last 3 recipes you cooked with it were rated 2 stars or below."},
        {"id": "4d5e6f70-0006-4d00-9e00-000000000006", "layer": "inferred",
         "featureKind": "ingredient", "featureKey": "ingredient:101",
         "templateId": "taste.lowrating.confident", "numerator": 2, "denominator": 3,
         "state": "active", "mutedUntil": None, "pinnedValue": None,
         "lastEvidenceAt": "2026-10-10T19:12:00Z", "createdAt": "2026-09-18T10:00:00Z",
         "updatedAt": "2026-10-10T19:12:00Z",
         "text": "You go off coriander: 2 of the 3 recipes you cooked with it were rated 2 stars or below."},
        {"id": "4d5e6f70-0003-4d00-9e00-000000000003", "layer": "pinned",
         "featureKind": "ingredient", "featureKey": "ingredient:207",
         "templateId": "pinned.dont_ask_again", "numerator": None, "denominator": None,
         "state": "muted", "mutedUntil": "2027-02-08T10:00:00Z", "pinnedValue": -6.0,
         "lastEvidenceAt": "2026-11-11T10:00:00Z", "createdAt": "2026-11-11T10:00:00Z",
         "updatedAt": "2026-11-11T10:00:00Z",
         "text": "You asked not to hear about blue cheese again for a while."},
    ]
    for s in statements:
        name = s["layer"] + ("-" + s["state"] if s["layer"] == "pinned" else "")
        if s["id"].endswith("000000000005"):
            name = "inferred-hedged"
        elif s["id"].endswith("000000000006"):
            name = "inferred-mixed"
        write_canonical(os.path.join(EX, "profile-statement", name + ".json"), s)

    # --- worked golden fixture ---
    # Input log is committed in canonical (at, id) order — the model sorts
    # defensively, but committed fixtures must read chronologically.
    events = [E1, E2, E3, E4, E6, E5, E7]
    exposures = [X1, X2, X3, X4, X5]
    input_statements = [PIN]
    eval_at = sorted(events, key=lambda e: (e["at"], e["id"]))[-1]["at"]
    _, final = run_reference(events, exposures, CATALOG, input_statements, eval_at)

    ing = final["ingredient:101"]
    cui = final["cuisine:indian"]
    sti = final["technique:stirfry"]
    p_ing = contribution(ing, "ingredient")
    p_cui = contribution(cui, "cuisine")
    p_sti = contribution(sti, "technique")

    def utc(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    pins = {"ingredient:101": PIN["pinnedValue"]}

    def learned_sum(c):
        return sum({"ingredient:101": p_ing, "cuisine:indian": p_cui,
                    "technique:stirfry": p_sti}[fk] for fk in c["features"]) + sum(
            v for fk, v in pins.items() if fk in c["features"])

    ranked = sorted(
        CATALOG,
        key=lambda c: (-(c["ruleScore"] + max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, learned_sum(c)))),
                       c["recipe"]["id"]))
    ranking = []
    for c in ranked:
        feats = [{"featureKey": fk,
                  "contribution": {"ingredient:101": p_ing, "cuisine:indian": p_cui,
                                   "technique:stirfry": p_sti}[fk]}
                 for fk in sorted(c["features"])]
        raw = learned_sum(c)
        applied = max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, raw))
        ranking.append({
            "recipe": c["recipe"],
            "ruleScore": c["ruleScore"],
            "learnedFeatures": feats,
            "learnedContribution": applied,
            "learnedContributionRaw": raw,
            "totalScore": c["ruleScore"] + applied,
        })

    hedged = 3 == 3 and 3 < 10
    fixture = {
        "format": "fridgeluck-taste-golden-fixture",
        "version": 2,
        "engine": "taste-residual-v1",
        "meta": {
            "household": "solo-cook-you",
            "seed": 0,
            "notes": (
                "Worked example. Three cooked meals containing coriander (ingredient 101), "
                "rated 2, 1, 1 stars, each cooking event in the same transaction as its meal "
                "log; exposure shares 2/4, 1/4, 1/2 weight the updates and the 60-day "
                "cook-rating half-life decays the posterior between them. A fourth, unrated "
                "cook of the stir-fry is followed two days later by recipe_rated (rating 3, "
                "cookEventId merge at strength 1.0), plus a save (reward 0.75, no slate) and "
                "a skip of the coriander recipe against the slate that showed it (reward "
                "0.15). The learned layer stays small: coriander's contribution is %.6f. An "
                "active pin (pinnedValue -8) on coriander dominates learning and binds "
                "GLOBAL_CLAMP on both coriander recipes (learnedContributionRaw below -8, "
                "learnedContribution exactly -8), pushing them under the tied featureless "
                "pair: R2 and R4 both ruleScore 60.0 and separate only by the rank tiebreak "
                "(recipe id ascending). cuisine:indian and technique:stirfry each have one "
                "cooked recipe and hide from the profile as thin evidence."
                % (p_ing,)
            ),
        },
        "catalog": {"featureNames": FEATURE_NAMES, "recipes": CATALOG},
        "input": {"events": events, "exposures": exposures, "statements": input_statements},
        "expected": {
            "featureState": [
                {"featureClass": "cuisine", "featureKey": "cuisine:indian",
                 "alpha": cui[0], "beta": cui[1], "lastEvidenceAt": utc(cui[2])},
                {"featureClass": "ingredient", "featureKey": "ingredient:101",
                 "alpha": ing[0], "beta": ing[1], "lastEvidenceAt": utc(ing[2])},
                {"featureClass": "technique", "featureKey": "technique:stirfry",
                 "alpha": sti[0], "beta": sti[1], "lastEvidenceAt": utc(sti[2])},
            ],
            "ranking": ranking,
            "profileStatements": [
                {"id": "5e6f7081-0001-4e00-8f00-000000000001", "layer": "inferred",
                 "featureKind": "ingredient", "featureKey": "ingredient:101",
                 "templateId": "taste.lowrating.hedged", "numerator": 3, "denominator": 3,
                 "state": "active", "mutedUntil": None, "pinnedValue": None,
                 "lastEvidenceAt": max(e["at"] for e in events
                                       if e["kind"] == "recipe_cooked"
                                       and e["recipe"]["id"] in ("1", "3")),
                 "createdAt": eval_at, "updatedAt": eval_at,
                 "text": "You seem to go off coriander: the last 3 recipes you cooked with it were rated 2 stars or below."},
                PIN,
            ],
            "hiddenStatements": [
                {"featureKey": "cuisine:indian", "reason": "thin-evidence"},
                {"featureKey": "technique:stirfry", "reason": "thin-evidence"},
            ],
        },
    }
    path = os.path.join(EX, "golden-fixture", "coriander-v1.json")
    write_canonical(path, fixture)

    print("ingredient:101 final alpha=%.6f beta=%.6f contribution=%.6f" % (ing[0], ing[1], p_ing))
    print("cuisine:indian final alpha=%.6f beta=%.6f contribution=%.6f" % (cui[0], cui[1], p_cui))
    print("technique:stirfry final alpha=%.6f beta=%.6f contribution=%.6f" % (sti[0], sti[1], p_sti))
    print("ranking totals:", [(r_["recipe"]["id"], "%.6f" % r_["totalScore"]) for r_ in ranking])
    print("learned sums (raw -> applied):",
          [(r_["recipe"]["id"], "%.6f" % r_["learnedContributionRaw"], "%.6f" % r_["learnedContribution"])
           for r_ in ranking])
    print("wrote", path)


if __name__ == "__main__":
    main()
