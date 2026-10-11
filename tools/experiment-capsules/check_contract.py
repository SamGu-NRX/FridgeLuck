#!/usr/bin/env python3
"""Contract checker for experiment-capsule bindings.

A binding claims: these source/import files (with digests) plus this
toolchain, reading only these permitted inputs, under these model/transport
settings, produced exactly these outputs (with digests). This checker
verifies every claim it can check offline, against file contents — never
against git state, wall-clock time, or any live endpoint.

The three rejection classes it must catch:

1. missing-import          a declared source/import file is absent
2. source-mismatch         a file's content differs from its declared digest
3. self-referential-hash   an output's declared digest string appears inside
                           that output's content. No digest can be both
                           correct and embedded in the content it hashes
                           (that would be a sha256 fixed point), so such a
                           binding is unverifiable by construction.

Additional strictness (documented, always reported): schema, missing-output,
undeclared-import, undeclared-dynamic-import, undeclared-dependency,
source-syntax. Precedence per file: missing beats mismatch, and a
self-referential output is reported once (its digest is necessarily wrong —
counting the implied mismatch too would double-count one root cause).

Usage:
  python3 tools/experiment-capsules/check_contract.py
      Run every fixture case and print the exact rejection counts.
      Exit 0 iff every case behaves as expected.

  python3 tools/experiment-capsules/check_contract.py --binding <binding.json>
      Check one binding. Exit 0 = clean, 1 = rejections, 2 = usage error.

Trust limits: digests bind content, not intent. A consistent rewrite of
sources, digests AND outputs passes — the scheme detects drift and
inconsistent rewrites, but cannot detect a consistent malicious rewrite
without an external root of trust. See README.md.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from capsule_model import (  # noqa: E402
    Binding,
    Finding,
    load_binding_file,
    parse_binding,
    sha256_hex,
)
from import_scan import analyze_binding_sources  # noqa: E402

REPO_ROOT = TOOLS_DIR.parents[1]
FIXTURES_DIR = TOOLS_DIR / "fixtures" / "contracts"

# Fixture case -> expected rejection counts by finding code (exact).
FIXTURE_CASES: tuple[tuple[str, dict[str, int]], ...] = (
    ("valid", {}),
    ("missing-import", {"missing-import": 1}),
    ("source-mismatch", {"source-mismatch": 1}),
    ("self-referential", {"self-referential-hash": 1}),
    ("dynamic-gap-declared", {}),
)


def check_binding_file(binding_path: Path, repo_root: Path) -> list[Finding]:
    """Full offline check of one binding file against the working tree."""
    raw, load_findings = load_binding_file(binding_path)
    if load_findings:
        return load_findings
    binding, schema_findings = parse_binding(raw)
    if binding is None or schema_findings:
        return schema_findings
    return check_parsed_binding(binding, repo_root)


def check_dependencies(binding: Binding, repo_root: Path) -> list[Finding]:
    """Declared source/import files: present, and matching their digests."""
    findings: list[Finding] = []
    for source in binding.sources:
        file_path = repo_root / source.path
        if not file_path.is_file():
            findings.append(
                Finding(
                    "missing-import",
                    source.path,
                    f"declared {source.role} file is absent from the repository",
                )
            )
            continue
        actual = sha256_hex(file_path.read_bytes())
        if actual != source.sha256:
            findings.append(
                Finding(
                    "source-mismatch",
                    source.path,
                    f"declared {source.role} digest {source.sha256[:12]}… but file "
                    f"hashes to {actual[:12]}…",
                )
            )
    return findings


def check_output_files(
    binding: Binding, repo_root: Path, capsule_dir: Path | None = None
) -> list[Finding]:
    """Declared outputs: present, digest-matching, never self-referential.

    Two modes:

    - repo mode (capsule_dir=None): each output lives at repo_root/output.path
      (the M1 fixture layout — outputs are repo files).
    - capsule mode (capsule_dir set): each output was packed into
      capsule_dir/outputs/<stored_as>; the packed copy is what the digest
      must cover. A packed output without a stored_as name is a
      missing-storage finding; a stored file the binding does not declare is
      an undeclared-output finding (hidden labels are never tolerated).
    """
    findings: list[Finding] = []
    if capsule_dir is not None:
        stored_dir = capsule_dir / "outputs"
        declared_stored: set[str] = set()
        for output in binding.outputs:
            if output.stored_as:
                declared_stored.add(output.stored_as)
        if stored_dir.is_dir():
            for stored in sorted(stored_dir.iterdir()):
                if stored.name not in declared_stored:
                    findings.append(
                        Finding(
                            "undeclared-output",
                            f"outputs/{stored.name}",
                            "capsule stores a file the binding does not declare "
                            "(hidden labels are not tolerated)",
                        )
                    )
    for output in binding.outputs:
        if capsule_dir is not None:
            if not output.stored_as:
                findings.append(
                    Finding(
                        "missing-storage",
                        output.path,
                        "packed output has no stored_as name; it cannot be "
                        "verified against the capsule",
                    )
                )
                continue
            file_path = capsule_dir / "outputs" / output.stored_as
        else:
            file_path = repo_root / output.path
        if not file_path.is_file():
            if capsule_dir is not None:
                findings.append(
                    Finding(
                        "missing-storage",
                        f"outputs/{output.stored_as}",
                        "packed output copy is absent from the capsule",
                    )
                )
            else:
                findings.append(
                    Finding(
                        "missing-output",
                        output.path,
                        "declared output file is absent from the repository",
                    )
                )
            continue
        content = file_path.read_bytes()
        if output.sha256.encode("utf-8") in content:
            # Root cause: the binding embeds the digest inside the content
            # that digest claims to cover. Unverifiable by construction.
            findings.append(
                Finding(
                    "self-referential-hash",
                    output.path,
                    "output content contains its own declared digest; no digest "
                    "can be simultaneously correct and embedded (the implied "
                    "mismatch is not double-counted)",
                )
            )
            continue
        actual = sha256_hex(content)
        if actual != output.sha256:
            findings.append(
                Finding(
                    "source-mismatch",
                    output.path,
                    f"declared output digest {output.sha256[:12]}… but file hashes "
                    f"to {actual[:12]}…",
                )
            )
    return findings


def check_parsed_binding(
    binding: Binding, repo_root: Path, capsule_dir: Path | None = None
) -> list[Finding]:
    """Full offline check of one parsed binding.

    Dependency digests are checked against ``repo_root`` (drift detection);
    output digests against the repo tree or the packed capsule, per
    ``check_output_files``.
    """
    findings: list[Finding] = []
    findings.extend(check_dependencies(binding, repo_root))
    # Import-coverage analysis (only meaningful for sources that exist).
    findings.extend(analyze_binding_sources(binding, repo_root))
    findings.extend(check_output_files(binding, repo_root, capsule_dir))
    return findings


def counts(findings: list[Finding]) -> dict[str, int]:
    return dict(sorted(Counter(f.code for f in findings).items()))


def run_fixtures(repo_root: Path) -> int:
    """Run every fixture case; print exact counts; exit 0 iff as expected."""
    all_ok = True
    total_rejections: Counter = Counter()
    print(f"checker fixtures under {FIXTURES_DIR.relative_to(repo_root)}")
    for case_name, expected in FIXTURE_CASES:
        binding_path = FIXTURES_DIR / case_name / "binding.json"
        findings = check_binding_file(binding_path, repo_root)
        got = counts(findings)
        total_rejections.update(got)
        ok = got == expected
        all_ok = all_ok and ok
        expected_str = json.dumps(expected, sort_keys=True)
        got_str = json.dumps(got, sort_keys=True)
        print(f"case {case_name}: findings {got_str} expected {expected_str} "
              f"{'PASS' if ok else 'FAIL'}")
        for finding in findings:
            print(f"    {finding.code}: {finding.path}: {finding.detail}")

    summary = ", ".join(f"{code}={n}" for code, n in sorted(total_rejections.items()))
    print(f"SUMMARY rejections: {summary if summary else 'none'}")
    print(f"fixture expectations: {'all met' if all_ok else 'NOT met'}")
    return 0 if all_ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check experiment-capsule bindings offline (digests, imports, self-reference)."
    )
    parser.add_argument(
        "--binding",
        type=Path,
        help="check one binding file instead of the fixture suite",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="repository root (default: derived from this file's location)",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    if not repo_root.is_dir():
        print(f"error: repo root not found: {repo_root}", file=sys.stderr)
        return 2

    if args.binding is None:
        return run_fixtures(repo_root)

    if not args.binding.is_file():
        print(f"error: binding not found: {args.binding}", file=sys.stderr)
        return 2
    findings = check_binding_file(args.binding.resolve(), repo_root)
    got = counts(findings)
    for finding in findings:
        print(f"{finding.code}: {finding.path}: {finding.detail}")
    summary = ", ".join(f"{code}={n}" for code, n in sorted(got.items()))
    print(f"rejections: {summary if summary else 'none'}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
