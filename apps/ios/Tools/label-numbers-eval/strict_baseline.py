#!/usr/bin/env python3
"""Strict tool baseline for the label-numbers corpus.

A deliberately rigid, single-purpose extractor used only as a comparison arm.
Unlike the production parser it is not limited to the parser's three fields:
it extracts all nine corpus fields wherever a rigid line-anchored pattern can.

Rules (documented because strictness is the whole point):
  - line-anchored: a pattern must match a single OCR line, no joining
  - first match wins per field key, later lines never overwrite
  - explicit unit tokens (kJ / kcal / g / mg) decide the field; a line whose
    number carries the wrong unit is not reinterpreted
  - EU declaration blocks are tracked with minimal state: a `Typical values
    per 100 g|ml` header starts a single-column block (basis per_100g or
    per_100ml); a `Typical values ... per 100 g ... per portion` header
    starts a two-column table (bases per_100g + per_portion)
  - US/CA patterns: ^Calories <n>, ^Serving size <text>, ^About <n> servings
    per container, ^Sodium [/ Sodium] <n> mg (first column only)
  - corrupted digits or damaged units simply fail the pattern: abstention

Everything unmatched is an abstention. The output carries the three
ReplayPrediction keys (so the production arm shape is unchanged) plus a
`fields` map keyed "<field>@<basis>" with everything the strict patterns
extracted, which the scorer reads for the strict arm only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SERVING_SIZE_RE = re.compile(r"^Serving size (.+)$")
CALORIES_RE = re.compile(r"^Calories +([0-9][0-9,]*)")
SERVINGS_RE = re.compile(r"^About ([0-9]+) servings per container$")
SODIUM_RE = re.compile(r"^Sodium(?: / Sodium)? +([0-9][0-9,]*) mg")

EU_TABLE_HEADER_RE = re.compile(r"^Typical values +per 100 g +per portion")
EU_HEADER_RE = re.compile(r"^Typical values +per 100 (g|ml)$")
ENERGY_SINGLE_RE = re.compile(r"^Energy +([0-9][0-9 ]*) ?kJ(?: */ *([0-9][0-9,]*) ?kcal)?$")
ENERGY_ROW_2COL_RE = re.compile(r"^Energy +([0-9][0-9 ]*) ?kJ +([0-9][0-9 ]*) ?kJ$")
KCAL_ROW_2COL_RE = re.compile(r"^([0-9][0-9,]*) ?kcal +([0-9][0-9,]*) ?kcal$")
NUTRIENT_2COL_RE = re.compile(r"^(Fat|Carbohydrate|Protein|Salt) +([0-9][0-9.,]*) ?g +([0-9][0-9.,]*) ?g$")
NUTRIENT_1COL_RE = re.compile(r"^(Fat|Carbohydrate|Protein|Salt) +([0-9][0-9.,]*) ?g$")

FIELD_NAMES = {"Fat": "fat_g", "Carbohydrate": "carbohydrate_g", "Protein": "protein_g", "Salt": "salt_g"}


def parse_number(token: str) -> float:
    token = token.replace(" ", "")
    if re.fullmatch(r"\d{1,3}(,\d{3})+", token):
        return float(token.replace(",", ""))
    if "," in token and "." not in token:
        return float(token.replace(",", "."))
    return float(token.replace(",", ""))


def extract(lines: list[str]) -> dict:
    serving_size = None
    calories = None
    servings = None
    sodium = None
    fields: dict[str, float] = {}
    bases: tuple[str, ...] | None = None

    for raw in lines:
        text = raw.strip()
        indented = raw[:1].isspace()

        if text.startswith("Typical values"):
            m = EU_TABLE_HEADER_RE.match(text)
            if m:
                bases = ("per_100g", "per_portion")
            else:
                m = EU_HEADER_RE.match(text)
                if m:
                    bases = (f"per_100{m.group(1)}",)
            continue

        if bases is not None:
            m = ENERGY_ROW_2COL_RE.match(text)
            if m:
                for basis, token in zip(bases, m.groups()):
                    fields.setdefault(f"energy_kj@{basis}", parse_number(token))
                continue
            m = KCAL_ROW_2COL_RE.match(text)
            if m and indented:
                for basis, token in zip(bases, m.groups()):
                    fields.setdefault(f"energy_kcal@{basis}", parse_number(token))
                continue
            m = NUTRIENT_2COL_RE.match(text)
            if m:
                name = FIELD_NAMES[m.group(1)]
                for basis, token in zip(bases, m.groups()[1:]):
                    fields.setdefault(f"{name}@{basis}", parse_number(token))
                continue
            m = NUTRIENT_1COL_RE.match(text)
            if m:
                fields.setdefault(f"{FIELD_NAMES[m.group(1)]}@{bases[0]}", parse_number(m.group(2)))
                continue
            m = ENERGY_SINGLE_RE.match(text)
            if m:
                fields.setdefault(f"energy_kj@{bases[0]}", parse_number(m.group(1)))
                if m.group(2):
                    fields.setdefault(f"energy_kcal@{bases[0]}", parse_number(m.group(2)))
                continue

        if serving_size is None:
            m = SERVING_SIZE_RE.match(text)
            if m:
                serving_size = m.group(1).strip()
        if calories is None:
            m = CALORIES_RE.match(text)
            if m:
                calories = float(m.group(1).replace(",", ""))
        if servings is None:
            m = SERVINGS_RE.match(text)
            if m:
                servings = float(m.group(1))
        if sodium is None:
            m = SODIUM_RE.match(text)
            if m:
                sodium = float(m.group(1).replace(",", ""))
                fields.setdefault("sodium_mg@per_serving", sodium)

    if calories is not None:
        fields.setdefault("energy_kcal@per_serving", calories)
    if servings is not None:
        fields.setdefault("servings_per_container", servings)
    if serving_size is not None:
        fields.setdefault("serving_size", serving_size)

    parsed = serving_size is not None or calories is not None or servings is not None or bool(fields)
    return {
        "keyword_positive": True,  # strict arm has no keyword gate
        "parsed": parsed,
        "calories_per_serving": calories,
        "serving_size": serving_size,
        "servings_per_container": servings,
        "fields": dict(sorted(fields.items())),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--corpus", default="corpus/labels.jsonl")
    ap.add_argument("--out", default="reports/strict_predictions.jsonl")
    args = ap.parse_args()

    out_lines = []
    with open(args.corpus, encoding="utf-8") as fh:
        for raw in fh:
            if not raw.strip():
                continue
            record = json.loads(raw)
            result = extract(record["lines"])
            out_lines.append(
                json.dumps(
                    {
                        "record_id": record["record_id"],
                        "family": record["family"],
                        "variant_kind": record["variant_kind"],
                        **result,
                    },
                    sort_keys=True,
                )
            )
    out = "\n".join(out_lines) + ("\n" if out_lines else "")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(out, encoding="utf-8")
    print(f"wrote {len(out_lines)} strict predictions to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
