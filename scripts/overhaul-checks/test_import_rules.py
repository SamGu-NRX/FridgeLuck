#!/usr/bin/env python3
"""Tests for import_rules.py — the import-boundary checker.

Runs the checker as a subprocess against synthetic package trees, so the
tests exercise the real CLI contract (exit code 0 = clean, 1 = violations).

    python3 scripts/overhaul-checks/test_import_rules.py
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parent / "import_rules.py"

PACKAGE_SWIFT = "// swift-tools-version:6.0\nimport PackageDescription\n"


def make_package(root: Path, name: str, targets: dict):
    """Create packages/<name>/ with one Sources/<target> dir per entry."""
    package_dir = root / "packages" / name
    (package_dir / "Sources").mkdir(parents=True)
    (package_dir / "Package.swift").write_text(PACKAGE_SWIFT, encoding="utf-8")
    for target, source in targets.items():
        target_dir = package_dir / "Sources" / target
        target_dir.mkdir(parents=True, exist_ok=True)
        (target_dir / "S.swift").write_text(source, encoding="utf-8")
    return package_dir


def run_checker(root: Path):
    return subprocess.run(
        [sys.executable, str(CHECKER), str(root)],
        capture_output=True,
        text=True,
    )


class ImportRulesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_clean_tree_passes(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation\npublic struct Cook {}\n",
            "FLPersistence": "import Foundation\nimport GRDB\nimport FLDomain\n",
            "FLCapability": "import Foundation\nimport FLDomain\nimport FLPersistence\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("import rules: OK", result.stdout)

    def test_domain_importing_persistence_is_a_direction_violation(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation\nimport FLPersistence\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("dependency direction", result.stdout)

    def test_ui_framework_rejected_anywhere(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLPersistence": "import Foundation\nimport SwiftUI\n",
            "FLCapability": "import UIKit\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("UI framework"), 2)

    def test_unknown_import_fails_closed(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLCapability": "import Foundation\nimport Firebase\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("'Firebase'", result.stdout)
        self.assertIn("declare new dependencies here first", result.stdout)

    def test_multiple_imports_on_one_line_are_all_checked(self):
        # Sam, review round 3: the old matcher anchored at the line start,
        # so "import Foundation; import SwiftUI" reported only Foundation.
        # Every import statement on a line must be checked.
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation; import SwiftUI\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("UI framework", result.stdout)

    def test_exported_import_after_semicolon_is_checked(self):
        # The @_exported attribute form must be found anywhere on a line.
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation; @_exported import UIKit\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("UI framework", result.stdout)

    def test_leading_exported_import_is_checked(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "@_exported import SwiftUI\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("UI framework", result.stdout)

    def test_commented_import_is_not_an_import(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "// import SwiftUI is banned here\nimport Foundation\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_test_and_build_directories_are_out_of_scope(self):
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation\n",
        })
        base = self.root / "packages" / "FridgeLuckCore"
        (base / "Tests" / "FLDomainTests").mkdir(parents=True)
        (base / "Tests" / "FLDomainTests" / "T.swift").write_text(
            "import XCTest\nimport SwiftUI\n", encoding="utf-8"
        )
        build = base / ".build" / "checkouts" / "weird"
        build.mkdir(parents=True)
        (build / "B.swift").write_text("import UIKit\n", encoding="utf-8")
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_later_capability_package_is_scanned_and_fail_closed(self):
        # A canonical capability package (e.g. FLFoodSafety) appears under
        # packages/ automatically; its targets may not silently import
        # sibling capabilities — consumption must be declared.
        make_package(self.root, "FridgeLuckCore", {
            "FLDomain": "import Foundation\n",
        })
        make_package(self.root, "FLFoodSafety", {
            "FLFoodSafety": "import Foundation\nimport FLIngredientFacts\n",
        })
        result = run_checker(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("'FLIngredientFacts'", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
