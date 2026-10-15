#!/usr/bin/env python3
"""Generates the worked golden fixture and contract examples for docs/spec/taste.

The model math mirrors SPEC section 2.2 exactly. Run from the repo root:
  python3 docs/spec/taste/contracts/gen_examples.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.join(HERE, "examples")


def f6(x: float) -> float:
    """Canonical 6-decimal rounding (round-half-even, matching Python round)."""
    return round(x, 6)


def decay(dt_days: float, half_life: float) -> float:
    return 2.0 ** (-dt_days / half_life)


# Model constants (SPEC 2.2)
H = {"cook_rating": 60.0, "cook_no_rating": 30.0, "saved": 45.0, "skipped": 14.0,
     "substitution": 45.0, "lechef": 45.0, "open": 7.0, "view": 7.0}
STRENGTH = {"cook_rating": 1.0, "cook_no_rating": 0.3, "saved": 0.4, "skipped": 0.2,
            "substitution": 0.5, "lechef": 0.4, "open": 0.15, "view": 0.08}
CAP = {"ingredient": 4.0, "cuisine": 3.0, "technique": 2.0, "time": 2.0,
       "nutrient": 2.0, "spice": 2.0, "tool": 1.0, "other": 1.0}
K_SHRINK = 3.0
GLOBAL_CLAMP = 8.0


def exposure_share(exp_id, exposures):
    for e in exposures:
        if e["id"] == exp_id:
            share = len(e["slate"]) / len(e["feasible"])
            return max(share, 0.15)
    raise KeyError(exp_id)


class Ref:
    def __init__(self, rid):
        self.source = "catalog"
        self.id = rid
        self.revision = 1

    def d(self):
        return {"source": self.source, "id": self.id, "revision": self.revision}


R1, R2, R3, R4 = Ref("1"), Ref("2"), Ref("3"), Ref("4")

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

CATALOG = [
    {"recipe": R1.d(), "features": ["ingredient:101", "cuisine:indian"], "ruleScore": 63.0, "timeMinutes": 30},
    {"recipe": R2.d(), "features": [], "ruleScore": 60.0, "timeMinutes": 25},
    {"recipe": R3.d(), "features": ["ingredient:101"], "ruleScore": 61.0, "timeMinutes": 15},
    {"recipe": R4.d(), "features": [], "ruleScore": 55.0, "timeMinutes": 20},
]

CATALOG_KIND = {"ingredient:101": "ingredient", "cuisine:indian": "cuisine"}


def from_iso(s):
    import datetime
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def run_reference(events, exposures, catalog, statements, eval_at):
    """The taste-residual-v1 reference model, exactly as SPEC section 2.2 defines it."""
    feature_cls = {}
    for c in catalog:
        for fk in c["features"]:
            feature_cls[fk] = fk.split(":", 1)[0]
    state = {}  # key -> [alpha, beta, last_update_dt, last_evidence_dt]
    rating_class = "cook_rating"

    for ev in sorted(events, key=lambda e: (e["at"], e["id"])):
        if ev["kind"] != "recipe_cooked":
            continue
        rec = next(c for c in catalog if c["recipe"]["id"] == ev["recipe"]["id"])
        t_ev = from_iso(ev["at"])
        rating = ev["payload"].get("rating")
        if rating is None:
            reward, strength, half_life = 0.6, STRENGTH["cook_no_rating"], H["cook_no_rating"]
        else:
            reward, strength, half_life = (rating - 1) / 4.0, STRENGTH[rating_class], H[rating_class]
        share = max(len(next(x for x in exposures if x["id"] == ev["payload"]["exposureId"])["slate"])
                    / len(next(x for x in exposures if x["id"] == ev["payload"]["exposureId"])["feasible"]), 0.15)
        w = share * strength
        for fk in rec["features"]:
            a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, None])
            if t_last is not None:
                d = decay((t_ev - t_last).total_seconds() / 86400.0, half_life)
                a, b = a * d, b * d
            a += w * reward
            b += w * (1.0 - reward)
            state[fk] = [a, b, t_ev, t_ev]

    # Final decay of every touched feature to the evaluation instant.
    t_eval = from_iso(eval_at)
    final = {}
    for fk, (a, b, t_last, t_ev) in state.items():
        hl = H[rating_class]  # all evidence in this fixture is rated cooks
        d = decay((t_eval - t_last).total_seconds() / 86400.0, hl)
        final[fk] = (a * d, b * d, t_ev)
    return state, final


def contribution(final_key, cls_key):
    a, b, _ = final_key
    n = a + b
    mu = a / n
    d = 2.0 * mu - 1.0
    c = n / (n + K_SHRINK)
    return d * c * CAP[cls_key]


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
                          "payload": {"slatePosition": 2, "exposureId": X1["id"]}},
        "recipe_opened": {"recipe": r, "surface": "home.tonight",
                          "payload": {"slatePosition": 2, "exposureId": X1["id"]}},
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
        with open(os.path.join(EX, "events", kind + ".json"), "w") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")

    with open(os.path.join(EX, "exposure", "tonight-weeknight.json"), "w") as f:
        os.makedirs(os.path.join(EX, "exposure"), exist_ok=True)
        json.dump(X1, f, indent=2, sort_keys=True)
        f.write("\n")

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
        with open(os.path.join(EX, "profile-statement", name + ".json"), "w") as f:
            json.dump(s, f, indent=2, sort_keys=True)
            f.write("\n")

    # --- worked golden fixture ---
    events = [E1, E2, E3]
    exposures = [X1, X2, X3]
    eval_at = events[-1]["at"]
    _, final = run_reference(events, exposures, CATALOG, [], eval_at)

    ing = final["ingredient:101"]
    cui = final["cuisine:indian"]
    p_ing = contribution(ing, "ingredient")
    p_cui = contribution(cui, "cuisine")

    fixture = {
        "format": "fridgeluck-taste-golden-fixture",
        "version": 1,
        "engine": "taste-residual-v1",
        "meta": {
            "household": "solo-cook-you",
            "seed": 0,
            "notes": (
                "Worked example: three cooked meals containing coriander (ingredient 101), "
                "rated 2, 1, 1 stars, each cooking event in the same transaction as its meal log. "
                "Exposure shares 2/4, 1/4, 1/2 weight the updates; the second and third cooks are "
                "20 and 15 days apart, so the 60-day cook-rating half-life decays the posterior "
                "between updates and once more before the ranking is computed. The learned layer "
                "starts from the uniform Beta prior (alpha=beta=1). Coriander's posterior ends "
                "negative (n=%.6f, mean=%.6f) but the shrinkage c=n/(n+3) and the per-class cap "
                "(4.0) keep its contribution at %.6f: small evidence can nudge but never overturn "
                "the rule ranker. cuisine:indian carries one observation and hides from the profile "
                "as thin evidence."
                % (ing[0] + ing[1], ing[0] / (ing[0] + ing[1]), p_ing)
            ),
        },
        "catalog": {"recipes": CATALOG},
        "input": {"events": events, "exposures": exposures, "statements": []},
        "expected": {
            "featureState": [
                {"featureClass": "cuisine", "featureKey": "cuisine:indian",
                 "alpha": f6(cui[0]), "beta": f6(cui[1]), "lastEvidenceAt": "2026-09-01T18:00:00Z"},
                {"featureClass": "ingredient", "featureKey": "ingredient:101",
                 "alpha": f6(ing[0]), "beta": f6(ing[1]), "lastEvidenceAt": "2026-10-06T18:00:00Z"},
            ],
            "ranking": [
                {"recipe": R1.d(), "ruleScore": 63.0,
                 "learnedFeatures": [{"featureKey": "cuisine:indian", "contribution": f6(p_cui)},
                                     {"featureKey": "ingredient:101", "contribution": f6(p_ing)}],
                 "learnedContribution": f6(p_ing + p_cui), "totalScore": f6(63.0 + p_ing + p_cui)},
                {"recipe": R3.d(), "ruleScore": 61.0,
                 "learnedFeatures": [{"featureKey": "ingredient:101", "contribution": f6(p_ing)}],
                 "learnedContribution": f6(p_ing), "totalScore": f6(61.0 + p_ing)},
                {"recipe": R2.d(), "ruleScore": 60.0, "learnedFeatures": [],
                 "learnedContribution": 0.0, "totalScore": 60.0},
                {"recipe": R4.d(), "ruleScore": 55.0, "learnedFeatures": [],
                 "learnedContribution": 0.0, "totalScore": 55.0},
            ],
            "profileStatements": [
                {"id": "5e6f7081-0001-4e00-8f00-000000000001", "layer": "inferred",
                 "featureKind": "ingredient", "featureKey": "ingredient:101",
                 "templateId": "taste.lowrating.hedged", "numerator": 3, "denominator": 3,
                 "state": "active", "mutedUntil": None, "pinnedValue": None,
                 "lastEvidenceAt": "2026-10-06T18:00:00Z",
                 "createdAt": eval_at, "updatedAt": eval_at,
                 "text": "You seem to go off coriander: the last 3 recipes you cooked with it were rated 2 stars or below."},
            ],
            "hiddenStatements": [
                {"featureKey": "cuisine:indian", "reason": "thin-evidence"},
            ],
        },
    }
    path = os.path.join(EX, "golden-fixture", "coriander-v1.json")
    with open(path, "w") as f:
        json.dump(fixture, f, indent=2, sort_keys=True)
        f.write("\n")

    print("ingredient:101 final alpha=%.6f beta=%.6f contribution=%.6f" % (ing[0], ing[1], p_ing))
    print("cuisine:indian final alpha=%.6f beta=%.6f contribution=%.6f" % (cui[0], cui[1], p_cui))
    print("ranking totals:", [(r["recipe"]["id"], r["totalScore"]) for r in fixture["expected"]["ranking"]])
    print("wrote", path)


if __name__ == "__main__":
    main()
