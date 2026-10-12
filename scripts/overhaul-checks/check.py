#!/usr/bin/env python3
"""Named-suite runner for the FridgeLuckCore package (Linux).

The original Part 1 brief asked for a way to run a NAMED test suite on Linux
without running the world — iterating on persistence should not re-run the
whole bundle. This runner maps suite names to `swift test --filter`
expressions and prints a self-identifying header (HEAD SHA, toolchain,
platform) so output pasted into a PR's Proof section says what produced it.

Suites:
  domain             FLDomainTests (validated models, canonical contracts)
  persistence        FLPersistenceTests (migrations, WAL, records)
  paired-write       CookPersistenceTests (atomic Cook + PreferenceEvent)
  fixtures           FixtureContractTests (core fixture integrity)
  sharing            CookSharingTests (share-card round-trips, day contract)
  round2-validation  ShareCardDecodeValidationTests + ConstructedPayloadValidationTests
  imports            the import-boundary checker (import_rules.py)
  all                the full swift test bundle

`swift test --filter` still builds every test target (SwiftPM compiles the
whole bundle) but RUNS only the matching tests — that is the fastest
correct thing on Linux today; per-target builds would need per-target test
bundles, which the package layout does not have yet.

Usage:
    python3 scripts/overhaul-checks/check.py --suite persistence
    python3 scripts/overhaul-checks/check.py --suite all
    python3 scripts/overhaul-checks/check.py --list
"""

import argparse
import platform
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_DIR = REPO_ROOT / "packages" / "FridgeLuckCore"
CHECKS_DIR = Path(__file__).resolve().parent

SUITES = {
    "domain": ["--filter", "FLDomainTests"],
    "persistence": ["--filter", "FLPersistenceTests"],
    "paired-write": ["--filter", "CookPersistenceTests"],
    "fixtures": ["--filter", "FixtureContractTests"],
    "sharing": ["--filter", "CookSharingTests"],
    "round2-validation": [
        "--filter",
        "ShareCardDecodeValidationTests|ConstructedPayloadValidationTests",
    ],
}


def run(cmd, cwd=None):
    """Run a command streaming to stdout; return its exit code."""
    result = subprocess.run(cmd, cwd=cwd)
    return result.returncode


def print_header(suite: str):
    head = run_capture("git rev-parse HEAD")
    swift_version = run_capture("swift --version --brief") or run_capture("swift --version")
    print("=" * 64)
    print(f"check.py — suite: {suite}")
    print(f"HEAD: {head}")
    print(f"toolchain: {swift_version.strip()}")
    print(f"platform: {platform.platform()}")
    print("=" * 64)


def run_capture(cmd: str):
    try:
        out = subprocess.run(
            cmd, shell=True, cwd=REPO_ROOT, capture_output=True, text=True
        )
        return out.stdout.strip() or out.stderr.strip()
    except OSError:
        return ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--suite", help="suite name (see docstring); required unless --list")
    parser.add_argument("--list", action="store_true", help="list suite names and exit")
    args = parser.parse_args(argv)

    if args.list:
        for name in sorted(SUITES):
            print(name)
        print("imports")
        print("all")
        return 0

    if not args.suite:
        parser.error("--suite is required (or use --list)")
    suite = args.suite

    print_header(suite)

    if suite == "imports":
        return run([sys.executable, str(CHECKS_DIR / "import_rules.py")], cwd=REPO_ROOT)

    if suite == "all":
        return run(["swift", "test"], cwd=PACKAGE_DIR)

    if suite not in SUITES:
        print(f"unknown suite: {suite} (see --list)", file=sys.stderr)
        return 2

    return run(["swift", "test", *SUITES[suite]], cwd=PACKAGE_DIR)


if __name__ == "__main__":
    sys.exit(main())
