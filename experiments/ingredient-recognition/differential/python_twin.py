#!/usr/bin/env python3
"""Differential twin: answer the Swift probe's inputs with the Python port and
diff field by field. Any DIFF line is a port divergence to fix or document.

The catalog resolver path is verified separately (resolver_golden_test), since
the Swift probe cannot link GRDB and answers label probes with catalog disabled.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import sys as _sys

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
_sys.path.insert(0, str(EXPERIMENT_ROOT / "resolution"))

from app_resolution import IngredientLexicon, resolve_label  # noqa: E402


class _NoCatalog:
    def resolve(self, raw: str, matching: str = "exact") -> int | None:
        return None


def answers(kind: str, text: str, lexicon: IngredientLexicon) -> dict:
    out: dict = {"kind": kind, "input": text}
    if kind == "label":
        resolved = resolve_label(text, lexicon, _NoCatalog())
        out["resolveLabel_curatedOnly"] = (
            str(resolved.ingredient_id) if resolved else None
        )
        out["lexiconResolve"] = _s(lexicon.resolve(text))
    elif kind == "lexicon":
        out["lexiconResolve"] = _s(lexicon.resolve(text))
    elif kind == "ocr":
        out["unsupportedPhrases"] = "|".join(lexicon.unsupported_food_phrases_in(text))
        out["masked"] = lexicon.masking_unsupported_food_phrases(text)
        m = lexicon.resolve_from_text_detailed(text)
        out["matchId"] = str(m.ingredient_id) if m else None
        out["matchKind"] = m.kind if m else None
        out["matchToken"] = m.matched_token if m else None
        out["resolveFromText"] = _s(lexicon.resolve_from_text(text))
    return out


def _s(v: int | None) -> str | None:
    return str(v) if v is not None else None


def main() -> None:
    swift_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("swift_probe_results.jsonl")
    lexicon = IngredientLexicon()
    n_diff = 0
    n_cases = 0
    for line in swift_path.read_text().splitlines():
        swift = json.loads(line)
        mine = answers(swift["kind"], swift["input"], lexicon)
        n_cases += 1
        if mine != swift:
            n_diff += 1
            print("DIFF", json.dumps({"input": swift["input"], "kind": swift["kind"]}, sort_keys=True))
            for k in sorted(set(mine) | set(swift)):
                if mine.get(k) != swift.get(k):
                    print(f"  {k}: swift={swift.get(k)!r} python={mine.get(k)!r}")
    print(f"cases={n_cases} diffs={n_diff}")
    sys.exit(1 if n_diff else 0)


if __name__ == "__main__":
    main()
