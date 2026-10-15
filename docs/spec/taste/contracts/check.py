#!/usr/bin/env python3
"""Contract checker for docs/spec/taste.

Validates every example fixture under contracts/examples/ against its JSON
Schema (a small, standard-library validator — no dependencies; see
requirements.txt), checks cross-field invariants, canonical float formatting,
and re-runs the taste-residual-v1 reference model over the golden fixture's
input and compares the result with the fixture's expected section at the
canonical 6-decimal precision.

Usage (from anywhere): python3 docs/spec/taste/contracts/check.py
Exit code 0 = every example valid and self-consistent.
"""
import json
import os
import re
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.join(HERE, "examples")

UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(:?\.\d{3})?Z$")

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "null": type(None),
}


class CheckError(Exception):
    pass


def type_ok(value, name):
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    return isinstance(value, TYPES.get(name, object))


def validate(value, schema, path="$", root=None):
    root = root or schema
    if "$ref" in schema:
        ref = schema["$ref"]
        target_path = os.path.join(HERE, ref)
        with open(target_path) as f:
            target = json.load(f)
        return validate(value, target, path, target)

    if "const" in schema and value != schema["const"]:
        raise CheckError(f"{path}: expected const {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise CheckError(f"{path}: {value!r} not in enum {schema['enum']}")

    types = schema.get("type")
    if types:
        names = types if isinstance(types, list) else [types]
        if not any(type_ok(value, n) for n in names):
            raise CheckError(f"{path}: expected type {names}, got {type(value).__name__}")
        if value is None:
            return  # nothing further to check

    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise CheckError(f"{path}: {value!r} does not match {schema['pattern']}")
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise CheckError(f"{path}: shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise CheckError(f"{path}: longer than maxLength {schema['maxLength']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise CheckError(f"{path}: {value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            raise CheckError(f"{path}: {value} > maximum {schema['maximum']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise CheckError(f"{path}: fewer than minItems {schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise CheckError(f"{path}: more than maxItems {schema['maxItems']}")
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(value):
                validate(item, item_schema, f"{path}[{i}]", root)

    if isinstance(value, dict):
        for req in schema.get("required", []):
            if req not in value:
                raise CheckError(f"{path}: missing required property {req!r}")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    raise CheckError(f"{path}: unexpected property {key!r}")
        for key, sub in props.items():
            if key in value:
                validate(value[key], sub, f"{path}.{key}", root)


# ---------------------------------------------------------------------------
# taste-residual-v1 reference model (SPEC section 2.2 constants)
# ---------------------------------------------------------------------------

HALF_LIFE = {"cook_rating": 60.0, "cook_no_rating": 30.0, "saved": 45.0,
             "skipped": 14.0, "substitution": 45.0, "lechef": 45.0,
             "open": 7.0, "view": 7.0}
STRENGTH = {"cook_rating": 1.0, "cook_no_rating": 0.3, "saved": 0.4,
            "skipped": 0.2, "substitution": 0.5, "lechef": 0.4,
            "open": 0.15, "view": 0.08}
CAP = {"ingredient": 4.0, "cuisine": 3.0, "technique": 2.0, "time": 2.0,
       "nutrient": 2.0, "spice": 2.0, "tool": 1.0, "other": 1.0}
K_SHRINK = 3.0
GLOBAL_CLAMP = 8.0
PROFILE_MIN_DENOMINATOR = 3
PROFILE_MIN_RATIO = 0.6
STALE_AFTER_HALF_LIVES = 3.0


def parse_utc(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def decay(dt_days, half_life):
    return 2.0 ** (-dt_days / half_life)


def recompute(fixture):
    """Returns (feature_state, ranking, rendered, hidden) for the fixture input."""
    catalog = {c["recipe"]["id"]: c for c in fixture["catalog"]["recipes"]}
    exposures = {e["id"]: e for e in fixture["input"]["exposures"]}
    events = sorted(fixture["input"]["events"], key=lambda e: (e["at"], e["id"]))

    state = {}  # key -> [alpha, beta, last_update_dt, last_evidence_dt]
    for ev in events:
        if ev["kind"] != "recipe_cooked":
            continue
        rec = catalog[ev["recipe"]["id"]]
        rating = ev["payload"].get("rating")
        if rating is None:
            reward, strength, hl = 0.6, STRENGTH["cook_no_rating"], HALF_LIFE["cook_no_rating"]
        else:
            reward, strength, hl = (rating - 1) / 4.0, STRENGTH["cook_rating"], HALF_LIFE["cook_rating"]
        exp = exposures[ev["payload"]["exposureId"]]
        share = max(len(exp["slate"]) / len(exp["feasible"]), 0.15)
        w = share * strength
        t_ev = parse_utc(ev["at"])
        for fk in rec["features"]:
            a, b, t_last, _ = state.get(fk, [1.0, 1.0, None, None])
            if t_last is not None:
                d = decay((t_ev - t_last).total_seconds() / 86400.0, hl)
                a, b = a * d, b * d
            a += w * reward
            b += w * (1.0 - reward)
            state[fk] = [a, b, t_ev, t_ev]

    t_eval = parse_utc(events[-1]["at"])
    final = {}
    for fk, (a, b, t_last, t_ev) in state.items():
        d = decay((t_eval - t_last).total_seconds() / 86400.0, HALF_LIFE["cook_rating"])
        final[fk] = (a * d, b * d, t_ev)

    def contrib(fk):
        a, b, _ = final[fk]
        n = a + b
        d = 2.0 * (a / n) - 1.0
        c = n / (n + K_SHRINK)
        cls = fk.split(":", 1)[0]
        return max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, d * c * CAP[cls]))

    ranked = sorted(
        catalog.values(),
        key=lambda c: (-(c["ruleScore"] + sum(contrib(fk) for fk in c["features"])),
                       c["recipe"]["id"]))
    ranking = []
    for c in ranked:
        feats = [{"featureKey": fk, "contribution": round(contrib(fk), 6)}
                 for fk in sorted(c["features"])]
        lc = round(float(sum(contrib(fk) for fk in c["features"])), 6)
        ranking.append({
            "recipe": c["recipe"],
            "ruleScore": c["ruleScore"],
            "learnedFeatures": feats,
            "learnedContribution": lc,
            "totalScore": round(c["ruleScore"] + lc, 6),
        })

    # Profile statements: numerator/denominator over cooked recipes containing
    # the feature; rendered when denominator, ratio and recency bars pass.
    rendered, hidden = [], []
    for fk in sorted(state):
        cls = fk.split(":", 1)[0]
        denom = 0
        numer = 0
        last_ev = None
        for ev in events:
            if ev["kind"] != "recipe_cooked":
                continue
            if fk not in catalog[ev["recipe"]["id"]]["features"]:
                continue
            denom += 1
            rating = ev["payload"].get("rating")
            if rating is not None and rating <= 2:
                numer += 1
            last_ev = ev["at"]
        stale = last_ev is None or (
            (t_eval - parse_utc(last_ev)).total_seconds() / 86400.0
            > STALE_AFTER_HALF_LIVES * HALF_LIFE["cook_rating"])
        if denom < PROFILE_MIN_DENOMINATOR:
            hidden.append({"featureKey": fk, "reason": "thin-evidence"})
        elif stale:
            hidden.append({"featureKey": fk, "reason": "stale-evidence"})
        elif numer / denom < PROFILE_MIN_RATIO:
            hidden.append({"featureKey": fk, "reason": "thin-evidence"})
        else:
            hedged = denom < 10
            name = "coriander" if fk == "ingredient:101" else fk.split(":", 1)[1]
            text = (f"You seem to go off {name}: the last {numer} recipes you cooked with it "
                    f"were rated 2 stars or below.") if hedged else (
                f"You go off {name}: {numer} of the {denom} recipes you cooked with it "
                f"were rated 2 stars or below.")
            rendered.append({
                "id": "5e6f7081-0001-4e00-8f00-000000000001",
                "layer": "inferred", "featureKind": cls, "featureKey": fk,
                "templateId": "taste.lowrating.hedged" if hedged else "taste.lowrating.confident",
                "numerator": numer, "denominator": denom, "state": "active",
                "mutedUntil": None, "pinnedValue": None, "lastEvidenceAt": last_ev,
                "createdAt": events[-1]["at"], "updatedAt": events[-1]["at"], "text": text,
            })
    return final, ranking, rendered, hidden


def check_canonical_floats(value, path="$"):
    if isinstance(value, float):
        if round(value, 6) != value:
            raise CheckError(f"{path}: float {value!r} is not canonical at 6 decimals")
    elif isinstance(value, dict):
        for k, v in value.items():
            check_canonical_floats(v, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            check_canonical_floats(v, f"{path}[{i}]")


def check_statement_invariants(s, path):
    layer = s["layer"]
    if layer == "inferred":
        if s["numerator"] is None or s["denominator"] is None:
            raise CheckError(f"{path}: inferred statement needs numerator and denominator")
        if s["denominator"] == 0 and s["numerator"] > 0:
            raise CheckError(f"{path}: numerator without denominator opportunities")
        if s["numerator"] is not None and s["denominator"] is not None \
                and s["numerator"] > s["denominator"]:
            raise CheckError(f"{path}: numerator {s['numerator']} exceeds denominator {s['denominator']}")
    if layer == "pinned" and s["pinnedValue"] is None:
        raise CheckError(f"{path}: pinned statement needs pinnedValue")
    for ts in ("mutedUntil", "lastEvidenceAt", "createdAt", "updatedAt"):
        v = s.get(ts)
        if v is not None and not UTC_RE.match(v):
            raise CheckError(f"{path}.{ts}: not ISO-8601 UTC: {v!r}")


def main():
    failures = []

    def load(rel):
        with open(os.path.join(HERE, rel)) as f:
            return json.load(f)

    schemas = {
        "events": load("taste-event.schema.json"),
        "exposure": load("exposure.schema.json"),
        "profile-statement": load("profile-statement.schema.json"),
        "golden-fixture": load("golden-fixture.schema.json"),
    }

    count = 0
    for sub, schema in schemas.items():
        directory = os.path.join(EX, sub)
        if not os.path.isdir(directory):
            continue
        for fname in sorted(os.listdir(directory)):
            if not fname.endswith(".json"):
                continue
            count += 1
            rel = os.path.join("examples", sub, fname)
            path_str = f"examples/{sub}/{fname}"
            try:
                with open(os.path.join(directory, fname)) as f:
                    doc = json.load(f)
                validate(doc, schema)
                if sub == "profile-statement":
                    check_statement_invariants(doc, path_str)
                if sub == "golden-fixture":
                    check_canonical_floats(doc, path_str)
                    final, ranking, rendered, hidden = recompute(doc)
                    exp = doc["expected"]
                    got_state = [
                        {"featureClass": fk.split(":", 1)[0], "featureKey": fk,
                         "alpha": round(final[fk][0], 6), "beta": round(final[fk][1], 6),
                         "lastEvidenceAt": final[fk][2].strftime("%Y-%m-%dT%H:%M:%SZ")}
                        for fk in sorted(final)]
                    if json.dumps(got_state, sort_keys=True) != json.dumps(exp["featureState"], sort_keys=True):
                        raise CheckError(
                            f"{path_str}: featureState mismatch\n  recomputed: {got_state}\n  expected:   {exp['featureState']}")
                    if json.dumps(ranking, sort_keys=True) != json.dumps(exp["ranking"], sort_keys=True):
                        raise CheckError(
                            f"{path_str}: ranking mismatch\n  recomputed: {json.dumps(ranking)}\n  expected:   {json.dumps(exp['ranking'])}")
                    if json.dumps(rendered, sort_keys=True) != json.dumps(exp["profileStatements"], sort_keys=True):
                        raise CheckError(
                            f"{path_str}: profileStatements mismatch\n  recomputed: {json.dumps(rendered)}\n  expected:   {json.dumps(exp['profileStatements'])}")
                    if json.dumps(hidden, sort_keys=True) != json.dumps(exp["hiddenStatements"], sort_keys=True):
                        raise CheckError(
                            f"{path_str}: hiddenStatements mismatch\n  recomputed: {json.dumps(hidden)}\n  expected:   {json.dumps(exp['hiddenStatements'])}")
            except CheckError as e:
                failures.append(str(e))
            except Exception as e:  # noqa: BLE001 — report and continue
                failures.append(f"{path_str}: {type(e).__name__}: {e}")

    print(f"checked {count} examples under docs/spec/taste/contracts/examples")
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        print(f"check.py: {len(failures)} failure(s)")
        return 1
    print("check.py: all examples valid and self-consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
