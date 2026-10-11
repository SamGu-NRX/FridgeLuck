#!/usr/bin/env python3
"""Regeneration proof: rebuild the food-study table from capsule-stored outputs.

    python3 tools/experiment-capsules/regen.py \
        --capsules tools/experiment-capsules/results \
        --out tools/experiment-capsules/reports/regen-proof

Proves report regeneration from stored outputs alone:

1. verifies the capsules first (verify_capsule: dependency digests, import
   coverage, output digests) — an invalid capsule is never used as a
   regeneration source,
2. rebuilds the food-study table **purely from capsule-stored outputs**
   (the packed catalog copy; owner files and running owner code are never
   used for the table itself),
3. proves digest stability: the table is built twice and the bytes must be
   identical, and the volatile-content scanner must find no wall-clock or
   HEAD tokens in the regenerated table (the volatile ``generated_at_utc``
   field of the origin artifact is deliberately not carried over),
4. cross-checks counts between capsule-stored outputs (catalog record count
   vs the Swift export's embedded ``ingredientCount``), each result labeled
   as numerical agreement or labeled difference,
5. compares the capsule-derived table with the same table built from the
   **current origin files**, presenting every divergence as an explicitly
   labeled difference. Numerical agreement is never presented as identical
   provenance: agreement says "the numbers match today", not "this table
   came from the same run".

Trust limits (README.md): this proof binds content via digests. It detects
drift and inconsistent rewrites; a consistent malicious rewrite passes
without an external root of trust. Dynamic imports that cannot be statically
resolved remain declared coverage gaps in the capsule — regen never guesses
them closed.

Exit codes: 0 proof written, 1 invalid capsule or internal check failed,
2 usage error. Artifacts: ``table-from-capsule.tsv`` and
``regen-proof.md`` under ``--out`` (both timestamp-free and digest-stable).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from capsule_model import Finding, sha256_hex  # noqa: E402
from volatile_scan import scan_text as scan_volatile_content  # noqa: E402
from verify import verify_capsule  # noqa: E402

REPO_ROOT = TOOLS_DIR.parents[1]
MACRO_FIELDS = ("calories", "carbs_g", "fat_g", "fiber_g", "protein_g", "sodium_g", "sugar_g")
CATALOG_CAPSULE = "usda-curation-catalog"
CATALOG_STORED_AS = "usda_curated_ingredients.json"
SWIFT_CAPSULE = "usda-swift-static-export"
CATALOG_ORIGIN = "scripts/data/catalog/usda_curated_ingredients.json"


def catalog_table(records: list[dict]) -> list[dict]:
    """Pure: food-study table rows (per-category counts) from catalog records."""
    per_category: dict[str, dict[str, int]] = {}
    for record in records:
        category = str(record.get("category_label", "?"))
        macros = record.get("macros")
        complete = isinstance(macros, dict) and all(
            isinstance(macros.get(field), (int, float)) for field in MACRO_FIELDS
        )
        bucket = per_category.setdefault(
            category, {"ingredients": 0, "macro_complete": 0}
        )
        bucket["ingredients"] += 1
        bucket["macro_complete"] += 1 if complete else 0

    rows: list[dict] = []
    for category in sorted(per_category):
        bucket = per_category[category]
        rows.append(
            {
                "category": category,
                "ingredients": bucket["ingredients"],
                "macro_complete": bucket["macro_complete"],
                "macro_complete_share": bucket["macro_complete"] / bucket["ingredients"],
            }
        )
    total_ingredients = sum(row["ingredients"] for row in rows)
    total_complete = sum(row["macro_complete"] for row in rows)
    rows.append(
        {
            "category": "TOTAL",
            "ingredients": total_ingredients,
            "macro_complete": total_complete,
            "macro_complete_share": (
                total_complete / total_ingredients if total_ingredients else 0.0
            ),
        }
    )
    return rows


def render_tsv(rows: list[dict]) -> str:
    """Pure: digest-stable TSV rendering (no volatile values, fixed precision)."""
    lines = ["category\tingredients\tmacro_complete\tmacro_complete_share"]
    for row in rows:
        lines.append(
            f"{row['category']}\t{row['ingredients']}\t{row['macro_complete']}"
            f"\t{row['macro_complete_share']:.4f}"
        )
    return "\n".join(lines) + "\n"


def compare_tables(capsule_rows: list[dict], origin_rows: list[dict]) -> list[str]:
    """Pure: labeled differences between capsule-derived and origin-derived rows."""
    labels: list[str] = []
    by_category_capsule = {row["category"]: row for row in capsule_rows}
    by_category_origin = {row["category"]: row for row in origin_rows}
    for category in sorted(set(by_category_capsule) | set(by_category_origin)):
        capsule_row = by_category_capsule.get(category)
        origin_row = by_category_origin.get(category)
        if capsule_row is None:
            labels.append(
                f"DIFFERENCE [{category}]: row present only in the origin-derived "
                "table (capsule table has no such category)"
            )
            continue
        if origin_row is None:
            labels.append(
                f"DIFFERENCE [{category}]: row present only in the capsule-derived "
                "table (origin table has no such category)"
            )
            continue
        for field in ("ingredients", "macro_complete", "macro_complete_share"):
            if capsule_row[field] != origin_row[field]:
                labels.append(
                    f"DIFFERENCE [{category}] {field}: "
                    f"capsule={capsule_row[field]} vs origin={origin_row[field]}"
                )
    if not labels:
        labels.append(
            "AGREEMENT (numerical): every row of the capsule-derived table matches "
            "the origin-derived table numerically. This is numerical agreement, "
            "NOT identical provenance: the capsule table's provenance is the "
            "packed output digests, not the origin file or any run that produced it."
        )
    return labels


def extract_swift_count(swift_text: str) -> int | None:
    match = re.search(r"static let ingredientCount = (\d+)", swift_text)
    return int(match.group(1)) if match else None


def load_capsule_output(
    capsules_dir: Path, capsule: str, stored_as: str
) -> tuple[Path | None, list[Finding]]:
    capsule_dir = capsules_dir / capsule
    output_path = capsule_dir / "outputs" / stored_as
    if not output_path.is_file():
        return (
            None,
            [
                Finding(
                    "missing-storage",
                    f"{capsule}/outputs/{stored_as}",
                    "capsule output copy required for regeneration is absent",
                )
            ],
        )
    return output_path, []


def build_proof(capsules_dir: Path, repo_root: Path) -> tuple[str, str, int]:
    """Build (report_md, table_tsv, exit_code) from capsules + current origin."""
    findings: list[Finding] = []
    for capsule_dir in sorted(p for p in capsules_dir.iterdir() if p.is_dir()):
        capsule_findings, _ = verify_capsule(capsule_dir, repo_root)
        findings.extend(capsule_findings)
    if findings:
        details = "\n".join(f"  {f.code}: {f.path}: {f.detail}" for f in findings)
        print(f"error: capsules failed verification; refusing to build a proof:\n{details}",
              file=sys.stderr)
        return "", "", 1

    catalog_path, findings = load_capsule_output(capsules_dir, CATALOG_CAPSULE, CATALOG_STORED_AS)
    if catalog_path is None:
        print("error: catalog capsule output missing; cannot regenerate", file=sys.stderr)
        return "", "", 1
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    table = catalog_table(catalog["records"])
    tsv = render_tsv(table)

    # Digest-stability: rebuild and require identical bytes; volatile scan clean.
    rebuild_tsv = render_tsv(catalog_table(catalog["records"]))
    volatile = scan_volatile_content(tsv)
    digest_stable = rebuild_tsv == tsv and not volatile

    # Cross-capsule check: Swift export count vs catalog total. The Swift
    # file's own embedded record count is checked first so a difference
    # between the two artifacts cannot be misread as internal corruption.
    swift_path, findings = load_capsule_output(capsules_dir, SWIFT_CAPSULE, "USDAIngredientNutritionStaticData.swift")
    cross_checks: list[str] = []
    if swift_path is not None:
        swift_text = swift_path.read_text(encoding="utf-8")
        swift_count = extract_swift_count(swift_text)
        swift_rows = swift_text.count("USDAIngredientNutritionRecord(")
        catalog_total = table[-1]["ingredients"]
        if swift_count is None:
            cross_checks.append(
                "DIFFERENCE [cross-capsule]: the Swift export does not expose an "
                "ingredientCount constant; no count cross-check is possible"
            )
        elif swift_count != swift_rows:
            cross_checks.append(
                f"DIFFERENCE [cross-capsule]: Swift export ingredientCount "
                f"({swift_count}) does not match the Swift file's own embedded "
                f"record count ({swift_rows})"
            )
        elif swift_count == catalog_total:
            cross_checks.append(
                f"AGREEMENT (numerical): Swift export ingredientCount "
                f"({swift_count}, internally consistent with its {swift_rows} "
                f"embedded records) matches the capsule catalog record count "
                f"({catalog_total}). Numerical agreement, not identical provenance."
            )
        else:
            cross_checks.append(
                f"DIFFERENCE [cross-capsule]: Swift export ingredientCount "
                f"({swift_count}, internally consistent with its {swift_rows} "
                f"embedded records) differs from the capsule catalog record "
                f"count ({catalog_total}): the two owner artifacts cover "
                f"different record sets; no equality claim is made"
            )
    else:
        cross_checks.append(
            "DIFFERENCE [cross-capsule]: Swift capsule output copy is absent; "
            "no count cross-check is possible"
        )

    # Origin comparison: same table built from the CURRENT origin file.
    origin_path = repo_root / CATALOG_ORIGIN
    if origin_path.is_file():
        origin_catalog = json.loads(origin_path.read_text(encoding="utf-8"))
        origin_table = catalog_table(origin_catalog["records"])
        origin_labels = compare_tables(table, origin_table)
        origin_state = (
            f"origin file: `{CATALOG_ORIGIN}` (current sha256 "
            f"`{sha256_hex(origin_path.read_bytes())[:16]}...`)"
        )
    else:
        origin_labels = [
            "DIFFERENCE [origin]: the origin file is currently absent from the "
            "repository; the capsule-derived table stands alone on its packed digests"
        ]
        origin_state = f"origin file: `{CATALOG_ORIGIN}` (currently absent)"

    if not digest_stable:
        print("error: regenerated table is not digest-stable", file=sys.stderr)
        return "", "", 1

    lines = [
        "# Regeneration proof (from capsule-stored outputs)",
        "",
        "The food-study table below was regenerated **purely from capsule-stored",
        "outputs** — no owner file was read for the table, no owner code was run,",
        "and no live endpoint was contacted. Provenance for this table is the",
        f"capsule binding digests (capsule `{CATALOG_CAPSULE}`, output",
        f"`{CATALOG_STORED_AS}`, sha256 `{sha256_hex(catalog_path.read_bytes())}`),",
        "not the repository, not HEAD, and not any run.",
        "",
        "## Digest stability",
        "",
        f"- rebuilt twice from the same capsule bytes: identical ({'yes' if digest_stable else 'no'})",
        f"- volatile-content scan of the regenerated table: "
        f"{'clean' if not volatile else 'FINDINGS'}"
        " (the origin artifact's volatile `generated_at_utc` field is deliberately",
        "  not carried into regenerated table content)",
        "",
        "## Cross-capsule count checks (labeled)",
        "",
        *(item for line in cross_checks for item in ("", f"- {line}")),
        "",
        "## Comparison against the current origin files (labeled)",
        "",
        origin_state,
        "",
        *(item for line in origin_labels for item in ("", f"- {line}")),
        "",
        "## Coverage gaps",
        "",
        "Dynamic imports that cannot be statically resolved remain **declared",
        "coverage gaps** in the capsule. Regeneration does not guess them closed:",
        "the capsule declares exactly what was verified, and nothing else.",
        "",
        "## Trust limits",
        "",
        "Digests bind content, not intent. This proof detects drift and",
        "inconsistent rewrites; it cannot detect a consistent malicious rewrite",
        "absent an external root of trust. Numerical agreement between the",
        "capsule-derived table and any other table is agreement of numbers only —",
        "it is never identical provenance.",
        "",
        "## Regenerated table (tsv)",
        "",
        "```tsv",
        tsv.rstrip("\n"),
        "```",
        "",
    ]
    return "\n".join(lines), tsv, 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate the food-study table from capsule-stored outputs with labeled differences."
    )
    parser.add_argument(
        "--capsules", type=Path, default=REPO_ROOT / "tools/experiment-capsules/results"
    )
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "tools/experiment-capsules/reports/regen-proof")
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    capsules_dir = args.capsules.resolve()
    if not capsules_dir.is_dir():
        print(f"error: capsules directory not found: {capsules_dir}", file=sys.stderr)
        return 2

    report_md, tsv, exit_code = build_proof(capsules_dir, repo_root)
    if exit_code != 0:
        return exit_code

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "table-from-capsule.tsv").write_text(tsv, encoding="utf-8")
    (args.out / "regen-proof.md").write_text(report_md, encoding="utf-8")
    for line in tsv.strip().splitlines():
        print(f"  {line}")
    print(f"proof written: {args.out / 'regen-proof.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
