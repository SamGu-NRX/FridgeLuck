#!/usr/bin/env python3
"""Extract the app's curated lexicon tables from Swift source into a JSON snapshot.

The benchmark's resolution layer must be the app's actual label-to-ingredient
resolution, not a re-typed copy of it. This script parses the Swift source of
`IngredientLexicon` (the single source of truth in the app) and emits a JSON
snapshot that `app_resolution.py` loads. The snapshot is committed; re-run this
script and diff it whenever the Swift file changes.

Parsed from: apps/ios/Capability/Core/Recognition/IngredientLexicon.swift
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
LEXICON_PATH = (
    REPO_ROOT
    / "apps"
    / "ios"
    / "Capability"
    / "Core"
    / "Recognition"
    / "IngredientLexicon.swift"
)


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def extract_dict(source: str, name: str) -> dict[str, str]:
    """Extract a [String: X] Swift dict literal by key."""
    m = re.search(rf"static let {name}\s*:\s*\[String:\s*\w+\]\s*=\s*\[", source)
    if not m:
        raise SystemExit(f"could not find dict {name}")
    start = m.end()
    depth = 1
    i = start
    while depth > 0:
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
        i += 1
    body = source[start : i - 1]
    body = strip_comments(body)
    out = {}
    for key, value in re.findall(r'"((?:[^"\\]|\\.)*)"\s*:\s*"([^"]*)"', body):
        out[key] = value
    # Int-valued dicts
    out_int = {}
    for key, value in re.findall(r'"((?:[^"\\]|\\.)*)"\s*:\s*(\d+)', body):
        out_int[key] = int(value)
    if out_int:
        return out_int
    return out


def extract_string_list(source: str, name: str) -> list[str]:
    m = re.search(rf"static let {name}\s*(:\s*\[[^\]]*\])?\s*=\s*\[", source)
    if not m:
        raise SystemExit(f"could not find list {name}")
    start = m.end()
    depth = 1
    i = start
    while depth > 0:
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
        i += 1
    body = strip_comments(source[start : i - 1])
    return re.findall(r'"((?:[^"\\]|\\.)*)"', body)


def extract_int_dict(source: str, name: str) -> dict[str, int]:
    m = re.search(rf"static let {name}\s*:\s*\[Int64:\s*String\]\s*=\s*\[", source)
    if not m:
        raise SystemExit(f"could not find int dict {name}")
    start = m.end()
    depth = 1
    i = start
    while depth > 0:
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
        i += 1
    body = strip_comments(source[start : i - 1])
    return {str(int(k)): v for k, v in re.findall(r"(\d+)\s*:\s*\"([^\"]*)\"", body)}


def main() -> None:
    source = LEXICON_PATH.read_text()
    snapshot = {
        "source_file": str(LEXICON_PATH.relative_to(REPO_ROOT)),
        "extracted_at_utc": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        )
        .isoformat()
        .replace("+00:00", "Z"),
        "labelToId": extract_dict(source, "labelToId"),
        "synonyms": extract_dict(source, "synonyms"),
        "unsupportedFoodPhrases": extract_string_list(source, "unsupportedFoodPhrases"),
        "displayNames": extract_int_dict(source, "displayNames"),
    }
    out = Path(__file__).resolve().parent.parent / "resolution" / "lexicon_snapshot.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
    print(
        f"wrote {out}: {len(snapshot['labelToId'])} labels, "
        f"{len(snapshot['synonyms'])} synonyms, "
        f"{len(snapshot['unsupportedFoodPhrases'])} unsupported phrases, "
        f"{len(snapshot['displayNames'])} display names"
    )


if __name__ == "__main__":
    sys.exit(main())
