#!/usr/bin/env python3
"""Standalone witness verifier for feasibility explanations.

Usage:
  python3 tools/feasibility-witnesses/verify.py \
      --records tools/feasibility-witnesses/records.jsonl \
      --out tools/feasibility-witnesses/results \
      [--fixtures tools/feasibility-witnesses/fixtures]

For every certificate record the verifier decides, from the pinned fixtures
alone:

  outcome: accepted | rejected
    rejected.failure_class:
      structure            — the certificate is not a well-formed typed record
      source_binding       — revisions do not recompute from fixture bytes
                             (forged IDs, stale sources, wrong profile version)
      claim_not_in_source  — the claim kind is not backed by the pinned
                             production-replay claim for the (state, recipe)
      incomplete_witness   — some required/optional recipe row has no witness,
                             or an explanation list references nothing witnessed
      unsupported_witness  — a witness contradicts the sources (kind or payload:
                             wrong numbers, wrong lot basis, mislabeled exclusion)

  explanation_verdict (accepted records only): supported | unsupported
    A complete_match claim is supported only when no required ingredient is
    absent/short/excluded and no diet tag is violated. A missing_list claim is
    supported only when at least one required ingredient is genuinely
    absent/short or excluded (never vacuous). A diet-tag conflict is decisive
    only for complete_match claims: a missing_list explanation never asserted
    the recipe is diet-compliant.

Unknown quantities are never guessed: a quantity_unknown witness that asserts
an amount is structurally invalid, and the verifier carries unknowns through
as unknown.

Exit codes: 0 = every record classified (accepts and rejects are both
classifications); 2 = usage or fixture error; 3 = verifier-internal error.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import certificate
import sources
from sources import GRAM_TOLERANCE, SourceBundle

TOOL_DIR = Path(__file__).resolve().parent
DEFAULT_FIXTURES = TOOL_DIR / "fixtures"

FAILURE_CLASSES = (
    "structure",
    "source_binding",
    "claim_not_in_source",
    "incomplete_witness",
    "unsupported_witness",
)


def _grams_close(a: Any, b: Any) -> bool:
    return (
        isinstance(a, (int, float))
        and not isinstance(a, bool)
        and abs(float(a) - float(b)) <= GRAM_TOLERANCE
    )


def _basis_equal(witness_basis: Any, expected_basis: Any) -> bool:
    if not isinstance(witness_basis, list):
        return False
    a = sorted(json.dumps(lot, sort_keys=True) for lot in witness_basis if isinstance(lot, dict))
    b = sorted(json.dumps(lot, sort_keys=True) for lot in expected_basis)
    return a == b


def check_source_binding(bundle: SourceBundle, cert: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    binding = cert["source_binding"]
    for key, digest in bundle.binding_sha256s().items():
        if binding.get(key) != digest:
            errs.append(f"source_binding.{key} does not match fixture bytes (stale or forged)")
    claim = cert["claim"]
    state_id = claim.get("state_id")
    recipe_id = claim.get("recipe_id")
    if isinstance(state_id, int) and not isinstance(state_id, bool):
        state = bundle.states.get(state_id)
        if state is None:
            errs.append(f"state_id {state_id} not in pinned states fixture")
        else:
            expected_inv = sources.inventory_revision_id(bundle.states_sha256, state_id)
            if binding.get("inventory_revision") != expected_inv:
                errs.append("inventory_revision does not recompute from fixture bytes")
            apv = (state.get("profile") or {}).get("allergen_preferences_version")
            expected_prof = sources.profile_revision_id(
                bundle.states_sha256, state_id, int(apv or 0)
            )
            if binding.get("profile_revision") != expected_prof:
                errs.append("profile_revision does not recompute from fixture bytes")
    if isinstance(recipe_id, int) and not isinstance(recipe_id, bool):
        if recipe_id not in bundle.catalog:
            errs.append(f"recipe_id {recipe_id} not in pinned catalog fixture")
        else:
            expected_rec = sources.recipe_revision_id(bundle.catalog_sha256, recipe_id)
            if binding.get("recipe_revision") != expected_rec:
                errs.append("recipe_revision does not recompute from fixture bytes")
    return errs


def check_claim_provenance(bundle: SourceBundle, cert: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    claim = cert["claim"]
    state_id, recipe_id, kind = claim.get("state_id"), claim.get("recipe_id"), claim.get("kind")
    row = (
        bundle.claims.get(state_id)
        if isinstance(state_id, int) and not isinstance(state_id, bool)
        else None
    )
    if row is None:
        errs.append(f"no pinned production claim row for state_id {state_id}")
        return errs
    if kind == "complete_match":
        if recipe_id not in (row.get("makeable_ids") or []):
            errs.append(
                f"complete_match not backed by pinned production claim (recipe {recipe_id} "
                f"not in makeable_ids for state {state_id})"
            )
    elif kind == "missing_list":
        if recipe_id not in (row.get("near_match_ids") or []):
            errs.append(
                f"missing_list not backed by pinned production claim (recipe {recipe_id} "
                f"not in near_match_ids for state {state_id})"
            )
    return errs


def check_coverage_and_support(bundle: SourceBundle, cert: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    claim = cert["claim"]
    recipe = bundle.catalog[claim["recipe_id"]]

    truth = bundle.derive_all(claim["state_id"], claim["recipe_id"])
    required_rows: dict[int, float] = {int(i): float(g) for i, g in recipe["required"]}
    optional_rows: set[int] = {int(i) for i, _ in recipe["optional"]}

    witnessed: dict[int, dict[str, Any]] = {}
    for item in cert["required_witnesses"]:
        iid = item.get("ingredient_id")
        if isinstance(iid, int) and not isinstance(iid, bool):
            if iid not in required_rows:
                errs.append(
                    f"required witness for ingredient {iid} has no required recipe row "
                    f"(optional-to-required conflation or forged id)"
                )
            witnessed[iid] = item
    missing_witnesses = sorted(set(required_rows) - set(witnessed))
    if missing_witnesses:
        errs.append(
            f"incomplete witness set: required ingredients with no witness: {missing_witnesses}"
        )

    for iid, grams in required_rows.items():
        item = witnessed.get(iid)
        if item is None:
            continue
        if "required_grams" in item and not _grams_close(item.get("required_grams"), grams):
            errs.append(
                f"witness for ingredient {iid} claims required_grams "
                f"{item.get('required_grams')}, recipe row requires {grams}"
            )
        expected = truth["required"][iid]
        if item.get("kind") != expected["kind"]:
            errs.append(
                f"witness for ingredient {iid} claims kind {item.get('kind')!r}, "
                f"sources derive {expected['kind']!r}"
            )
            continue
        if item.get("kind") in ("required_satisfied", "shortage"):
            if not _grams_close(item.get("available_grams"), expected["available_grams"]):
                errs.append(
                    f"witness for ingredient {iid} claims available_grams "
                    f"{item.get('available_grams')}, sources derive "
                    f"{expected['available_grams']}"
                )
            if not _basis_equal(item.get("basis_lots"), expected.get("basis_lots", [])):
                errs.append(
                    f"witness for ingredient {iid} cites a lot basis the sources do not show"
                )
        elif item.get("kind") in ("quantity_unknown", "optional_unknown"):
            if not _basis_equal(item.get("basis_lots"), expected.get("basis_lots", [])):
                errs.append(
                    f"witness for ingredient {iid} cites a lot basis the sources do not show"
                )
        elif item.get("kind") == "explicit_exclusion":
            if sorted(item.get("excluded_via") or []) != expected["excluded_via"]:
                errs.append(
                    f"witness for ingredient {iid} claims exclusion via "
                    f"{item.get('excluded_via')}, sources derive {expected['excluded_via']}"
                )

    optional_witnessed: dict[int, dict[str, Any]] = {}
    for item in cert["optional_witnesses"]:
        iid = item.get("ingredient_id")
        if isinstance(iid, int) and not isinstance(iid, bool):
            if iid not in optional_rows:
                errs.append(f"optional witness for ingredient {iid} has no optional recipe row")
            optional_witnessed[iid] = item
    missing_optional = sorted(optional_rows - set(optional_witnessed))
    if missing_optional:
        errs.append(
            f"incomplete witness set: optional ingredients with no witness: {missing_optional}"
        )
    for iid, item in optional_witnessed.items():
        if iid not in optional_rows:
            continue
        expected = truth["optional"][iid]
        if item.get("kind") != expected["kind"]:
            errs.append(
                f"optional witness for ingredient {iid} claims kind {item.get('kind')!r}, "
                f"sources derive {expected['kind']!r}"
            )
            continue
        if item.get("kind") == "optional_present":
            if not _grams_close(item.get("available_grams"), expected["available_grams"]):
                errs.append(
                    f"optional witness for ingredient {iid} claims available_grams "
                    f"{item.get('available_grams')}, sources derive "
                    f"{expected['available_grams']}"
                )
            if not _basis_equal(item.get("basis_lots"), expected.get("basis_lots", [])):
                errs.append(
                    f"optional witness for ingredient {iid} cites a lot basis the sources "
                    f"do not show"
                )
        elif item.get("kind") == "optional_unknown":
            if not _basis_equal(item.get("basis_lots"), expected.get("basis_lots", [])):
                errs.append(
                    f"optional witness for ingredient {iid} cites a lot basis the sources "
                    f"do not show"
                )
        elif item.get("kind") == "optional_excluded":
            if sorted(item.get("excluded_via") or []) != expected["excluded_via"]:
                errs.append(
                    f"optional witness for ingredient {iid} claims exclusion via "
                    f"{item.get('excluded_via')}, sources derive {expected['excluded_via']}"
                )

    if truth["tag_violation"] and claim.get("kind") == "complete_match":
        errs.append("diet-required tag missing from recipe, not represented in the certificate")
    return errs


def explanation_verdict(bundle: SourceBundle, cert: dict[str, Any]) -> tuple[str, list[str]]:
    claim = cert["claim"]
    truth = bundle.derive_all(claim["state_id"], claim["recipe_id"])
    if claim["kind"] == "complete_match":
        reasons: list[str] = []
        if truth["missing_ids"]:
            reasons.append(f"required ingredients absent or short: {truth['missing_ids']}")
        if truth["excluded_ids"]:
            reasons.append(
                f"required ingredients excluded by health profile: {truth['excluded_ids']}"
            )
        if truth["tag_violation"]:
            reasons.append("recipe lacks a diet-required tag")
        return ("supported" if not reasons else "unsupported"), reasons
    explanation = cert["explanation"]
    reasons = []
    if not explanation.get("missing") and not explanation.get("excluded"):
        reasons.append("missing-list explanation names nothing missing or excluded")
    return ("supported" if not reasons else "unsupported"), reasons


def _is_coverage_error(err: str) -> bool:
    """Coverage gaps (witness set vs recipe rows) -> incomplete; content mismatches -> unsupported."""
    return (
        err.startswith("incomplete witness set")
        or "has no required recipe row" in err
        or "has no optional recipe row" in err
    )


def verify_record(bundle: SourceBundle, cert: Any, line_no: int) -> dict[str, Any]:
    if not isinstance(cert, dict):
        return {
            "record_id": f"line-{line_no}",
            "outcome": "rejected",
            "failure_class": "structure",
            "reasons": ["record is not a JSON object"],
            "explanation_verdict": None,
        }
    record_id = (
        cert.get("record_id") if isinstance(cert.get("record_id"), str) else f"line-{line_no}"
    )
    mutation = cert.get("mutation") if isinstance(cert.get("mutation"), dict) else None

    def verdict(outcome: str, failure_class: str | None, reasons: list[str]) -> dict[str, Any]:
        claim = cert.get("claim") if isinstance(cert.get("claim"), dict) else {}
        v: dict[str, Any] = {
            "record_id": record_id,
            "outcome": outcome,
            "failure_class": failure_class,
            "reasons": reasons,
            "explanation_verdict": None,
            "claim_kind": claim.get("kind"),
            "state_id": claim.get("state_id"),
            "recipe_id": claim.get("recipe_id"),
        }
        if mutation is not None:
            v["mutation"] = mutation
        return v

    structural = certificate.structural_errors(cert)
    if structural:
        return verdict("rejected", "structure", structural)

    binding_errs = check_source_binding(bundle, cert)
    if binding_errs:
        return verdict("rejected", "source_binding", binding_errs)

    provenance_errs = check_claim_provenance(bundle, cert)
    if provenance_errs:
        return verdict("rejected", "claim_not_in_source", provenance_errs)

    support_errs = check_coverage_and_support(bundle, cert)
    if support_errs:
        failure_class = (
            "incomplete_witness"
            if any(_is_coverage_error(e) for e in support_errs)
            else "unsupported_witness"
        )
        return verdict("rejected", failure_class, support_errs)

    exp_verdict, reasons = explanation_verdict(bundle, cert)
    return verdict("accepted", None, reasons) | {"explanation_verdict": exp_verdict}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", required=True, help="certificate records (JSONL) to verify")
    parser.add_argument("--out", required=True, help="output directory for verdicts and summary")
    parser.add_argument("--fixtures", default=str(DEFAULT_FIXTURES), help="pinned fixture directory")
    args = parser.parse_args(argv)

    records_path = Path(args.records)
    out_dir = Path(args.out)
    if not records_path.is_file():
        print(f"error: records file not found: {records_path}", file=sys.stderr)
        return 2

    try:
        bundle = SourceBundle(Path(args.fixtures))
    except sources.SourceError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    verdicts: list[dict[str, Any]] = []
    with open(records_path, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                cert = json.loads(line)
            except json.JSONDecodeError as e:
                verdicts.append(
                    {
                        "record_id": f"line-{line_no}",
                        "outcome": "rejected",
                        "failure_class": "structure",
                        "reasons": [f"unparseable JSON line: {e}"],
                        "explanation_verdict": None,
                    }
                )
                continue
            verdicts.append(verify_record(bundle, cert, line_no))

    summary = summarize(verdicts, bundle)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "verdicts.jsonl").write_text(
        "".join(json.dumps(v, sort_keys=True) + "\n" for v in verdicts), encoding="utf-8"
    )
    (out_dir / "summary.json").write_text(
        json.dumps(summary, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"{summary['records']} records: {summary['accepted']} accepted, "
        f"{summary['rejected']} rejected "
        f"({', '.join(f'{k}={v}' for k, v in sorted(summary['rejected_by_class'].items())) or 'none'}); "
        f"explanations: {summary['supported']} supported, {summary['unsupported']} unsupported"
    )
    return 0


def summarize(verdicts: list[dict[str, Any]], bundle: SourceBundle) -> dict[str, Any]:
    rejected_by_class: dict[str, int] = {}
    for v in verdicts:
        if v["outcome"] == "rejected":
            rejected_by_class[v["failure_class"]] = rejected_by_class.get(v["failure_class"], 0) + 1
    return {
        "records": len(verdicts),
        "accepted": sum(1 for v in verdicts if v["outcome"] == "accepted"),
        "rejected": sum(1 for v in verdicts if v["outcome"] == "rejected"),
        "rejected_by_class": rejected_by_class,
        "supported": sum(1 for v in verdicts if v.get("explanation_verdict") == "supported"),
        "unsupported": sum(1 for v in verdicts if v.get("explanation_verdict") == "unsupported"),
        "fixtures": bundle.binding_sha256s(),
    }


if __name__ == "__main__":
    sys.exit(main())
