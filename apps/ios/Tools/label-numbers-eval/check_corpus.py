#!/usr/bin/env python3
"""Integrity checks for the label-numbers corpus.

Validates schema, corpus composition, and — critically — that every recorded
truth is justified by the record's own lines:

- no *assumed transcription*: an observable entry's value must be numerically
  present in its evidence line (assumed values fail);
- no *invalid basis*: a basis-bearing observable entry requires a basis marker
  line in the record (missing marker fails); a basis-less container field must
  not claim a column basis;
- unobservable entries must carry a justified reason that is independently
  verified (value truly absent / unit truly absent / basis marker truly absent /
  field name truly absent / not declared);
- derivable arithmetic must hold where inputs exist (kJ<->kcal, salt<->sodium,
  per-portion vs per-100g within rounding, per-package vs per-serving).

Usage: python3 check_corpus.py [corpus/labels.jsonl]
Exit code 0 = corpus valid; nonzero with a list of violations otherwise.
"""

import json
import re
import sys
from collections import Counter
from decimal import Decimal, InvalidOperation
from pathlib import Path

from generate_corpus import (
    BASIS_MARKERS, BASES, CANONICAL_FIELDS, FIELD_NAMES, FIELD_UNITS,
    FAMILIES, KJ_PER_KCAL, SALT_PER_SODIUM,
)

NUM_TOKEN_RE = re.compile(r"\d[\d.,]*")

VALID_REASONS = ("value_not_in_text", "unit_missing", "basis_header_missing",
                 "not_declared", "field_name_missing")


def _dec(s):
    try:
        return Decimal(str(s))
    except InvalidOperation:
        return None


def _numeric_present(value, text):
    """Decimal-equality presence of value among numeric tokens of text."""
    if value is None:
        return False
    target = _dec(value)
    if target is None:
        return str(value) in text
    for tok in NUM_TOKEN_RE.findall(text):
        tok = tok.strip(".,")
        if not tok:
            continue
        for cand in {tok, tok.replace(",", "")}:
            d = _dec(cand)
            if d is not None and d == target:
                return True
    return False


def _basis_marker_present(basis, lines):
    if basis is None:
        return True
    return any(re.search(BASIS_MARKERS[basis], l) for l in lines)


def _unit_visible(unit, line):
    return bool(re.search(rf"(?<![A-Za-z0-9]){re.escape(unit)}(?![A-Za-z0-9])", line))


def check_record(rec, errors, where):
    for key in ("record_id", "group_id", "variant", "family", "variant_kind",
                "source", "lines", "fields"):
        if key not in rec:
            errors.append(f"{where}: missing key {key}")
            return
    if rec["family"] not in FAMILIES:
        errors.append(f"{where}: unknown family {rec['family']}")
    if rec["variant_kind"] not in ("clean", "corrupted"):
        errors.append(f"{where}: bad variant_kind {rec['variant_kind']}")
    if rec["source"].get("kind") != "synthetic":
        errors.append(f"{where}: source must be explicitly synthetic")
    if not rec["source"].get("reference"):
        errors.append(f"{where}: source.reference (regulator format) missing")
    if not rec["lines"]:
        errors.append(f"{where}: empty lines")
    for k, d in rec["fields"].items():
        fid = k.split("@")[0]
        if fid not in CANONICAL_FIELDS:
            errors.append(f"{where}/{k}: unknown field {fid}")
            continue
        basis = d.get("basis")
        val = d.get("value")
        obs = d.get("observable")
        ev = d.get("evidence_line")
        unit = d.get("unit")
        reason = d.get("unobservability_reason")

        if fid in ("serving_size", "servings_per_container") and basis is not None:
            errors.append(f"{where}/{k}: container-level field claims column basis {basis}")
        if basis is not None and basis not in BASES:
            errors.append(f"{where}/{k}: unknown basis {basis}")

        if obs:
            if val is None:
                errors.append(f"{where}/{k}: observable entry with null value (assumed transcription)")
                continue
            if ev is None or not (0 <= ev < len(rec["lines"])):
                errors.append(f"{where}/{k}: evidence_line {ev} out of range")
                continue
            line = rec["lines"][ev]
            if fid == "serving_size":
                if " ".join(str(val).split()).lower() not in " ".join(line.split()).lower():
                    errors.append(f"{where}/{k}: serving size text '{val}' not in evidence line (assumed transcription)")
            elif not _numeric_present(val, line):
                errors.append(f"{where}/{k}: value '{val}' not in evidence line '{line}' (assumed transcription)")
            # declared unit must match the canonical unit (sodium may be g or mg)
            if fid == "sodium_mg":
                if unit not in ("mg", "g"):
                    errors.append(f"{where}/{k}: sodium unit must be mg or g, got {unit}")
            elif unit != FIELD_UNITS[fid]:
                errors.append(f"{where}/{k}: unit {unit} != canonical {FIELD_UNITS[fid]}")
            # mass units must be visible as tokens on the evidence line; energy
            # wording varies by format ("Calories" vs "kcal"), so it is not required
            if unit in ("g", "mg") and not _unit_visible(unit, line):
                errors.append(f"{where}/{k}: unit '{unit}' not visible on evidence line")
            # invalid basis: marker must be present somewhere in the record
            if not _basis_marker_present(basis, rec["lines"]):
                errors.append(f"{where}/{k}: observable entry claims basis {basis} but no basis marker line exists (invalid basis)")
        else:
            if reason not in VALID_REASONS:
                errors.append(f"{where}/{k}: unobservable entry without a valid justification (got {reason})")
                continue
            if reason == "value_not_in_text":
                # scope to the evidence line when known: another field's line may
                # legitimately contain the same number without restoring this one
                scope = rec["lines"][ev] if ev is not None and 0 <= ev < len(rec["lines"]) else " ".join(rec["lines"])
                if val is not None and _numeric_present(val, scope):
                    errors.append(f"{where}/{k}: claims value_not_in_text but value '{val}' is present")
            elif reason == "unit_missing":
                if ev is None or not (0 <= ev < len(rec["lines"])):
                    errors.append(f"{where}/{k}: unit_missing with invalid evidence_line")
                else:
                    line = rec["lines"][ev]
                    if val is not None and not _numeric_present(val, line):
                        errors.append(f"{where}/{k}: unit_missing but the value is also gone (should be value_not_in_text)")
                    if unit and _unit_visible(unit, line):
                        errors.append(f"{where}/{k}: unit_missing but unit '{unit}' still visible")
            elif reason == "basis_header_missing":
                if _basis_marker_present(basis, rec["lines"]):
                    errors.append(f"{where}/{k}: basis_header_missing but marker for {basis} still present")
            elif reason == "field_name_missing":
                if ev is None or not (0 <= ev < len(rec["lines"])):
                    errors.append(f"{where}/{k}: field_name_missing with invalid evidence_line")
                else:
                    line = rec["lines"][ev]
                    if val is not None and not _numeric_present(val, line):
                        errors.append(f"{where}/{k}: field_name_missing but the value is also gone (should be value_not_in_text)")
                    if any(w in line for w in FIELD_NAMES.get(fid, [])):
                        errors.append(f"{where}/{k}: field_name_missing but a name for {fid} is still visible")
            elif reason == "not_declared" and val is not None:
                errors.append(f"{where}/{k}: not_declared entry must have null value")

    missing = [f for f in CANONICAL_FIELDS if not any(k.split("@")[0] == f for k in rec["fields"])]
    if missing:
        errors.append(f"{where}: truth entries missing for fields {missing}")

    _check_arithmetic(rec, errors, where)


def _close(a, b, tol):
    return abs(a - b) <= tol


def _check_arithmetic(rec, errors, where):
    """Verify derivable relations, only where both conversion inputs exist."""
    f = rec["fields"]

    def val(k):
        d = f.get(k)
        if not d or not d["observable"] or d["value"] is None:
            return None
        return _dec(d["value"])

    for b in BASES:
        kj, kcal = val(f"energy_kj@{b}"), val(f"energy_kcal@{b}")
        # both are integer-displayed conversions of one underlying value, so the
        # displayed pair can legitimately differ by up to ~2.6 kJ under rounding
        if kj is not None and kcal is not None and not _close(kj, kcal * Decimal(str(KJ_PER_KCAL)), Decimal("3")):
            errors.append(f"{where}: kJ {kj} != kcal {kcal} x {KJ_PER_KCAL} (tol 3) on basis {b}")
        salt = val(f"salt_g@{b}")
        sod = None
        sod_d = f.get(f"sodium_mg@{b}")
        if sod_d and sod_d["observable"] and sod_d["value"] is not None:
            sod = _dec(sod_d["value"]) / (Decimal(1000) if sod_d["unit"] == "mg" else Decimal(1))
        if sod is not None and salt is not None and not _close(salt, sod * Decimal(str(SALT_PER_SODIUM)), Decimal("0.05")):
            errors.append(f"{where}: salt {salt} g != sodium {sod} g x {SALT_PER_SODIUM} on basis {b}")

    spc = val("servings_per_container")
    if spc is not None:
        for fid in ("energy_kcal", "fat_g", "carbohydrate_g", "protein_g", "sodium_mg"):
            ps, pp = val(f"{fid}@per_serving"), val(f"{fid}@per_package")
            if ps is not None and pp is not None:
                expect = ps * spc
                if not _close(pp, expect, max(Decimal("1"), expect * Decimal("0.001"))):
                    errors.append(f"{where}: per_package {fid} {pp} != per_serving {ps} x servings {spc}")

    # per-portion vs per-100g using the portion grams stated in the header line
    header = next((l for l in rec["lines"] if re.search(BASIS_MARKERS["per_portion"], l)), None)
    if header and rec["family"] == "eu_per_portion":
        m = re.search(r"per portion \((\d+) g\)", header)
        if m:
            grams = Decimal(m.group(1))
            for fid in ("energy_kcal", "energy_kj", "fat_g", "carbohydrate_g", "protein_g", "salt_g"):
                p100, pport = val(f"{fid}@per_100g"), val(f"{fid}@per_portion")
                if p100 is not None and pport is not None:
                    expect = p100 * grams / Decimal(100)
                    tol = max(Decimal("3"), expect * Decimal("0.01"))
                    if not _close(pport, expect, tol):
                        errors.append(f"{where}: per_portion {fid} {pport} != {p100} x {grams}/100 (tol {tol})")


def check_corpus(path):
    errors = []
    records = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh):
            where = f"line {n + 1}"
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append(f"{where}: invalid JSON ({e})")
                continue
            records.append(rec)
            check_record(rec, errors, where)

    if len(records) < 400:
        errors.append(f"corpus too small: {len(records)} records (<400)")
    for fam in FAMILIES:
        n = sum(1 for r in records if r["family"] == fam)
        if n < 20:
            errors.append(f"family {fam} underrepresented: {n} records")
    corrupted = sum(1 for r in records if r["variant_kind"] == "corrupted")
    if corrupted == 0:
        errors.append("no corrupted variants present")
    groups = {r["group_id"] for r in records}
    if len(groups) < 100:
        errors.append(f"too few groups: {len(groups)}")
    per_group = Counter((r["group_id"], r["variant_kind"]) for r in records)
    for g in groups:
        if per_group[(g, "clean")] != 1:
            errors.append(f"group {g}: expected exactly 1 clean variant")
    return records, errors


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "corpus/labels.jsonl"
    if not Path(path).exists():
        print(f"corpus not found: {path}; run generate_corpus.py first", file=sys.stderr)
        return 2
    records, errors = check_corpus(path)
    fams = {}
    for r in records:
        fams.setdefault(r["family"], {"clean": 0, "corrupted": 0})
        fams[r["family"]][r["variant_kind"]] += 1
    print(f"records: {len(records)}  groups: {len({r['group_id'] for r in records})}")
    for fam, c in sorted(fams.items()):
        print(f"  {fam}: {c['clean']} clean + {c['corrupted']} corrupted")
    if errors:
        print(f"\nFAILED with {len(errors)} violation(s):")
        for e in errors[:50]:
            print(f"  - {e}")
        if len(errors) > 50:
            print(f"  ... and {len(errors) - 50} more")
        return 1
    print("corpus OK: schema, observability justifications, and derivable arithmetic all verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
