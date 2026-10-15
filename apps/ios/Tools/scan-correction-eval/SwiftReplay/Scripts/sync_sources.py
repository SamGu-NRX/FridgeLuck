#!/usr/bin/env python3
"""Sync production sources into the SwiftReplay package.

Copies the real production files (verbatim) and generates the minimal
companions the replay needs on Linux:

  AppSources/LearningService.swift   verbatim copy
  AppSources/ConfidenceRouter.swift  verbatim copy
  AppSources/Detection.swift         verbatim copy except `import CoreGraphics`
                                     is dropped (no CoreGraphics on Linux);
                                     PlatformShims.swift supplies a CGRect stand-in
  AppSources/ScanContractsSubset.swift  only the OCRMatchKind and
                                     ConfidenceBucket enums, extracted verbatim
                                     (the full file needs CoreGraphics +
                                     FLFeatureLogic)
  AppSources/GeneratedSchema.swift   the user_corrections and ingredients
                                     create-table blocks plus the
                                     idx_corrections_label index, extracted
                                     verbatim from Migrations.swift

Nothing in the app sources is edited semantically: every transform here is a
platform-compatibility shim or a verbatim extraction, and `--check` fails if
the committed copies drift from production.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[6]  # .../SwiftReplay/Scripts -> repo root
TOOL = REPO / "apps" / "ios" / "Tools" / "scan-correction-eval"
PKG = TOOL / "SwiftReplay"

RECOGNITION = REPO / "apps" / "ios" / "Capability" / "Core" / "Recognition"
DETECTION = REPO / "apps" / "ios" / "Domain" / "Models" / "Detection.swift"
MIGRATIONS = REPO / "apps" / "ios" / "Platform" / "Persistence" / "Database" / "Migrations.swift"

EXTRACTIONS = {
    "OCRMatchKind": "enum OCRMatchKind",
    "ConfidenceBucket": "enum ConfidenceBucket",
}


def extract_block(source: str, start_marker: str, open_line: str) -> str:
    """Extract a brace-balanced block starting at the line containing
    start_marker/open_line."""
    idx = source.index(open_line)
    begin = source.rfind("\n", 0, idx) + 1
    depth = 0
    for pos in range(idx, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                end = source.index("\n", pos) + 1
                return source[begin:end]
    raise ValueError(f"unbalanced block for {start_marker}")


def extract_create_block(source: str, table: str) -> str:
    open_line = f'try db.create(table: "{table}")'
    return extract_block(source, table, open_line)


def generate() -> dict[str, str]:
    learning = (RECOGNITION / "LearningService.swift").read_text()
    router = (RECOGNITION / "ConfidenceRouter.swift").read_text()
    detection = DETECTION.read_text()
    contracts = (RECOGNITION / "ScanContracts.swift").read_text()
    migrations = MIGRATIONS.read_text()

    detection_linux = detection.replace("import CoreGraphics\n", "")
    if "import CoreGraphics" in detection_linux:
        raise SystemExit("failed to drop CoreGraphics import from Detection.swift")

    subset_blocks = []
    for name, marker in EXTRACTIONS.items():
        open_line = next(
            line for line in contracts.splitlines() if line.startswith(marker)
        )
        subset_blocks.append(extract_block(contracts, marker, open_line).rstrip("\n"))
    subset = "\n\n".join(subset_blocks) + "\n"

    user_corrections = extract_create_block(migrations, "user_corrections")
    ingredients = extract_create_block(migrations, "ingredients")
    index = re.search(
        r'try db\.create\(\s*\n\s*index: "idx_corrections_label",.*?\n\s*\)\n',
        migrations,
        re.S,
    )
    if index is None:
        raise SystemExit("idx_corrections_label index not found")
    schema = "\n".join(
        [
            "// Generated from Migrations.swift by Scripts/sync_sources.py -- do not edit.",
            "// Verbatim create blocks for the tables the replay touches.",
            "import GRDB",
            "",
            "enum ReplaySchema {",
            "  static func migrate(_ db: Database) throws {",
            "    " + ingredients.strip().replace("\n", "\n    "),
            "    " + user_corrections.strip().replace("\n", "\n    "),
            "    " + index.group(0).strip().replace("\n", "\n    "),
            "  }",
            "}",
        ]
    )

    return {
        "LearningService.swift": learning,
        "ConfidenceRouter.swift": router,
        "Detection.swift": detection_linux,
        "ScanContractsSubset.swift": (
            "// Generated from ScanContracts.swift by Scripts/sync_sources.py -- do not edit.\n"
            "// Only the enums Detection/ConfidenceRouter need; the full file pulls in\n"
            "// CoreGraphics and FLFeatureLogic.\n\n" + subset
        ),
        "GeneratedSchema.swift": schema,
        "PlatformShims.swift": (
            "// Linux compatibility shim: production Detection.swift uses CGRect only as an\n"
            "// optional payload it never reads in the replay; CoreGraphics does not exist here.\n"
            "#if !canImport(CoreGraphics)\n"
            "struct CGRect {}\n"
            "#endif\n"
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if committed copies would change")
    args = parser.parse_args()

    files = generate()
    out_dir = PKG / "Sources" / "AppSources"
    if args.check:
        drifted = [
            name
            for name, content in files.items()
            if not (out_dir / name).exists()
            or (out_dir / name).read_text() != content
        ]
        if drifted:
            print("SYNC DRIFT (run Scripts/sync_sources.sh):", ", ".join(drifted))
            raise SystemExit(1)
        print("sync check OK")
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (out_dir / name).write_text(content)
    print(f"synced {len(files)} files into {out_dir}")


if __name__ == "__main__":
    main()
