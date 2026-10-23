#!/usr/bin/env python3
"""Extract the probe list from differential/main.swift into probes.jsonl.

Single source of truth for probe inputs: the Swift probe source. The GRDB
replay package and the Python catalog diff both consume probes.jsonl, so
probe parity with the published 186-case lexicon differential is structural,
not copied by hand.

Usage: python3 extract_probes.py [--check]
  default     writes probes.jsonl next to main.swift
  --check     exits 0 iff probes.jsonl is already up to date
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAIN = HERE / "main.swift"

# array variable -> probe kind, per main.swift's append loops
ARRAYS = {
    "classNames": "label",
    "lexiconProbes": "lexicon",
    "ocrProbes": "ocr",
}


def parse(source: str) -> list[dict]:
    probes: list[dict] = []
    for var, kind in ARRAYS.items():
        body = re.search(rf"let {var} = \[(.*?)\]", source, re.DOTALL)
        if body is None:
            raise SystemExit(f"main.swift: array `{var}` not found")
        items = re.findall(r'"((?:[^"\\]|\\.)*)"', body.group(1))
        for item in items:
            probes.append({"kind": kind, "input": json.loads(f'"{item}"')})
    loop = re.findall(r'for (?:name|text) in (\w+)', source)
    expected = [v for v in ARRAYS]
    if sorted(loop) != sorted(expected):
        raise SystemExit(f"main.swift: append loops {loop} do not cover {expected}")
    return probes


def main() -> None:
    probes = parse(MAIN.read_text(encoding="utf-8"))
    if len(probes) != 186:
        raise SystemExit(f"expected 186 probes, parsed {len(probes)} — main.swift changed?")
    payload = "".join(json.dumps(p, sort_keys=True) + "\n" for p in probes)
    out = HERE / "probes.jsonl"
    if "--check" in sys.argv:
        if out.read_text(encoding="utf-8") != payload:
            raise SystemExit("probes.jsonl is stale vs main.swift")
        print("probes.jsonl up to date")
        return
    out.write_text(payload, encoding="utf-8")
    kinds: dict[str, int] = {}
    for p in probes:
        kinds[p["kind"]] = kinds.get(p["kind"], 0) + 1
    print(f"wrote {len(probes)} probes: {kinds}")


if __name__ == "__main__":
    main()
