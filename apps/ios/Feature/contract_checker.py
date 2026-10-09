#!/usr/bin/env python3
"""Static contract checker for apps/ios/Feature/.

Part of the FridgeLuck Feature contract suite (see CONTRACTS.md). This script
makes the Feature-layer API contracts machine-checked: any banned construct in
a Swift file under apps/ios/Feature/ fails with a file:line report.

Usage:
  python3 apps/ios/Feature/contract_checker.py              # whole Feature dir
  python3 apps/ios/Feature/contract_checker.py --path Demo  # one submodule
  python3 apps/ios/Feature/contract_checker.py --all-tests-present
      # additionally requires every submodule's contract test file to exist
      # under apps/ios/Tests/ (used at merge time)

Exit codes: 0 = clean, 1 = violations found, 2 = usage error.

Rules are deliberately conservative (near-zero false positives). Anything the
regexes cannot decide reliably is a human review matter, not a rule here.
"""

import argparse
import re
import sys
from pathlib import Path

FEATURE_ROOT = Path(__file__).resolve().parent
REPO_ROOT = FEATURE_ROOT.parent.parent.parent
TESTS_DIR = REPO_ROOT / "apps" / "ios" / "Tests"


class Rule:
    def __init__(self, rule_id, message, pattern, line_exceptions=()):
        self.rule_id = rule_id
        self.message = message
        self.pattern = re.compile(pattern)
        self.line_exceptions = tuple(line_exceptions)


RULES = [
    Rule(
        "S001",
        "forced cast `as!` is banned: use `as?` + guard with a specific contract error",
        r"as\s*!",
    ),
    Rule(
        "S002",
        "force-try `try!` is banned: propagate a typed error or handle with a specific message",
        r"\btry\s*!",
    ),
    Rule(
        "S003",
        "implicitly unwrapped optional declaration (`let x: T!` / `var x: T!`) is banned",
        r"\b(?:let|var)\s+\w+\s*:\s*[^=\n{]*?!\s*(?:=|,|\)|\{|\]|$)",
    ),
    Rule(
        "S004",
        "`Any`-typed payloads (`[String: Any]`, `: Any`, `as Any`, ...) are banned in Feature APIs",
        r"\[[^\]\[]*:\s*Any\w*\]|\:\s*Any\b|\bas\s+Any\b|\bAny\]\b",
        line_exceptions=("UIImagePickerController.InfoKey",),
    ),
    Rule(
        "S005",
        "force-unwrapped `.first!` / `.last!` / `.only!` is banned: handle the empty case explicitly",
        r"\.\s*(?:first|last|only)\s*!",
    ),
    Rule(
        "S006",
        "force-unwrapped `URL(string:)!` is banned: validate and throw a specific error",
        r"URL\s*\(\s*string\s*:[^)]*\)\s*!",
    ),
    Rule(
        "S007",
        "empty catch block is banned: report or handle with a specific, non-silent fallback",
        r"catch\s*(?:\s*\([^\)]*\))?\s*\{\s*\}",
    ),
    Rule(
        "S008",
        "`fatalError` / `preconditionFailure` is banned in Feature code: throw a typed error instead",
        r"\bfatalError\s*\(|\bpreconditionFailure\s*\(",
    ),
    Rule(
        "S009",
        "`unowned` references are banned in Feature code: use weak + explicit handling",
        r"\bunowned\s*\(",
    ),
]

# Every Feature submodule must have contract tests. Submodules split across
# multiple fleet parts may have several test files; one match per prefix is enough.
EXPECTED_TEST_FILES = [
    "AssistantContractTests.swift",
    "DemoContractTests.swift",
    "EstimateContractTests.swift",
    "FinalizationContractTests.swift",
    "ResultsContractTests.swift",
    "HomeDashboardContractTests.swift",
    "HomeTutorialContractTests.swift",
    "IngredientsContractTests.swift",
    "InventoryContractTests.swift",
    "KitchenContractTests.swift",
    "OnboardingFlowContractTests.swift",
    "OnboardingDataContractTests.swift",
    "ProfileContractTests.swift",
    "ProgressContractTests.swift",
    "RecipeContractTests.swift",
    "ScanContractTests.swift",
    "SettingsNavContractTests.swift",
    "SettingsEditorsContractTests.swift",
    "SharedContractTests.swift",
]


def swift_files(base):
    return sorted(p for p in base.rglob("*.swift") if p.is_file())


def check_file(path, rules):
    violations = []
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="utf-8", errors="replace")
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        for rule in rules:
            if rule.pattern.search(line):
                if any(exc in line for exc in rule.line_exceptions):
                    continue
                violations.append((path, lineno, rule, line.rstrip()))
    return violations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--path",
        default=None,
        help="restrict scanning to this path relative to apps/ios/Feature (e.g. Demo)",
    )
    parser.add_argument(
        "--all-tests-present",
        action="store_true",
        help="also require every submodule contract test file to exist under apps/ios/Tests/",
    )
    args = parser.parse_args()

    base = FEATURE_ROOT
    if args.path:
        base = FEATURE_ROOT / args.path
        if not base.exists():
            print(f"error: no such path under apps/ios/Feature: {args.path}", file=sys.stderr)
            return 2
        rules = RULES
    else:
        rules = RULES

    violations = []
    for path in swift_files(base):
        violations.extend(check_file(path, rules))

    missing_tests = []
    if args.all_tests_present:
        for name in EXPECTED_TEST_FILES:
            if not (TESTS_DIR / name).is_file():
                missing_tests.append(name)

    if violations:
        by_file = {}
        for path, lineno, rule, line in violations:
            by_file.setdefault(path, []).append((lineno, rule, line))
        for path in sorted(by_file):
            rel = path.relative_to(REPO_ROOT)
            print(f"{rel}:")
            for lineno, rule, line in sorted(by_file[path]):
                print(f"  {rel}:{lineno}: {rule.rule_id} {rule.message}")
                print(f"      > {line.strip()[:120]}")
        print(
            f"\n{len(violations)} violation(s) in {len(by_file)} file(s)."
            " See apps/ios/Feature/CONTRACTS.md for how to fix each rule."
        )

    if missing_tests:
        print("\nmissing contract test files:")
        for name in missing_tests:
            print(f"  apps/ios/Tests/{name}")
        print(
            "\nEvery Feature submodule needs contract tests calling each public"
            " function with valid, boundary and invalid input."
        )

    if violations or missing_tests:
        return 1

    scanned = len(swift_files(base))
    print(f"OK: {scanned} file(s) scanned, 0 violations.")
    if args.all_tests_present:
        print(f"OK: all {len(EXPECTED_TEST_FILES)} contract test files present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
