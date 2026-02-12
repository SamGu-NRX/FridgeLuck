from __future__ import annotations

from collections import Counter
from pathlib import Path

from .schema import CanonicalCatalog
from .utils import utc_now_iso


def build_report(catalog: CanonicalCatalog) -> str:
    by_category = Counter(row.category_label for row in catalog.records)
    lines: list[str] = []
    lines.append("# USDA Pipeline Report")
    lines.append("")
    lines.append(f"- Generated at UTC: {utc_now_iso()}")
    lines.append(f"- Schema version: {catalog.schema_version}")
    lines.append(f"- Record count: {len(catalog.records)}")
    lines.append("")
    lines.append("## Category Distribution")
    lines.append("")
    for key, value in sorted(by_category.items(), key=lambda item: (-item[1], item[0])):
        lines.append(f"- {key}: {value}")
    lines.append("")
    lines.append("## Sample")
    lines.append("")
    for row in catalog.records[:20]:
        lines.append(f"- {row.fdc_id} | {row.display_name} | {row.category_label} | {row.sprite_group}/{row.sprite_key}")
    lines.append("")
    return "\n".join(lines)


def write_report(path: Path, report: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(report, encoding="utf-8")
