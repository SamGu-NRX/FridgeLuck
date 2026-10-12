#!/usr/bin/env python3
"""Independent Python conformance runner for data/ingredient-facts.

Re-implements the evaluation semantics from
packages/FLIngredientFacts/Sources/FLIngredientFacts on its own: it shares no
code with the Swift package or the TypeScript runner. Loads the dataset,
validates it strictly, runs every case in conformance/cases.json and exits
nonzero on any failure.

Usage: python3 run_conformance.py [repo-root-or-data-dir] [cases.json]
Standard library only.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

ALLERGENS = [
    "milk", "egg", "fish", "crustaceanShellfish", "treeNuts",
    "peanuts", "wheat", "soy", "sesame",
]
DIETS = ["vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree"]
EVIDENCE_KINDS = ["usda", "label", "reference", "recipe", "standard"]
FACT_STATES = ["contains", "free", "unknown", "allowed", "violated"]
CERTAINTIES = ["certain", "typical", "variable", "unknown"]


class DatasetError(Exception):
    pass


def fail(message: str) -> None:
    raise DatasetError(message)


def normalized(raw: str) -> str:
    return raw.strip().lower()


def parse_json_file(path: str) -> Any:
    if not os.path.exists(path):
        fail(f"missing dataset file: {path}")
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")


def check_evidence(evidence: dict | None, where: str) -> None:
    """Evidence completeness: known kind, non-blank ref and note — mirrors the
    Swift loader (Dataset.swift validateFact) so all three implementations
    reject the same malformed data."""
    if evidence is None:
        fail(f"{where}: fact lacks evidence")
    if evidence.get("kind") not in EVIDENCE_KINDS:
        fail(f"{where}: bad evidence kind '{evidence.get('kind')}'")
    ref = evidence.get("ref")
    note = evidence.get("note")
    if not isinstance(ref, str) or not ref.strip():
        fail(f"{where}: evidence ref must be a non-empty string")
    if not isinstance(note, str) or not note.strip():
        fail(f"{where}: evidence note must be a non-empty string")


def check_evidence_state(state: str, evidence: dict | None, where: str) -> None:
    """State vocabulary and the absence-evidence rule (pinned)."""
    if state not in FACT_STATES:
        fail(f"{where}: bad state '{state}'")
    if evidence is None:
        if state == "unknown":
            return
        fail(f"{where}: {state} fact lacks evidence")
    check_evidence(evidence, where)
    if state in ("free", "allowed") and evidence.get("kind") in ("usda", "recipe"):
        fail(f"{where}: absence state '{state}' may not use '{evidence.get('kind')}' evidence")


class Dataset:
    def __init__(self, data_dir: str) -> None:
        identities_file = parse_json_file(os.path.join(data_dir, "identities.json"))
        facts_file = parse_json_file(os.path.join(data_dir, "facts.json"))
        self.identities: list[dict] = identities_file.get("ingredients", [])
        self.facts: dict[str, dict] = facts_file.get("facts", {})
        if not self.identities:
            fail("identities.json is empty")
        if not self.facts:
            fail("facts.json is empty")
        self.display_name: dict[str, str] = {i["key"]: i["display"] for i in self.identities}
        self.name_index: dict[str, str] = {}
        self.form_index: dict[str, tuple[str, str]] = {}
        self.validate()

    def index_name(self, raw: str, key: str) -> None:
        name = normalized(raw)
        existing = self.name_index.get(name)
        if existing is not None:
            if existing != key:
                fail(f"name '{raw}' maps to both {existing} and {key}")
            return
        self.name_index[name] = key

    def index_form_name(self, raw: str, identity: str, form: str) -> None:
        name = normalized(raw)
        if name in self.form_index or name in self.name_index:
            fail(f"match name '{raw}' is not unique (identity {identity}, form {form})")
        self.form_index[name] = (identity, form)
        self.name_index[name] = identity

    def validate(self) -> None:
        keys: set[str] = set()
        for ing in self.identities:
            key = ing["key"]
            if key in keys:
                fail(f"duplicate identity key '{key}'")
            keys.add(key)
            if key not in self.facts and key != "artisan-granola-bar":
                fail(f"identity '{key}' has no fact entry")
            self.index_name(key, key)
            self.index_name(ing["display"], key)
            for syn in ing.get("synonyms") or []:
                self.index_name(syn, key)
            for form in ing.get("forms") or []:
                for syn in form.get("synonyms") or []:
                    self.index_form_name(syn, key, form["key"])
                fact_entry = self.facts.get(key)
                if not fact_entry or form["key"] not in (fact_entry.get("forms") or {}):
                    fail(f"identity '{key}' form '{form['key']}' has no fact override")

        for key, entry in self.facts.items():
            if entry.get("key") != key:
                fail(f"fact entry key mismatch: {key} vs {entry.get('key')}")
            for allergen, fact in (entry.get("allergens") or {}).items():
                if allergen not in ALLERGENS:
                    fail(f"{key}: unknown allergen '{allergen}'")
                check_evidence_state(fact["state"], fact.get("evidence"), f"{key}.allergens.{allergen}")
            for diet, fact in (entry.get("diets") or {}).items():
                if diet not in DIETS:
                    fail(f"{key}: unknown diet '{diet}'")
                check_evidence_state(fact["state"], fact.get("evidence"), f"{key}.diets.{diet}")
            if entry.get("gluten"):
                check_evidence_state(entry["gluten"]["state"], entry["gluten"].get("evidence"), f"{key}.gluten")
            for form_name, override in (entry.get("forms") or {}).items():
                for allergen, fact in (override.get("allergens") or {}).items():
                    if allergen not in ALLERGENS:
                        fail(f"{key}.forms.{form_name}: unknown allergen '{allergen}'")
                    check_evidence_state(
                        fact["state"], fact.get("evidence"),
                        f"{key}.forms.{form_name}.allergens.{allergen}")
                for diet, fact in (override.get("diets") or {}).items():
                    if diet not in DIETS:
                        fail(f"{key}.forms.{form_name}: unknown diet '{diet}'")
                    check_evidence_state(
                        fact["state"], fact.get("evidence"),
                        f"{key}.forms.{form_name}.diets.{diet}")
                if override.get("gluten"):
                    check_evidence_state(
                        override["gluten"]["state"], override["gluten"].get("evidence"),
                        f"{key}.forms.{form_name}.gluten")
            for component in entry.get("components") or []:
                if component["key"] not in self.facts:
                    fail(f"{key}: component key '{component['key']}' does not resolve")
                if component["certainty"] not in CERTAINTIES:
                    fail(f"{key}: bad certainty '{component['certainty']}'")
                if component["certainty"] != "unknown" and not component.get("evidence"):
                    fail(f"{key}: component '{component['key']}' lacks evidence")
                if component.get("evidence"):
                    check_evidence(
                        component.get("evidence"), f"{key}.components.{component['key']}",
                    )

    def resolve_fact_key(self, name: str) -> tuple[str, str | None] | None:
        folded = normalized(name)
        key = self.name_index.get(folded)
        if key is None:
            return None
        form = self.form_index.get(folded)
        if form is not None:
            return (form[0], form[1])
        return (key, None)


def ordered_restrictions(restrictions: dict[str, set[str]]) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for kind, vocab in (("allergen", ALLERGENS), ("diet", DIETS)):
        for name in vocab:
            if name in restrictions[f"{kind}s"]:
                result.append((kind, name))
    return result


def evaluate(
    dataset: Dataset,
    entry: dict,
    form: str | None,
    restrictions: dict[str, set[str]],
    ingredient_label: str,
    depth: int,
) -> dict:
    violations: list[dict] = []
    unknown_missing: list[str] = []
    unknown_allergens: set[str] = set()
    unknown_diets: set[str] = set()
    unknown_restriction: tuple[str, str] | None = None
    allowed_evidence: list[dict] = []

    def fact_for(restriction: tuple[str, str]) -> dict | None:
        override = (entry.get("forms") or {}).get(form) if form else None
        kind, name = restriction
        if override is not None:
            fact = (override.get(f"{kind}s") or {}).get(name)
            if fact is not None:
                return fact
        return (entry.get(f"{kind}s") or {}).get(name)

    def record_unknown(restriction: tuple[str, str], note: str | None = None) -> None:
        nonlocal unknown_restriction
        if unknown_restriction is None:
            unknown_restriction = restriction
        kind, name = restriction
        if kind == "allergen":
            unknown_allergens.add(name)
        else:
            unknown_diets.add(name)
        what = (f"allergen '{name}' fact for '{entry['key']}' is missing or unknown"
                if kind == "allergen"
                else f"diet '{name}' fact for '{entry['key']}' is missing or unknown")
        unknown_missing.append(f"{what} — {note}" if note else what)

    def violation_reason(restriction: tuple[str, str]) -> str:
        kind, name = restriction
        if kind == "allergen":
            return f"'{ingredient_label}' contains the allergen '{name}'"
        return f"'{ingredient_label}' is not compatible with the {name} diet"

    def restriction_payload(restriction: tuple[str, str]) -> dict:
        kind, name = restriction
        return {kind: name}

    for restriction in ordered_restrictions(restrictions):
        fact = fact_for(restriction)
        state = fact.get("state") if fact else None
        if state in ("contains", "violated"):
            evidence = fact.get("evidence") if fact else None
            if evidence is not None:
                violations.append({
                    "ingredient": ingredient_label,
                    "restriction": restriction_payload(restriction),
                    "reason": violation_reason(restriction),
                    "evidence": [evidence],
                })
        elif state in ("free", "allowed"):
            evidence = fact.get("evidence") if fact else None
            if evidence is not None:
                allowed_evidence.append(evidence)
        elif state == "unknown":
            record_unknown(restriction, (fact.get("evidence") or {}).get("note"))
        else:
            record_unknown(restriction)

    if violations:
        return {"result": "violated", "violation": violations[0]}

    components = entry.get("components") or []
    if unknown_missing and depth < 8 and components:
        component_unknowns: list[str] = []
        for component in components:
            label = f"'{component['key']}' in '{entry['key']}'"
            component_entry = dataset.facts.get(component["key"])
            if component_entry is None:
                component_unknowns.append(f"composition of {label} is unrecorded")
                continue
            if component["certainty"] in ("certain", "typical"):
                sub = evaluate(dataset, component_entry, None, restrictions,
                               component["key"], depth + 1)
                if sub["result"] == "violated":
                    evidence = list(sub["violation"]["evidence"])
                    if component.get("evidence"):
                        evidence.append(component["evidence"])
                    return {"result": "violated", "violation": {
                        "ingredient": ingredient_label,
                        "restriction": sub["violation"]["restriction"],
                        "reason": f"component {sub['violation']['reason']}",
                        "evidence": evidence,
                    }}
                if sub["result"] == "unknown":
                    component_unknowns.append(
                        f"component {component['key']}: " + "; ".join(sub["unknown"]["missing"]))
                else:
                    allowed_evidence.extend(sub["evidence"])
            elif component["certainty"] == "variable":
                # Presence varies: a violation only means SOME products carry
                # it, which is unknown, not violated.
                sub = evaluate(dataset, component_entry, None, restrictions,
                               component["key"], depth + 1)
                if sub["result"] == "violated":
                    component_unknowns.append(
                        f"whether {label} is present varies by product; when present it "
                        + sub["violation"]["reason"])
                elif sub["result"] == "unknown":
                    component_unknowns.append(
                        f"component {component['key']} (presence varies): "
                        + "; ".join(sub["unknown"]["missing"]))
                else:
                    allowed_evidence.extend(sub["evidence"])
            else:
                component_unknowns.append(
                    f"composition of {label} is unverified (certainty unknown)")

        fallback = unknown_restriction or (ordered_restrictions(restrictions) or [("allergen", "milk")])[0]
        if component_unknowns:
            return {"result": "unknown", "unknown": {
                "ingredient": ingredient_label,
                "restriction": restriction_payload(fallback),
                "missing": unknown_missing + component_unknowns,
                "reason": "compound composition leaves restrictions undecided",
            }}
        # Every component settled allowed. Clearing still requires the
        # composition to be known complete: an unlisted component could carry
        # an allergen or violate a diet — incomplete composition blocks every
        # clear.
        if entry.get("compositionComplete") is True:
            return {"result": "allowed", "evidence": allowed_evidence}
        return {"result": "unknown", "unknown": {
            "ingredient": ingredient_label,
            "restriction": restriction_payload(fallback),
            "missing": unknown_missing + [f"composition of '{entry['key']}' is incomplete"],
            "reason": "composition is not known to be complete; incomplete composition clears nothing",
        }}

    if not unknown_missing:
        return {"result": "allowed", "evidence": allowed_evidence}
    fallback = unknown_restriction or (ordered_restrictions(restrictions) or [("allergen", "milk")])[0]
    return {"result": "unknown", "unknown": {
        "ingredient": ingredient_label,
        "restriction": restriction_payload(fallback),
        "missing": unknown_missing,
        "reason": "facts do not settle the restricted properties",
    }}


def evaluate_ingredient(dataset: Dataset, name: str, restrictions: dict[str, set[str]]) -> dict:
    resolved = dataset.resolve_fact_key(name)
    fallback = (ordered_restrictions(restrictions) or [("allergen", "milk")])[0]
    if resolved is None:
        return {"result": "unknown", "unknown": {
            "ingredient": name,
            "restriction": {"allergen": fallback[1]} if fallback[0] == "allergen" else {"diet": fallback[1]},
            "missing": [f"ingredient '{name}' is not in the dataset"],
            "reason": "unresolved ingredient: evaluation fails closed",
        }}
    key, form = resolved
    entry = dataset.facts.get(key)
    if entry is None:
        return {"result": "unknown", "unknown": {
            "ingredient": name,
            "restriction": {"allergen": fallback[1]} if fallback[0] == "allergen" else {"diet": fallback[1]},
            "missing": [f"no facts exist for '{key}'"],
            "reason": "unfactored ingredient: evaluation fails closed",
        }}
    label = dataset.display_name.get(key, name)
    return evaluate(dataset, entry, form, restrictions, label, 0)


def main(argv: list[str]) -> int:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # script lives at <root>/data/ingredient-facts/conformance/runners/python/
    default_data_dir = os.path.abspath(os.path.join(script_dir, "..", "..", ".."))
    data_dir = default_data_dir
    cases_path = os.path.join(default_data_dir, "conformance", "cases.json")
    if len(argv) >= 2:
        arg = os.path.abspath(argv[1])
        data_dir = arg if os.path.exists(os.path.join(arg, "identities.json")) \
            else os.path.join(arg, "data", "ingredient-facts")
    if len(argv) >= 3:
        cases_path = os.path.abspath(argv[2])

    try:
        dataset = Dataset(data_dir)
    except DatasetError as error:
        print(f"dataset load failed: {error}", file=sys.stderr)
        return 2

    cases_file = parse_json_file(cases_path)
    cases = cases_file.get("cases", [])

    failures = 0
    print(f"running {len(cases)} conformance cases against {data_dir}")
    for case in cases:
        restrictions: dict[str, set[str]] = {
            "allergens": {a for a in (case["restrictions"].get("allergens") or []) if a in ALLERGENS},
            "diets": {d for d in (case["restrictions"].get("diets") or []) if d in DIETS},
        }
        evaluation = evaluate_ingredient(dataset, case["ingredient"], restrictions)
        problems: list[str] = []
        expected = case["expected"]
        if evaluation["result"] != expected["result"]:
            problems.append(f"expected {expected['result']}, got {evaluation['result']}")
        if evaluation["result"] == expected["result"]:
            if evaluation["result"] == "violated":
                reason = evaluation["violation"]["reason"].lower()
            elif evaluation["result"] == "unknown":
                reason = evaluation["unknown"]["reason"].lower()
            else:
                reason = ""
            for needle in expected.get("reasonContains") or []:
                if needle.lower() not in reason:
                    problems.append(f"reason does not mention '{needle}': {reason}")
            missing = "; ".join(evaluation["unknown"]["missing"]).lower() \
                if evaluation["result"] == "unknown" else ""
            for needle in expected.get("missingMention") or []:
                if needle.lower() not in missing:
                    problems.append(f"missing list does not mention '{needle}': {missing}")
            evidence = " | ".join(
                f"{e['kind']} {e['ref']} {e['note']}" for e in evaluation.get("evidence", [])
            ).lower() if evaluation["result"] == "allowed" else ""
            for needle in expected.get("evidenceMention") or []:
                if needle.lower() not in evidence:
                    problems.append(f"evidence does not mention '{needle}': {evidence}")
        if problems:
            failures += 1
            print(f"  FAIL {case['id']}: " + "; ".join(problems))
        else:
            print(f"  PASS {case['id']}: {evaluation['result']}")

    if failures == 0:
        print(f"all {len(cases)} cases passed")
        return 0
    print(f"{failures} of {len(cases)} cases failed")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
