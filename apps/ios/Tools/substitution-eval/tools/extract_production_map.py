#!/usr/bin/env python3
"""Extract the production substitution pairs from SubstitutionService.swift.

Parses the literal `add(...)` calls in `buildMap()` — the single source of truth —
and writes apps/ios/Tools/substitution-eval/evidence/pairs.snapshot.json plus a
SHA-256 of the extracted source region so later runs can detect drift between
this snapshot and the Swift file.

Usage:
    python3 tools/extract_production_map.py [--service PATH] [--out PATH]

Deterministic: same Swift source -> byte-identical snapshot.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REASON_MAP = {
    "vegan": "vegan",
    "dairyFree": "dairyFree",
    "glutenFree": "glutenFree",
    "vegetarian": "vegetarian",
    "lighter": "lighter",
    "lowCarb": "lowCarb",
    "similar": "similar",
}

ADD_RE = re.compile(
    r"add\(\s*(\d+)\s*,\s*(\d+)\s*,\s*reasons:\s*\[([^\]]*)\]\s*,\s*"
    r"ratio:\s*([0-9.]+)\s*,\s*note:\s*\"((?:[^\"\\]|\\.)*)\"",
    re.S,
)


def parse_service(path: Path):
    text = path.read_text(encoding="utf-8")
    # Only the buildMap() region is authoritative. The hashed region EXCLUDES
    # the leading `private static func buildMap()` marker itself — the Swift
    # replay (Tests/SubstitutionEvidenceReplayTests.swift) slices the same way
    # (everything after the marker, up to `return map`), so both sides hash an
    # identical byte range.
    marker = "private static func buildMap()"
    start = text.index(marker)
    region = text[start + len(marker):]
    region_end = region.index("return map")
    region = region[:region_end]

    pairs = []
    for m in ADD_RE.finditer(region):
        orig, sub, reasons_raw, ratio, note = m.groups()
        # reasons are comma-separated enum cases like `.vegan, .dairyFree`
        reasons = []
        for tok in reasons_raw.split(","):
            tok = tok.strip().lstrip(".")
            if not tok:
                continue
            if tok not in REASON_MAP:
                raise ValueError(f"unknown SubstitutionReason case: {tok!r}")
            reasons.append(tok)
        pairs.append(
            {
                "originalId": int(orig),
                "substituteId": int(sub),
                "reasons": reasons,
                "ratio": float(ratio),
                "note": note.encode().decode("unicode_escape"),
            }
        )
    region_hash = hashlib.sha256(region.encode("utf-8")).hexdigest()
    return pairs, region_hash


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--service",
        default="apps/ios/Platform/Persistence/Services/SubstitutionService.swift",
    )
    ap.add_argument(
        "--out", default="apps/ios/Tools/substitution-eval/evidence/pairs.snapshot.json"
    )
    args = ap.parse_args()

    service = Path(args.service)
    if not service.exists():
        print(f"service source not found: {service}", file=sys.stderr)
        return 2
    pairs, region_hash = parse_service(service)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source_file": str(service),
        "source_region_sha256": region_hash,
        "pair_count": len(pairs),
        "pairs": pairs,
    }
    out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out}: {len(pairs)} pairs, region sha256={region_hash[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
