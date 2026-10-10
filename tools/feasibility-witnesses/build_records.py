#!/usr/bin/env python3
"""Build the witness-record corpus: nine valid certificates + eighteen mutations.

Valids: every (state, recipe) pair backed by the pinned claims rows
(states 1-3 x recipes 101-103), with witnesses and explanations derived
from the sources, never asserted. Mutants m01-m18 each perturb one aspect;
see expected_counts.py for the class table.
"""

from __future__ import annotations

import copy
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOL_DIR))

import certificate
from sources import (
    SourceBundle,
    inventory_revision_id,
    profile_revision_id,
    recipe_revision_id,
)

FIXTURES = TOOL_DIR / "fixtures"
RECORDS = TOOL_DIR / "records.jsonl"


def build_valid(bundle: SourceBundle, state_id: int, recipe_id: int, claim_kind: str) -> dict:
    state = bundle.states[state_id]
    truth = bundle.derive_all(state_id, recipe_id)
    apv = int((state.get("profile") or {}).get("allergen_preferences_version") or 0)
    binding = certificate.make_source_binding(
        inventory_revision_id(bundle.states_sha256, state_id),
        profile_revision_id(bundle.states_sha256, state_id, apv),
        recipe_revision_id(bundle.catalog_sha256, recipe_id),
        bundle.binding_sha256s(),
    )
    req: list[dict] = []
    for iid in sorted(truth["required"]):
        w = truth["required"][iid]
        item = {"ingredient_id": iid, "kind": w["kind"]}
        if w["kind"] == "explicit_exclusion":
            item["required_grams"] = w["required_grams"]
            item["excluded_via"] = list(w["excluded_via"])
        elif w["kind"] == "absent":
            item["required_grams"] = w["required_grams"]
        elif w["kind"] == "quantity_unknown":
            item["required_grams"] = w["required_grams"]
            item["basis_lots"] = copy.deepcopy(w["basis_lots"])
        else:  # required_satisfied | shortage
            item["required_grams"] = w["required_grams"]
            item["available_grams"] = w["available_grams"]
            item["basis_lots"] = copy.deepcopy(w["basis_lots"])
        req.append(item)
    opt: list[dict] = []
    for iid in sorted(truth["optional"]):
        w = truth["optional"][iid]
        item = {"ingredient_id": iid, "kind": w["kind"]}
        if w["kind"] == "optional_excluded":
            item["excluded_via"] = list(w["excluded_via"])
        elif w["kind"] == "optional_present":
            item["available_grams"] = w["available_grams"]
            item["basis_lots"] = copy.deepcopy(w["basis_lots"])
        elif w["kind"] == "optional_unknown":
            item["basis_lots"] = copy.deepcopy(w["basis_lots"])
        opt.append(item)
    return {
        "record_id": f"s{state_id}r{recipe_id}",
        "claim": {
            "kind": claim_kind,
            "state_id": state_id,
            "recipe_id": recipe_id,
            "claimed_by": "production_replay",
        },
        "source_binding": binding,
        "required_witnesses": req,
        "optional_witnesses": opt,
        "explanation": certificate.make_explanation(
            "complete" if claim_kind == "complete_match" else "missing_list", truth
        ),
    }


def _witness(cert: dict, iid: int, required: bool = True) -> dict:
    lst = cert["required_witnesses"] if required else cert["optional_witnesses"]
    for item in lst:
        if item["ingredient_id"] == iid:
            return item
    raise KeyError(iid)


def _tagged(mid: str, cert: dict, applied_to: str) -> dict:
    cert = copy.deepcopy(cert)
    cert["record_id"] = mid
    cert["mutation"] = {"id": mid, "applied_to": applied_to}
    return cert


def _mutations(
    bundle: SourceBundle, valid: dict[tuple[int, int], dict]
) -> list[dict]:
    out: list[dict] = []

    def mutant(mid: str, base: dict, fn) -> None:
        cert = copy.deepcopy(base)
        fn(cert)
        cert["record_id"] = mid
        cert["mutation"] = {"id": mid, "applied_to": base["record_id"]}
        out.append(cert)

    # --- structure (schema catches, no sources needed) ---
    def m01(c: dict) -> None:
        del _witness(c, 2)["required_grams"]

    def m02(c: dict) -> None:
        _witness(c, 1)["required_grams"] = "150"

    def m03(c: dict) -> None:
        w = _witness(c, 12)
        assert w["kind"] == "quantity_unknown"
        w["basis_lots"] = [{"ingredient_id": 12, "known_grams": 180.0, "is_estimate": True}]

    def m04(c: dict) -> None:
        truth = bundle.derive_all(c["claim"]["state_id"], c["claim"]["recipe_id"])
        c["explanation"] = certificate.make_explanation("missing_list", truth)

    mutant("m01", valid[(1, 101)], m01)
    mutant("m02", valid[(1, 101)], m02)
    mutant("m03", valid[(1, 102)], m03)
    mutant("m04", valid[(1, 101)], m04)

    # --- source_binding (revisions must recompute from fixture bytes) ---
    def m05(c: dict) -> None:
        c["source_binding"]["inventory_revision"] = "states:" + "f" * 12 + ":state=1"

    def m06(c: dict) -> None:
        c["source_binding"]["states_sha256"] = "a" * 64

    def m07(c: dict) -> None:
        c["source_binding"]["profile_revision"] = (
            "profile:" + bundle.states_sha256[:12] + ":state=1:apv=99"
        )

    def m08(c: dict) -> None:
        c["claim"]["state_id"] = 99

    mutant("m05", valid[(1, 101)], m05)
    mutant("m06", valid[(1, 101)], m06)
    mutant("m07", valid[(1, 101)], m07)
    mutant("m08", valid[(1, 101)], m08)

    # --- claim_not_in_source (kind not backed by pinned production claims) ---
    out.append(_tagged("m09", build_valid(bundle, 1, 103, "complete_match"), "s1r103"))
    out.append(_tagged("m10", build_valid(bundle, 1, 101, "missing_list"), "s1r101"))
    out.append(_tagged("m11", build_valid(bundle, 4, 101, "complete_match"), "s4r101"))

    # --- incomplete_witness (recipe rows with no witness of the right kind) ---
    def m12(c: dict) -> None:
        c["required_witnesses"] = [w for w in c["required_witnesses"] if w["ingredient_id"] != 10]

    def m13(c: dict) -> None:
        _witness(c, 22, required=False)
        c["optional_witnesses"] = [
            w for w in c["optional_witnesses"] if w["ingredient_id"] != 22
        ]
        c["required_witnesses"].append(
            {"ingredient_id": 22, "kind": "absent", "required_grams": 10.0}
        )

    def m14(c: dict) -> None:
        w = _witness(c, 10)
        c["required_witnesses"] = [
            x for x in c["required_witnesses"] if x["ingredient_id"] != 10
        ]
        c["optional_witnesses"].append(
            {
                "ingredient_id": 10,
                "kind": "optional_present",
                "available_grams": w["available_grams"],
                "basis_lots": copy.deepcopy(w["basis_lots"]),
            }
        )

    mutant("m12", valid[(2, 101)], m12)
    mutant("m13", valid[(1, 101)], m13)
    mutant("m14", valid[(1, 101)], m14)

    # --- unsupported_witness (witness contradicts the sources) ---
    def m15(c: dict) -> None:
        w = _witness(c, 1)
        assert w["kind"] == "required_satisfied"
        w["available_grams"] = w["available_grams"] + 5.0

    def m16(c: dict) -> None:
        w = _witness(c, 5)
        assert w["kind"] == "shortage"
        truth = bundle.derive_all(c["claim"]["state_id"], c["claim"]["recipe_id"])
        exp = certificate.make_explanation("missing_list", truth)
        exp["missing"].remove(5)
        exp["excluded"].append(5)
        c["explanation"] = exp
        w["kind"] = "explicit_exclusion"
        w["excluded_via"] = ["allergen_group:shellfish"]
        w.pop("available_grams", None)
        w.pop("basis_lots", None)

    def m17(c: dict) -> None:
        w = _witness(c, 12)
        assert w["kind"] == "quantity_unknown"
        # Structurally coherent forged basis: a KNOWN lot of 180 g where the
        # sources pin an estimated (unknown-amount) lot. Only source
        # derivation can catch this; the schema cannot.
        w["basis_lots"] = [{"ingredient_id": 12, "known_grams": 180.0, "is_estimate": False}]

    def m18(c: dict) -> None:
        w = _witness(c, 43)
        assert w["kind"] == "explicit_exclusion"
        w["excluded_via"] = ["allergen_group:shellfish"]

    mutant("m15", valid[(2, 101)], m15)
    mutant("m16", valid[(2, 102)], m16)
    mutant("m17", valid[(1, 102)], m17)
    mutant("m18", valid[(3, 103)], m18)
    return out


def main() -> int:
    bundle = SourceBundle(FIXTURES)
    valid: dict[tuple[int, int], dict] = {}
    records: list[dict] = []
    for sid in (1, 2, 3):
        row = bundle.claims[sid]
        for rid in sorted(set(row["makeable_ids"]) | set(row["near_match_ids"])):
            kind = "complete_match" if rid in row["makeable_ids"] else "missing_list"
            cert = build_valid(bundle, sid, rid, kind)
            valid[(sid, rid)] = cert
            records.append(cert)
    n_valid = len(records)
    records.extend(_mutations(bundle, valid))
    RECORDS.write_text(
        "".join(certificate.dumps(r) + "\n" for r in records), encoding="utf-8"
    )
    print(f"wrote {len(records)} records ({n_valid} valid, {len(records) - n_valid} mutants)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
