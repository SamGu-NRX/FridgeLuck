"""Typed certificate schema for feasibility witnesses.

A certificate is the typed, self-describing form of ONE claimed explanation
(one (state, recipe) pair claimed by the production replay). Every witness
item is bound to an inventory/profile/recipe revision via the certificate's
source_binding, and every claim is justified from the pinned sources, not
asserted.

Witness kinds — required rows (exactly one per required recipe row):

  required_satisfied   known grams on hand cover the requirement; carries
                       required_grams, available_grams, basis_lots.
  quantity_unknown     present only via estimated lots: the amount is
                       UNKNOWN. Carries required_grams and basis_lots with
                       known_grams null. MUST NOT carry available_grams —
                       the verifier rejects an unknown that asserts a number.
  shortage             present, known grams below requirement; carries
                       required_grams, available_grams, basis_lots.
  absent               no pantry presence at all; carries required_grams.
  explicit_exclusion   the ingredient is excluded by the health profile
                       (allergen group / individual / diet); carries
                       required_grams and excluded_via. Dominates quantity:
                       an allergen in the dish is an allergen in the dish,
                       whether or not the pantry holds it.

Witness kinds — optional rows (kept strictly apart; an optional row can
never appear in required_witnesses and never blocks feasibility):

  optional_present / optional_unknown / optional_absent / optional_excluded

The explanation restates what the certificate claims in the surface's
vocabulary (complete match, or a missing list), and must partition the
witnesses exactly.
"""

from __future__ import annotations

import json
import re
from typing import Any

REQUIRED_KINDS = {
    "required_satisfied",
    "quantity_unknown",
    "shortage",
    "absent",
    "explicit_exclusion",
}
OPTIONAL_KINDS = {
    "optional_present",
    "optional_unknown",
    "optional_absent",
    "optional_excluded",
}
CLAIM_KINDS = {"complete_match", "missing_list"}
EXPLANATION_KIND_FOR_CLAIM = {"complete_match": "complete", "missing_list": "missing_list"}

_INVENTORY_RE = re.compile(r"^states:[0-9a-f]{12}:state=\d+$")
_PROFILE_RE = re.compile(r"^profile:[0-9a-f]{12}:state=\d+:apv=\d+$")
_RECIPE_RE = re.compile(r"^catalog:[0-9a-f]{12}:recipe=\d+$")
_SHA_RE = re.compile(r"^[0-9a-f]{64}$")

RECORD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


def structural_errors(cert: Any) -> list[str]:
    """Shape/type errors checkable without the sources. Empty list = well-formed."""
    errs: list[str] = []
    if not isinstance(cert, dict):
        return ["certificate is not an object"]

    record_id = cert.get("record_id")
    if not isinstance(record_id, str) or not RECORD_ID_RE.match(record_id):
        errs.append("record_id missing or malformed")

    claim = cert.get("claim")
    if not isinstance(claim, dict):
        errs.append("claim missing or not an object")
        claim = {}
    if claim.get("kind") not in CLAIM_KINDS:
        errs.append(f"claim.kind must be one of {sorted(CLAIM_KINDS)}")
    for field in ("state_id", "recipe_id"):
        value = claim.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            errs.append(f"claim.{field} must be a positive integer")
    if claim.get("claimed_by") != "production_replay":
        errs.append('claim.claimed_by must be "production_replay"')

    binding = cert.get("source_binding")
    if not isinstance(binding, dict):
        errs.append("source_binding missing or not an object")
        binding = {}
    for key, pattern in (
        ("inventory_revision", _INVENTORY_RE),
        ("profile_revision", _PROFILE_RE),
        ("recipe_revision", _RECIPE_RE),
        ("states_sha256", _SHA_RE),
        ("catalog_sha256", _SHA_RE),
        ("claims_sha256", _SHA_RE),
    ):
        value = binding.get(key)
        if not isinstance(value, str) or not pattern.match(value):
            errs.append(f"source_binding.{key} missing or malformed")

    req = cert.get("required_witnesses")
    if not isinstance(req, list):
        errs.append("required_witnesses missing or not a list")
        req = []
    opt = cert.get("optional_witnesses")
    if not isinstance(opt, list):
        errs.append("optional_witnesses missing or not a list")
        opt = []

    seen_required: set[int] = set()
    for item in req:
        for e in _witness_errors(item, required=True):
            errs.append(f"required_witnesses: {e}")
        if isinstance(item, dict) and isinstance(item.get("ingredient_id"), int):
            iid = item["ingredient_id"]
            if iid in seen_required:
                errs.append(f"required_witnesses: duplicate witness for ingredient {iid}")
            seen_required.add(iid)
    seen_optional: set[int] = set()
    for item in opt:
        for e in _witness_errors(item, required=False):
            errs.append(f"optional_witnesses: {e}")
        if isinstance(item, dict) and isinstance(item.get("ingredient_id"), int):
            iid = item["ingredient_id"]
            if iid in seen_optional:
                errs.append(f"optional_witnesses: duplicate witness for ingredient {iid}")
            seen_optional.add(iid)
    overlap = seen_required & seen_optional
    if overlap:
        errs.append(
            "an ingredient may not be witnessed both required and optional: "
            f"{sorted(overlap)}"
        )

    explanation = cert.get("explanation")
    if not isinstance(explanation, dict):
        errs.append("explanation missing or not an object")
        explanation = {}
    expected_kind = EXPLANATION_KIND_FOR_CLAIM.get(claim.get("kind"))
    if expected_kind is not None and explanation.get("kind") != expected_kind:
        errs.append(
            f"explanation.kind must be {expected_kind!r} for claim kind "
            f"{claim.get('kind')!r}"
        )
    errs.extend(_explanation_partition_errors(explanation, req))

    if "mutation" in cert and not isinstance(cert["mutation"], dict):
        errs.append("mutation, when present, must be an object")
    return errs


def _explanation_partition_errors(explanation: dict[str, Any], req: list[Any]) -> list[str]:
    if explanation.get("kind") != "missing_list":
        return []
    errs: list[str] = []
    lists: dict[str, Any] = {
        "satisfied": explanation.get("satisfied"),
        "missing": explanation.get("missing"),
        "excluded": explanation.get("excluded"),
        "unknown_quantity": explanation.get("unknown_quantity"),
    }
    for name, value in lists.items():
        if not isinstance(value, list) or not all(
            isinstance(v, int) and not isinstance(v, bool) for v in value
        ):
            errs.append(f"explanation.{name} must be a list of ingredient ids")
    if errs:
        return errs

    kind_by_id: dict[int, str] = {}
    for item in req:
        if isinstance(item, dict) and isinstance(item.get("ingredient_id"), int):
            kind_by_id[item["ingredient_id"]] = item.get("kind", "")

    allowed: dict[str, set[str]] = {
        "satisfied": {"required_satisfied", "quantity_unknown"},
        "missing": {"shortage", "absent"},
        "excluded": {"explicit_exclusion"},
        "unknown_quantity": {"quantity_unknown"},
    }
    covered: set[int] = set()
    for name, ids in lists.items():
        for iid in ids:
            if iid not in kind_by_id:
                errs.append(f"explanation.{name} references unwitnessed ingredient {iid}")
                continue
            if kind_by_id[iid] not in allowed[name]:
                errs.append(
                    f"explanation.{name} lists ingredient {iid} witnessed as "
                    f"{kind_by_id[iid]!r}"
                )
            if iid in covered:
                errs.append(f"explanation lists ingredient {iid} twice")
            covered.add(iid)
    unwitnessed_in_lists = set(kind_by_id) - covered
    if unwitnessed_in_lists:
        errs.append(
            "explanation does not partition witnesses; unwitnessed ids in lists: "
            f"{sorted(unwitnessed_in_lists)}"
        )
    return errs


def _witness_errors(item: Any, required: bool) -> list[str]:
    if not isinstance(item, dict):
        return ["witness is not an object"]
    errs: list[str] = []
    kinds = REQUIRED_KINDS if required else OPTIONAL_KINDS
    kind = item.get("kind")
    if kind not in kinds:
        errs.append(f"kind {kind!r} is not a valid {'required' if required else 'optional'} kind")
        return errs

    iid = item.get("ingredient_id")
    if not isinstance(iid, int) or isinstance(iid, bool) or iid < 1:
        errs.append(f"ingredient_id must be a positive integer, got {iid!r}")

    def _grams(name: str) -> float | None:
        value = item.get(name)
        if value is None:
            return None
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
            errs.append(f"{kind}: {name} must be a non-negative number, got {value!r}")
            return None
        return float(value)

    basis = item.get("basis_lots")
    basis_allowed = kind in (
        "required_satisfied",
        "quantity_unknown",
        "shortage",
        "optional_present",
        "optional_unknown",
    )
    if basis_allowed:
        if not isinstance(basis, list) or not basis:
            errs.append(f"{kind}: basis_lots must be a non-empty list")
        else:
            for lot in basis:
                if not isinstance(lot, dict):
                    errs.append(f"{kind}: basis lot is not an object")
                    continue
                lot_iid = lot.get("ingredient_id")
                if not isinstance(lot_iid, int) or isinstance(lot_iid, bool):
                    errs.append(f"{kind}: basis lot ingredient_id must be an integer")
                elif lot_iid != iid:
                    errs.append(f"{kind}: basis lot cites ingredient {lot_iid}, not {iid}")
                est = lot.get("is_estimate")
                if not isinstance(est, bool):
                    errs.append(f"{kind}: basis lot is_estimate must be a boolean")
                grams = lot.get("known_grams")
                if est and grams is not None:
                    errs.append(f"{kind}: estimated basis lot must carry known_grams null")
                if not est and not isinstance(grams, (int, float)):
                    errs.append(f"{kind}: known basis lot must carry a numeric known_grams")
    elif basis is not None:
        errs.append(f"{kind}: basis_lots must be omitted")

    amounts_allowed = kind in ("required_satisfied", "shortage", "optional_present")
    if "available_grams" in item and not amounts_allowed:
        errs.append(
            f"{kind}: available_grams must be omitted "
            f"(unknown quantities are retained, never invented)"
        )
    if amounts_allowed:
        if _grams("available_grams") is None and "available_grams" not in item:
            errs.append(f"{kind}: available_grams is required")

    if required and kind != "explicit_exclusion":
        if _grams("required_grams") is None and "required_grams" not in item:
            errs.append(f"{kind}: required_grams is required")
    elif required:
        if "required_grams" in item:
            _grams("required_grams")

    via = item.get("excluded_via")
    if kind in ("explicit_exclusion", "optional_excluded"):
        if not isinstance(via, list) or not via or not all(isinstance(s, str) and s for s in via):
            errs.append(f"{kind}: excluded_via must be a non-empty list of strings")
    elif via is not None:
        errs.append(f"{kind}: excluded_via must be omitted")
    return errs


def make_source_binding(
    inventory_revision: str, profile_revision: str, recipe_revision: str, sha256s: dict[str, str]
) -> dict[str, str]:
    return {
        "inventory_revision": inventory_revision,
        "profile_revision": profile_revision,
        "recipe_revision": recipe_revision,
        "states_sha256": sha256s["states_sha256"],
        "catalog_sha256": sha256s["catalog_sha256"],
        "claims_sha256": sha256s["claims_sha256"],
    }


def make_explanation(kind: str, truth: dict[str, Any]) -> dict[str, Any]:
    """Explanation lists straight from derived ground truth."""
    if kind == "complete":
        return {"kind": "complete", "statement": "all required ingredients on hand"}
    return {
        "kind": "missing_list",
        "missing": list(truth["missing_ids"]),
        "excluded": list(truth["excluded_ids"]),
        "unknown_quantity": list(truth["unknown_ids"]),
        "satisfied": list(truth["satisfied_ids"]),
    }


def dumps(cert: dict[str, Any]) -> str:
    """Canonical JSON line (sorted keys, no whitespace) for stable records."""
    return json.dumps(cert, sort_keys=True, separators=(",", ":"))
