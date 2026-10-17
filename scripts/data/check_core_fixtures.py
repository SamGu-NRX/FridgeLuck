#!/usr/bin/env python3
"""Offline integrity check for the FridgeLuckCore JSON fixture contract.

Standard library only; no project imports. Complements the Swift
FixtureContractTests by independently checking, from another language:

  - manifest.json parses, names only files that exist, and lists every
    .json file in the fixture directory (no orphans, no dangling entries);
  - the manifest schema string is an accepted contract version;
  - object keys are sorted at every level of every fixture (the canonical
    encoder's sortedKeys rule);
  - any string that looks like an ISO 8601 timestamp is the canonical UTC
    millisecond form (2026-10-11T12:00:00.000Z);
  - quantity evidence never claims "unknown" while carrying any other key.

Exit code 0 prints one PASS line per file; any violation exits 1 listing
every finding. The fixture set is the cross-language contract documented in
packages/FridgeLuckCore/Fixtures/README.md.
"""

import argparse
import json
import re
import sys
from pathlib import Path

CANONICAL_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
TIMESTAMP_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}T")
SCHEMA_ACCEPTED_MAJOR = "fldomain.v1"


def schema_is_accepted(raw: str) -> bool:
    if raw == SCHEMA_ACCEPTED_MAJOR:
        return True
    prefix = SCHEMA_ACCEPTED_MAJOR + "."
    suffix = raw[len(prefix):] if raw.startswith(prefix) else None
    return bool(suffix) and suffix.isdigit()


def check_keys_sorted(node, path, findings):
    if isinstance(node, dict):
        keys = list(node.keys())
        if keys != sorted(keys):
            findings.append(f"{path}: keys not in sorted order: {keys}")
        for key, value in node.items():
            check_keys_sorted(value, f"{path}.{key}", findings)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            check_keys_sorted(item, f"{path}[{index}]", findings)


def check_timestamps(node, path, findings):
    if isinstance(node, dict):
        for key, value in node.items():
            check_timestamps(value, f"{path}.{key}", findings)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            check_timestamps(item, f"{path}[{index}]", findings)
    elif isinstance(node, str) and TIMESTAMP_PREFIX.match(node):
        if not CANONICAL_TIMESTAMP.match(node):
            findings.append(
                f"{path}: timestamp {node!r} is not canonical UTC milliseconds"
            )


def check_unknown_evidence(node, path, findings):
    if isinstance(node, dict):
        if node.get("kind") == "unknown" and len(node) != 1:
            findings.append(
                f"{path}: unknown quantity evidence must carry no other keys"
            )
        for key, value in node.items():
            check_unknown_evidence(value, f"{path}.{key}", findings)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            check_unknown_evidence(item, f"{path}[{index}]", findings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "fixtures_dir",
        nargs="?",
        default="packages/FridgeLuckCore/Fixtures",
        help="path to the Fixtures directory (default: %(default)s)",
    )
    args = parser.parse_args()
    directory = Path(args.fixtures_dir)

    findings = []
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"FAIL {manifest_path}: manifest.json is missing", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    schema = manifest.get("schema")
    if not isinstance(schema, str) or not schema_is_accepted(schema):
        findings.append(f"manifest.json: unsupported schema version {schema!r}")

    entries = manifest.get("fixtures")
    if not isinstance(entries, list):
        findings.append("manifest.json: 'fixtures' must be a list")
        entries = []

    listed = set()
    for entry in entries:
        name = entry.get("file") if isinstance(entry, dict) else None
        if not name:
            findings.append(f"manifest.json: entry without a file name: {entry!r}")
            continue
        listed.add(name)
        if not (directory / name).is_file():
            findings.append(f"manifest.json: listed file {name} does not exist")

    on_disk = {
        path.name
        for path in directory.glob("*.json")
        if path.name != "manifest.json"
    }
    for orphan in sorted(on_disk - listed):
        findings.append(f"Fixtures/: {orphan} exists but is not in the manifest")

    for name in sorted(listed & on_disk):
        path = directory / name
        file_findings = []
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            findings.append(f"{name}: not valid JSON: {error}")
            continue
        check_keys_sorted(document, name, file_findings)
        check_timestamps(document, name, file_findings)
        check_unknown_evidence(document, name, file_findings)
        if file_findings:
            findings.extend(file_findings)
        else:
            print(f"PASS {name}")

    if findings:
        for finding in findings:
            print(f"FAIL {finding}", file=sys.stderr)
        return 1
    print(f"OK {len(listed & on_disk)} fixtures conform to {schema}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
