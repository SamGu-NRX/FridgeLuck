#!/usr/bin/env python3
"""Contract checker for docs/spec/taste.

Validates every example fixture under contracts/examples/ against its JSON
Schema (a small, standard-library validator — no dependencies; see
requirements.txt; supports types, enums, const, patterns, bounds, required,
additionalProperties, allOf and if/then/else), checks cross-field invariants,
and re-runs the taste-residual-v1 reference model over the golden fixture's
input and compares the result with the fixture's expected section through a
canonical serializer (sorted keys, 2-space indent, floats with exactly 6
fractional digits). Every example file must itself be in that canonical form.

The reference model consumes recipe_cooked (with and without rating),
recipe_rated (merge into the referenced cook's transaction window),
recipe_saved and recipe_skipped; ignores servings_edited, profile_edited and
correction_applied as configuration; and RAISES on any other kind, so a
future fixture cannot silently skip evidence.

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

UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$")

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
        elif isinstance(schema.get("additionalProperties"), dict):
            for key, sub in value.items():
                if key not in props:
                    validate(sub, schema["additionalProperties"], f"{path}.{key}", root)
        for key, sub in props.items():
            if key in value:
                validate(value[key], sub, f"{path}.{key}", root)

    if "allOf" in schema:
        for i, sub in enumerate(schema["allOf"]):
            validate(value, sub, f"{path}.allOf[{i}]", root)

    if "if" in schema:
        try:
            validate(value, schema["if"], f"{path}.if", root)
            matched = True
        except CheckError:
            matched = False
        if matched and "then" in schema:
            validate(value, schema["then"], f"{path}.then", root)
        if not matched and "else" in schema:
            validate(value, schema["else"], f"{path}.else", root)


# ---------------------------------------------------------------------------
# taste-residual-v1 reference model (SPEC section 2.2 constants)
# ---------------------------------------------------------------------------

HALF_LIFE = {"cook_rating": 60.0, "cook_no_rating": 30.0, "saved": 45.0,
             "skipped": 14.0, "substitution": 45.0, "lechef": 45.0,
             "open": 7.0, "view": 7.0}
STRENGTH = {"cook_rating": 1.0, "cook_no_rating": 0.3, "saved": 0.4,
            "skipped": 0.2, "substitution": 0.5, "lechef": 0.4,
            "open": 0.15, "view": 0.08}
REWARD = {"saved": 0.75, "skipped": 0.15}  # fixed rewards; cooks/ratings see recompute
CAP = {"ingredient": 4.0, "cuisine": 3.0, "technique": 2.0, "time": 2.0,
       "nutrient": 2.0, "spice": 2.0, "tool": 1.0, "other": 1.0}
K_SHRINK = 3.0
GLOBAL_CLAMP = 8.0
PROFILE_MIN_DENOMINATOR = 3
PROFILE_MIN_RATIO = 0.6
STALE_AFTER_HALF_LIVES = 3.0
IGNORED_KINDS = {"servings_edited", "profile_edited", "correction_applied"}

# The contract set ships one example per event kind plus the other surfaces;
# deleting one is contract drift, not tidying.
REQUIRED_EXAMPLES = {
    "events": sorted(["recipe_viewed", "recipe_opened", "recipe_saved", "recipe_unsaved",
                      "recipe_skipped", "recipe_cooked", "recipe_rated",
                      "ingredient_substituted", "servings_edited", "lechef_feedback",
                      "profile_edited", "correction_applied"]),
    "exposure": ["tonight-weeknight"],
    "profile-statement": sorted(["restriction", "inferred", "inferred-hedged",
                                 "inferred-mixed", "pinned-muted"]),
    "golden-fixture": ["coriander-v1"],
}


def require_utc(value, path):
    """Format AND calendar validity: '2026-13-01T...' must fail, not just match."""
    if value is None:
        return
    if not UTC_RE.match(value):
        raise CheckError(f"{path}: not ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ): {value!r}")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise CheckError(f"{path}: not a valid calendar timestamp: {value!r}")


def parse_utc(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def decay(dt_days, half_life):
    return 2.0 ** (-dt_days / half_life)


def exposure_share(exposures, exposure_id):
    """|slate| / |feasible| of the exposure, floored at 0.15; null id -> 1.0."""
    if exposure_id is None:
        return 1.0
    exp = exposures.get(exposure_id)
    if exp is None:
        raise CheckError(f"exposureId {exposure_id!r} not found in fixture exposures")
    return max(len(exp["slate"]) / len(exp["feasible"]), 0.15)


def check_slate_position(exp, ev, label):
    """payload.slatePosition must name the event's own recipe inside the slate."""
    pos = ev["payload"].get("slatePosition")
    if pos is None:
        return
    slate = exp["slate"]
    if not (1 <= pos <= len(slate)):
        raise CheckError(f"{label}: payload.slatePosition {pos} outside slate of size {len(slate)}")
    shown = slate[pos - 1]["recipe"]["id"]
    if shown != ev["recipe"]["id"]:
        raise CheckError(
            f"{label}: payload.slatePosition {pos} shows {shown!r} but the event names "
            f"recipe {ev['recipe']['id']!r}")


def check_exposure_refs(ev, exposures, path):
    """An event's payload.exposureId must resolve; its slatePosition must name
    the event's own recipe in that exposure's slate."""
    payload = ev.get("payload") or {}
    xid = payload.get("exposureId")
    if xid is None:
        return
    exp = exposures.get(xid)
    if exp is None:
        raise CheckError(f"{path}: payload.exposureId {xid!r} resolves to no exposure")
    check_slate_position(exp, ev, path)


def check_fixture_input(doc, path_str):
    """Calendar-valid timestamps, resolvable exposure references, and a
    chronologically-ordered input log in a committed fixture."""
    exposures = {e["id"]: e for e in doc["input"]["exposures"]}
    events = doc["input"]["events"]
    order = [(e["at"], e["id"]) for e in events]
    if order != sorted(order):
        raise CheckError(
            f"{path_str}: input events are not in canonical (at, id) order; "
            "committed fixtures must read chronologically")
    for e in events:
        require_utc(e["at"], f"{path_str}: input event {e['id']}.at")
        check_exposure_refs(e, exposures, f"{path_str}: input event {e['id']}")
    for e in doc["input"]["exposures"]:
        require_utc(e["at"], f"{path_str}: input exposure {e['id']}.at")
    for group, label in (("input", "input"), ("expected", "expected")):
        for s in doc.get(group, {}).get("profileStatements", doc.get(group, {}).get("statements", [])):
            for ts in ("mutedUntil", "lastEvidenceAt", "createdAt", "updatedAt"):
                require_utc(s.get(ts), f"{path_str}: {label} statement {s['id']}.{ts}")


def recompute(fixture):
    """Returns (feature_state, ranking, rendered, hidden) for the fixture input."""
    catalog = {c["recipe"]["id"]: c for c in fixture["catalog"]["recipes"]}
    exposures = {e["id"]: e for e in fixture["input"]["exposures"]}
    feature_names = fixture["catalog"].get("featureNames", {})
    events = sorted(fixture["input"]["events"], key=lambda e: (e["at"], e["id"]))
    input_statements = fixture["input"].get("statements", [])

    state = {}  # key -> [alpha, beta, last_update_dt, last_evidence_dt, last_class]
    cooks = {e["id"]: e for e in events if e["kind"] == "recipe_cooked"}

    for ev in events:
        kind = ev["kind"]
        rec = catalog.get(ev["recipe"]["id"]) if ev.get("recipe") else None
        if rec is None and kind in ("recipe_cooked", "recipe_rated", "recipe_saved",
                                    "recipe_skipped"):
            raise CheckError(f"event {ev['id']} ({kind}) has no catalog recipe")
        t_ev = parse_utc(ev["at"])

        if kind == "recipe_cooked":
            rating = ev["payload"].get("rating")
            if rating is None:
                reward, strength, hl = 0.6, STRENGTH["cook_no_rating"], HALF_LIFE["cook_no_rating"]
            else:
                reward, strength, hl = (rating - 1) / 4.0, STRENGTH["cook_rating"], HALF_LIFE["cook_rating"]
            exp = exposures.get(ev["payload"].get("exposureId"))
            if exp is not None:
                check_slate_position(exp, ev, f"event {ev['id']}")
            share = exposure_share(exposures, ev["payload"].get("exposureId"))
            w = share * strength
            evidence_class = "cook_no_rating" if rating is None else "cook_rating"
            for fk in rec["features"]:
                a, b, t_last, _, _ = state.get(fk, [1.0, 1.0, None, None, None])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, hl)
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, t_ev, evidence_class]

        elif kind == "recipe_rated":
            cook = cooks.get(ev["payload"]["cookEventId"])
            if cook is None:
                raise CheckError(
                    f"recipe_rated {ev['id']} references unknown cookEventId {ev['payload']['cookEventId']!r}")
            if cook["payload"].get("rating") is not None:
                raise CheckError(
                    f"recipe_rated {ev['id']} targets cook {cook['id']} which already carries an "
                    f"embedded rating; a late re-rating is a correction (correction_applied), not new evidence")
            if ev["recipe"]["id"] != cook["recipe"]["id"]:
                raise CheckError(f"recipe_rated {ev['id']} recipe does not match its cook's recipe")
            # Merge into the cook's transaction window: the rating is its own
            # evidence class (cook_rating, strength 1.0) at its own timestamp;
            # the exposure share comes from the cook's exposure.
            reward = (ev["payload"]["rating"] - 1) / 4.0
            strength = STRENGTH["cook_rating"]
            share = exposure_share(exposures, cook["payload"].get("exposureId"))
            w = share * strength
            for fk in rec["features"]:
                a, b, t_last, _, _ = state.get(fk, [1.0, 1.0, None, None, None])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, HALF_LIFE["cook_rating"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, t_ev, "cook_rating"]

        elif kind == "recipe_saved":
            share = exposure_share(exposures, ev["payload"].get("exposureId"))
            w = share * STRENGTH["saved"]
            reward = REWARD["saved"]
            for fk in rec["features"]:
                a, b, t_last, _, _ = state.get(fk, [1.0, 1.0, None, None, None])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, HALF_LIFE["saved"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, t_ev, "saved"]

        elif kind == "recipe_skipped":
            exp = exposures.get(ev["payload"].get("exposureId"))
            if exp is None:
                raise CheckError(f"recipe_skipped {ev['id']} has no resolvable exposureId")
            slate_ids = [s["recipe"]["id"] for s in exp["slate"]]
            if ev["recipe"]["id"] not in slate_ids:
                raise CheckError(
                    f"recipe_skipped {ev['id']} recipe is not in the slate of its exposure; "
                    "skips only apply to shown items")
            share = max(len(exp["slate"]) / len(exp["feasible"]), 0.15)
            w = share * STRENGTH["skipped"]
            reward = REWARD["skipped"]
            for fk in rec["features"]:
                a, b, t_last, _, _ = state.get(fk, [1.0, 1.0, None, None, None])
                if t_last is not None:
                    d = decay((t_ev - t_last).total_seconds() / 86400.0, HALF_LIFE["skipped"])
                    a, b = a * d, b * d
                a += w * reward
                b += w * (1.0 - reward)
                state[fk] = [a, b, t_ev, t_ev, "skipped"]

        elif kind in IGNORED_KINDS:
            continue  # configuration/correction; no posterior effect

        else:
            raise CheckError(
                f"reference model does not consume kind {kind!r}; extend recompute "
                "before adding it to a golden fixture")

    if not events:
        raise CheckError("golden fixture input has no events")

    t_eval = parse_utc(events[-1]["at"])
    final = {}
    for fk, (a, b, t_last, t_ev, last_class) in state.items():
        hl = HALF_LIFE[last_class]  # decay uses the most recent evidence class
        d = decay((t_eval - t_last).total_seconds() / 86400.0, hl)
        final[fk] = (a * d, b * d, t_ev, last_class)

    # Active pins: fixed per-feature rank values applied like contributions.
    pins = {}
    for s in input_statements:
        if s["layer"] == "pinned" and s["state"] == "active" and s.get("pinnedValue") is not None:
            if s.get("featureKey") is None:
                raise CheckError("active pinned statement without featureKey")
            pins[s["featureKey"]] = pins.get(s["featureKey"], 0.0) + float(s["pinnedValue"])

    def contrib(fk):
        a, b, _, _ = final[fk]
        n = a + b
        d = 2.0 * (a / n) - 1.0
        c = n / (n + K_SHRINK)
        cls = fk.split(":", 1)[0]
        return d * c * CAP[cls]  # magnitude is bounded by CAP; the clamp below bounds the sum

    def learned_sum(c):
        return sum(contrib(fk) for fk in c["features"]) + sum(
            v for fk, v in pins.items() if fk in c["features"])

    ranked = sorted(
        catalog.values(),
        key=lambda c: (-(c["ruleScore"] + max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, learned_sum(c)))),
                       c["recipe"]["id"]))
    ranking = []
    for c in ranked:
        feats = [{"featureKey": fk, "contribution": contrib(fk)}
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
            > STALE_AFTER_HALF_LIVES * HALF_LIFE[final[fk][3]])
        if denom < PROFILE_MIN_DENOMINATOR:
            hidden.append({"featureKey": fk, "reason": "thin-evidence"})
        elif stale:
            hidden.append({"featureKey": fk, "reason": "stale-evidence"})
        elif numer / denom < PROFILE_MIN_RATIO:
            hidden.append({"featureKey": fk, "reason": "thin-evidence"})
        else:
            # Hedged wording only when every cooked recipe with the feature is
            # in the numerator (few of them); otherwise the confident template
            # names both counts. A mixed history never uses "the last N ...".
            hedged = (numer == denom) and denom < 10
            name = feature_names.get(fk)
            if name is None:
                raise CheckError(
                    f"rendered statement for {fk} needs catalog.featureNames[{fk!r}]")
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

    active_pins = sorted(
        (s for s in input_statements
         if s["layer"] == "pinned" and s["state"] == "active"),
        key=lambda s: s["featureKey"])
    rendered = rendered + active_pins
    return final, ranking, rendered, hidden


# ---------------------------------------------------------------------------
# Canonical serialization: object keys sorted, 2-space indent, floats with
# exactly 6 fractional digits (%.6f), ensure-ascii strings, trailing newline.
# ---------------------------------------------------------------------------

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
    raise CheckError(f"cannot canonicalize {type(value).__name__}")


def canonical_text(value):
    return canonical(value) + "\n"


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
    if not s.get("text"):
        raise CheckError(f"{path}: statement text must be non-empty")
    for ts in ("mutedUntil", "lastEvidenceAt", "createdAt", "updatedAt"):
        require_utc(s.get(ts), f"{path}.{ts}")
    if layer == "restriction":
        for k in ("featureKind", "featureKey", "pinnedValue", "numerator",
                  "denominator", "mutedUntil"):
            if s.get(k) is not None:
                raise CheckError(f"{path}: restriction statement must not carry {k}")
    elif layer == "inferred":
        if s.get("featureKind") is None or s.get("featureKey") is None:
            raise CheckError(f"{path}: inferred statement must name its feature")
        if s["numerator"] is None or s["denominator"] is None:
            raise CheckError(f"{path}: inferred statement needs numerator and denominator")
        if s["denominator"] == 0 and s["numerator"] > 0:
            raise CheckError(f"{path}: numerator without denominator opportunities")
        if s["numerator"] > s["denominator"]:
            raise CheckError(
                f"{path}: numerator {s['numerator']} exceeds denominator {s['denominator']}")
        if s["denominator"] < PROFILE_MIN_DENOMINATOR:
            raise CheckError(
                f"{path}: inferred statement needs at least {PROFILE_MIN_DENOMINATOR} "
                f"opportunities before claiming a pattern (got {s['denominator']})")
        tid = s["templateId"]
        if tid.endswith(".hedged") and s["numerator"] != s["denominator"]:
            # Hedged wording claims every opportunity went the same way; a mixed
            # history must use the confident template naming both counts.
            raise CheckError(
                f"{path}: hedged template requires numerator == denominator "
                f"(got {s['numerator']}/{s['denominator']}); use the confident template")
        if tid.endswith(".confident") and s["numerator"] < PROFILE_MIN_RATIO * s["denominator"]:
            raise CheckError(
                f"{path}: confident wording needs at least {PROFILE_MIN_RATIO:.0%} of "
                f"opportunities agreeing (got {s['numerator']}/{s['denominator']})")
    elif layer == "pinned":
        if s.get("featureKey") is None:
            raise CheckError(f"{path}: pinned statement needs featureKey")
        pv = s.get("pinnedValue")
        if pv is None:
            raise CheckError(f"{path}: pinned statement needs pinnedValue")
        if abs(pv) > GLOBAL_CLAMP:
            raise CheckError(f"{path}: pinnedValue {pv} exceeds the global clamp ±{GLOBAL_CLAMP}")
        if s["state"] == "muted" and s.get("mutedUntil") is None:
            raise CheckError(f"{path}: muted pinned statement needs mutedUntil")
        if s["state"] == "active" and s.get("mutedUntil") is not None:
            raise CheckError(f"{path}: active pinned statement must not carry mutedUntil")


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

    # Cross-references for single-event examples resolve against the exposure
    # examples shipped alongside them.
    exposure_map = {}
    exposure_dir = os.path.join(EX, "exposure")
    if os.path.isdir(exposure_dir):
        for fname in sorted(os.listdir(exposure_dir)):
            if fname.endswith(".json"):
                with open(os.path.join(exposure_dir, fname)) as f:
                    e = json.load(f)
                exposure_map[e["id"]] = e

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
                raw_path = os.path.join(directory, fname)
                with open(raw_path) as f:
                    raw = f.read()
                doc = json.loads(raw)
                # Every committed file must already be in canonical form, so a
                # hand-edited file or a drifted generator fails loudly.
                if canonical_text(doc) != raw:
                    raise CheckError(
                        f"{path_str}: file is not in canonical serialization "
                        "(sorted keys, 2-space indent, %.6f floats); regenerate with gen_examples.py")
                validate(doc, schema)
                check_canonical_floats(doc, path_str)
                if sub in ("events", "exposure"):
                    require_utc(doc.get("at"), f"{path_str}.at")
                if sub == "events":
                    check_exposure_refs(doc, exposure_map, path_str)
                if sub == "profile-statement":
                    check_statement_invariants(doc, path_str)
                if sub == "golden-fixture":
                    check_fixture_input(doc, path_str)
                    final, ranking, rendered, hidden = recompute(doc)
                    exp = doc["expected"]
                    got_state = [
                        {"featureClass": fk.split(":", 1)[0], "featureKey": fk,
                         "alpha": final[fk][0], "beta": final[fk][1],
                         "lastEvidenceAt": final[fk][2].strftime("%Y-%m-%dT%H:%M:%SZ")}
                        for fk in sorted(final)]
                    sections = [
                        ("featureState", got_state),
                        ("ranking", ranking),
                        ("profileStatements", rendered),
                        ("hiddenStatements", hidden),
                    ]
                    for name, got in sections:
                        if canonical(got) != canonical(exp[name]):
                            raise CheckError(
                                f"{path_str}: {name} mismatch\n"
                                f"  recomputed: {canonical(got)}\n  expected:   {canonical(exp[name])}")
            except CheckError as e:
                failures.append(str(e))
            except Exception as e:  # noqa: BLE001 — report and continue
                failures.append(f"{path_str}: {type(e).__name__}: {e}")

    print(f"checked {count} examples under docs/spec/taste/contracts/examples")
    for sub, names in REQUIRED_EXAMPLES.items():
        for name in names:
            if not os.path.isfile(os.path.join(EX, sub, name + ".json")):
                failures.append(f"examples/{sub}/{name}.json: required contract example is missing")
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        print(f"check.py: {len(failures)} failure(s)")
        return 1
    print("check.py: all examples valid and self-consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
