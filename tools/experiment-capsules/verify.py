#!/usr/bin/env python3
"""Verify packed capsules: dependency digests and output digests, re-checked.

    python3 tools/experiment-capsules/verify.py \
        --capsules tools/experiment-capsules/results

For every capsule directory under ``--capsules`` (a directory containing
``binding.json`` and an ``outputs/`` copy directory — nothing else), verify.py:

1. loads and strictly parses the binding (schema, volatile fields,
   credential-shaped fields — all rejected),
2. re-checks **dependency digests**: every declared source/import file is
   hashed against the current repository tree — drift between the packed
   binding and the working tree is reported, never silently accepted,
3. re-checks **import coverage** with the same static scanner the contract
   checker uses (undeclared local imports, undeclared dependencies,
   undeclared dynamic-import constructs),
4. re-checks **output digests from what was packed**: every stored copy in
   ``outputs/`` is hashed against the binding's declared digest, and every
   stored file the binding does not declare is rejected (no hidden labels),
5. reports **origin drift as information, not rejection**: the capsule
   preserves the digest of the owner artifact as it was packed; the owner's
   current file may legitimately have moved on since. Origin drift never
   fails verification — output integrity is judged against the packed copy,
   which is what the capsule stores.

Capsule layout rule (no hidden labels): a capsule directory may contain
only ``binding.json`` and ``outputs/``. Anything else is a
``capsule-layout`` finding.

Trust limits (README.md): digests bind content, not intent. Verification
detects drift and inconsistent rewrites; a consistent malicious rewrite
passes without an external root of trust. Origin drift being informational
is exactly why: the packed digest pins what WAS packed, not what the owner
has published since.

Exit codes: 0 all capsules verified clean, 1 findings, 2 usage error.
With ``--report PATH`` a timestamp-free JSON report is written (digest-stable,
committable).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from capsule_model import (  # noqa: E402
    Finding,
    load_binding_file,
    parse_binding,
    sha256_hex,
)
from check_contract import check_parsed_binding, counts  # noqa: E402

REPO_ROOT = TOOLS_DIR.parents[1]


def origin_drift(binding_raw: dict, repo_root: Path) -> list[dict]:
    """Informational: owner artifacts that moved on after this pack."""
    drift: list[dict] = []
    for output in binding_raw.get("outputs", []):
        origin_path = repo_root / output["path"]
        if not origin_path.is_file():
            drift.append(
                {
                    "output": output["stored_as"],
                    "origin": output["path"],
                    "note": "origin file currently absent from the repository",
                    "packed_sha256": output["sha256"],
                    "origin_sha256": None,
                }
            )
            continue
        origin_digest = sha256_hex(origin_path.read_bytes())
        if origin_digest != output["sha256"]:
            drift.append(
                {
                    "output": output["stored_as"],
                    "origin": output["path"],
                    "note": "origin content differs from the packed snapshot "
                    "(informational; the capsule pins what was packed)",
                    "packed_sha256": output["sha256"],
                    "origin_sha256": origin_digest,
                }
            )
    return drift


def verify_capsule(capsule_dir: Path, repo_root: Path) -> tuple[list[Finding], list[dict]]:
    """Verify one capsule directory; returns (findings, origin drift)."""
    binding_path = capsule_dir / "binding.json"
    if not binding_path.is_file():
        return (
            [Finding("capsule-layout", capsule_dir.name, "capsule has no binding.json")],
            [],
        )
    raw, load_findings = load_binding_file(binding_path)
    if load_findings:
        return load_findings, []
    binding, schema_findings = parse_binding(raw)
    if binding is None or schema_findings:
        return schema_findings, []

    findings: list[Finding] = []
    # No hidden labels: only binding.json and outputs/ may exist.
    allowed_entries = {"binding.json", "outputs"}
    for entry in sorted(capsule_dir.iterdir()):
        if entry.name not in allowed_entries:
            findings.append(
                Finding(
                    "capsule-layout",
                    f"{capsule_dir.name}/{entry.name}",
                    "capsule directories contain only binding.json and outputs/ "
                    "(no hidden labels)",
                )
            )

    findings.extend(check_parsed_binding(binding, repo_root, capsule_dir=capsule_dir))
    return findings, origin_drift(raw, repo_root)


def verify_all(capsules_dir: Path, repo_root: Path) -> tuple[dict, int]:
    """Verify every capsule under capsules_dir; returns (report, exit_code)."""
    try:
        capsules_key = str(capsules_dir.relative_to(repo_root))
    except ValueError:
        capsules_key = str(capsules_dir)
    report: dict = {"capsules": [], "capsules_dir": capsules_key, "totals": {}}
    totals: dict[str, int] = {}
    all_clean = True

    capsule_dirs = sorted(d for d in capsules_dir.iterdir() if d.is_dir())
    if not capsule_dirs:
        print(f"error: no capsule directories under {capsules_dir}", file=sys.stderr)
        return report, 2

    for capsule_dir in capsule_dirs:
        findings, drift = verify_capsule(capsule_dir, repo_root)
        capsule_counts = counts(findings)
        for code, n in capsule_counts.items():
            totals[code] = totals.get(code, 0) + n
        clean = not findings
        all_clean = all_clean and clean
        print(
            f"capsule {capsule_dir.name}: "
            + ("VERIFIED (dependency digests, import coverage, output digests)"
               if clean
               else f"REJECTED {json.dumps(capsule_counts, sort_keys=True)}")
        )
        for finding in findings:
            print(f"    {finding.code}: {finding.path}: {finding.detail}")
        for entry in drift:
            print(
                f"    origin-drift (informational): {entry['output']} <- "
                f"{entry['origin']}: {entry['note']}"
            )
        report["capsules"].append(
            {
                "capsule": capsule_dir.name,
                "status": "verified" if clean else "rejected",
                "findings": [f.to_dict() for f in findings],
                "counts": capsule_counts,
                "origin_drift_informational": drift,
            }
        )

    report["totals"] = dict(sorted(totals.items()))
    summary = ", ".join(f"{code}={n}" for code, n in sorted(totals.items())) or "none"
    print(f"SUMMARY rejections: {summary}")
    print(
        "verification: "
        + ("all capsules clean" if all_clean else "FINDINGS PRESENT — see above")
    )
    return report, (0 if all_clean else 1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify packed capsules offline: dependency digests vs the repo, output digests vs the packed copies."
    )
    parser.add_argument("--capsules", type=Path, required=True, help="capsules directory")
    parser.add_argument(
        "--repo-root", type=Path, default=REPO_ROOT, help="repository root (default: derived)"
    )
    parser.add_argument(
        "--report", type=Path, help="optional path for a timestamp-free JSON report"
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    capsules_dir = args.capsules.resolve()
    if not repo_root.is_dir():
        print(f"error: repo root not found: {repo_root}", file=sys.stderr)
        return 2
    if not capsules_dir.is_dir():
        print(f"error: capsules directory not found: {capsules_dir}", file=sys.stderr)
        return 2

    report, exit_code = verify_all(capsules_dir, repo_root)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"report written: {args.report}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
