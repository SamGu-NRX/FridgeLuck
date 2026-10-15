#!/usr/bin/env python3
"""Validate the LeChef contract schemas and every example fixture.

Usage: python3 contracts/check.py
Exit 0 when every schema parses and every fixture validates against its schema,
plus the cross-checks listed below. Exit 1 with a report otherwise.

Cross-checks beyond schema validation:
  1. proposal fixtures: expiresAt == createdAt + 300 s (the pinned TTL).
  2. proposal fixtures: payloadHash == "sha256:" + sha256 over the compact
     canonical JSON of the payload (recomputed here, not trusted).
  3. receipt fixtures: matched to a proposal fixture by proposalID, and the
     receipt payloadHash equals that proposal's payloadHash.
  4. #102 round-trip: PR #102's frozen action-proposal.json envelope (fetched
     verbatim from its branch) is mapped through the §8.1 re-cut rename map and
     the mapped envelope must validate against proposal.schema.json. Its literal
     payloadHash is a placeholder that reproduces neither the payload digest nor
     any known constant, so the mapping recomputes the hash the way the runtime
     rule (wire.ts payloadHash()) does.
  5. plan fixture: pool conservation — sum of sufficient/short/unknown lines equals
     totalLines in fitSummary; every short line has a non-null `short`; a short
     line implies a non-empty shoppingList.
  6. substitution fixture: allergenClasses uses the nine shared classes only.

Requires the `jsonschema` package (pip install jsonschema); a vendored minimal
validator fallback covers the subset of draft 2020-12 this contract uses.
"""

import hashlib
import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMAS = ["proposal", "receipt", "cook-step", "plan", "substitution", "scaling-rules"]
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
SHA = re.compile(r"^sha256:[0-9a-f]{64}$")

errors: list[str] = []
checked = 0


def load(name: str) -> dict:
    path = HERE / f"{name}.schema.json"
    if not path.exists():
        path = HERE / "examples" / f"{name}.json"
    with open(path) as f:
        return json.load(f)


def iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def canonical(payload) -> str:
    """Compact canonical JSON — the digest input of both #102 (wire.ts:90-93) and this spec."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def payload_sha256(payload) -> str:
    return hashlib.sha256(canonical(payload).encode()).hexdigest()


# --- validator -----------------------------------------------------------------

def make_validator():
    try:
        import jsonschema

        def validate(instance, schema, path):
            v = jsonschema.Draft202012Validator(schema)
            for e in v.iter_errors(instance):
                errors.append(f"{path}: {e.message}")
        return validate
    except ImportError:
        pass

    def validate(instance, schema, path):
        # Minimal fallback for the subset used: type, enum, required,
        # properties, additionalProperties:false, items, oneOf, allOf,
        # if/then, min/maxItems, min/exclusiveMinimum, maximum, minLength,
        # maxLength, pattern, minItems.
        def check(inst, sch, p):
            t = sch.get("type")
            if t:
                types = t if isinstance(t, list) else [t]
                py = {"object": dict, "array": list, "string": str,
                      "integer": int, "number": (int, float), "boolean": bool,
                      "null": type(None)}
                ok = any(isinstance(inst, py[x]) and not (x in ("integer", "number") and isinstance(inst, bool)) for x in types)
                if not ok:
                    errors.append(f"{p}: expected type {t}, got {type(inst).__name__}")
                    return
            if "enum" in sch and inst not in sch["enum"]:
                errors.append(f"{p}: {inst!r} not in enum {sch['enum']}")
                return
            if "pattern" in sch and isinstance(inst, str) and not re.search(sch["pattern"], inst):
                errors.append(f"{p}: {inst!r} fails pattern {sch['pattern']}")
            if isinstance(inst, str):
                if "minLength" in sch and len(inst) < sch["minLength"]:
                    errors.append(f"{p}: shorter than minLength {sch['minLength']}")
                if "maxLength" in sch and len(inst) > sch["maxLength"]:
                    errors.append(f"{p}: longer than maxLength {sch['maxLength']}")
            if isinstance(inst, (int, float)) and not isinstance(inst, bool):
                if "minimum" in sch and inst < sch["minimum"]:
                    errors.append(f"{p}: {inst} < minimum {sch['minimum']}")
                if "exclusiveMinimum" in sch and inst <= sch["exclusiveMinimum"]:
                    errors.append(f"{p}: {inst} <= exclusiveMinimum {sch['exclusiveMinimum']}")
                if "maximum" in sch and inst > sch["maximum"]:
                    errors.append(f"{p}: {inst} > maximum {sch['maximum']}")
            if isinstance(inst, dict):
                for req in sch.get("required", []):
                    if req not in inst:
                        errors.append(f"{p}: missing required property {req!r}")
                props = sch.get("properties", {})
                for k, v in inst.items():
                    if k in props:
                        check(v, props[k], f"{p}.{k}")
                    elif sch.get("additionalProperties") is False:
                        errors.append(f"{p}: additional property {k!r} not allowed")
            if isinstance(inst, list):
                if "minItems" in sch and len(inst) < sch["minItems"]:
                    errors.append(f"{p}: fewer than minItems {sch['minItems']}")
                if "maxItems" in sch and len(inst) > sch["maxItems"]:
                    errors.append(f"{p}: more than maxItems {sch['maxItems']}")
                if "items" in sch:
                    for i, item in enumerate(inst):
                        check(item, sch["items"], f"{p}[{i}]")
            if "oneOf" in sch:
                good = 0
                for sub in sch["oneOf"]:
                    before = len(errors)
                    check(inst, sub, p)
                    if len(errors) == before:
                        good += 1
                    else:
                        del errors[before:]
                if good != 1:
                    errors.append(f"{p}: matched {good} of oneOf branches, expected 1")
            if "allOf" in sch:
                for sub in sch["allOf"]:
                    check(inst, sub, p)
            if "if" in sch:
                before = len(errors)
                check(inst, sch["if"], p)
                matched = len(errors) == before
                del errors[before:]
                if matched and "then" in sch:
                    check(inst, sch["then"], p)
        check(instance, schema, path)

    return validate


validate = make_validator()


def resolve(schema: dict) -> dict:
    """Inline $defs refs so the fallback validator sees the whole schema."""
    text = json.dumps(schema)
    defs = schema.get("$defs", {})

    def sub(m):
        name = m.group(1)
        if name not in defs:
            raise KeyError(f"unknown $defs reference: #/$defs/{name} — fix the schema, do not validate as any")
        return json.dumps(defs[name])
    # naive but sufficient: replace {"$ref": "#/$defs/x"} occurrences
    out = re.sub(r'\{"\$ref": "#/\$defs/([A-Za-z0-9_]+)"\}', sub, text)
    # for jsonschema path, refs resolve natively; return parsed
    return json.loads(out)


def main() -> int:
    global checked
    schemas = {name: load(name) for name in SCHEMAS}

    # 1. every schema parses and is a JSON Schema object
    for name, sch in schemas.items():
        checked += 1
        if not isinstance(sch, dict) or "$schema" not in sch:
            errors.append(f"{name}.schema.json: not a JSON Schema (missing $schema)")

    # 2. fixture -> schema validation
    fixture_map = {
        "proposal": ["proposal-substitute", "proposal-add-timer"],
        "receipt": ["receipt-executed", "receipt-expired"],
        "cook-step": ["cook-step"],
        "plan": ["plan"],
        "substitution": ["substitution"],
        "scaling-rules": ["scaling-rules"],
    }
    examples_dir = HERE / "examples"
    fixtures = {}
    for schema_name, fx in fixture_map.items():
        for f in fx:
            path = examples_dir / f"{f}.json"
            data = load(path.name.replace(".json", "")) if False else json.loads(path.read_text())
            fixtures[f] = data
            checked += 1
            validate(data, resolve(schemas[schema_name]), f"examples/{f}.json")

    # 3. TTL cross-check on proposals
    for f in ("proposal-substitute", "proposal-add-timer"):
        d = fixtures[f]
        checked += 1
        if not ISO.match(d["createdAt"]) or not ISO.match(d["expiresAt"]):
            errors.append(f"{f}: timestamps not ISO-8601 ms")
        elif iso(d["expiresAt"]) - iso(d["createdAt"]) != timedelta(seconds=300):
            errors.append(f"{f}: expiresAt != createdAt + 300 s")

    # 4. proposal payloadHash recomputation — the digest is derived, never trusted
    proposal_ids = ("proposal-substitute", "proposal-add-timer")
    for f in proposal_ids:
        d = fixtures[f]
        checked += 1
        expected = "sha256:" + payload_sha256(d["payload"])
        if d["payloadHash"] != expected:
            errors.append(f"{f}: payloadHash is not sha256 over the compact canonical payload (expected {expected})")

    # 5. receipt <-> proposal by proposalID, hash equality
    proposals = {fixtures[f]["proposalID"]: fixtures[f] for f in proposal_ids}
    for f in ("receipt-executed", "receipt-expired"):
        r = fixtures[f]
        checked += 1
        if not SHA.match(r["payloadHash"]):
            errors.append(f"{f}: payloadHash not a sha256 reference")
        src = proposals.get(r["proposalID"])
        if src is None:
            errors.append(f"{f}: references proposalID {r['proposalID']!r}, which no proposal fixture defines")
        elif r["payloadHash"] != src["payloadHash"]:
            errors.append(f"{f}: payloadHash does not equal proposal {r['proposalID']}'s payloadHash")

    # 6. #102 round-trip: the frozen #102 fixture, mapped through the §8.1
    # rename map, must validate against proposal.schema.json — proving the map
    # is complete and #102-produced proposals are expressible in this re-cut.
    p102 = json.loads((examples_dir / "action-proposal-102.json").read_text())
    KIND_MAP = {
        "timerStart": "timer_start",
        "timerAdjust": "timer_adjust",
        "stepAdvance": "step_advance",
        "inventoryCorrection": "inventory_correction",
        "mealLog": "meal_log",
        "note": "save_note",
    }
    mapped_kind = KIND_MAP.get(p102["payload"]["kind"])
    checked += 1
    if mapped_kind is None:
        errors.append(f"action-proposal-102: payload kind {p102['payload']['kind']!r} is missing from the §8.1 rename map")
    else:
        mapped = {
            "proposalID": "prop_" + p102["id"],
            "snapshotRevision": p102["snapshotRevision"],
            "createdAt": p102["createdAt"],
            "expiresAt": p102["expiresAt"],
            "payloadHash": "sha256:" + payload_sha256(p102["payload"]),
            "kind": mapped_kind,
            "payload": {k: v for k, v in p102["payload"].items() if k != "kind"},
        }
        validate(mapped, resolve(schemas["proposal"]), "examples/action-proposal-102.json -> re-cut -> proposal.schema.json")

    # 7. plan fixture: pool conservation and short-line integrity
    plan = fixtures["plan"]
    checked += 1
    lines = [ln for dinner in plan["dinners"] for ln in dinner["lines"]]
    counted = sum(1 for ln in lines if ln["lineState"] in ("sufficient", "short", "quantity_unknown"))
    if counted != plan["fitSummary"]["totalLines"]:
        errors.append(f"plan: counted {counted} lines, fitSummary.totalLines is {plan['fitSummary']['totalLines']}")
    short_lines = [ln for ln in lines if ln["lineState"] == "short"]
    for ln in short_lines:
        if not ln.get("short"):
            errors.append(f"plan: lineState=short without short amount ({ln.get('name')})")
    if short_lines and not plan["shoppingList"]:
        errors.append("plan: short lines exist but shoppingList is empty")

    # 8. substitution fixture: nine shared allergen classes only
    sub = fixtures["substitution"]
    checked += 1
    allowed = {"gluten", "dairy", "egg", "soy", "peanut", "tree_nut", "sesame", "fish", "shellfish"}
    bad = set(sub["recheck"]["allergenClasses"]) - allowed
    if bad:
        errors.append(f"substitution: allergen classes outside the nine shared classes: {sorted(bad)}")

    print(f"check.py: {checked} checks over {len(SCHEMAS)} schemas and {len(fixtures)} fixtures")
    if errors:
        print(f"FAILED ({len(errors)}):")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("OK — all schemas and fixtures valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
